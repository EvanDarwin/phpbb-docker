# evandarwin/phpbb-docker

[![Docker Pulls](https://img.shields.io/docker/pulls/evandarwin/phpbb.svg)](https://hub.docker.com/r/evandarwin/phpbb)
[![License](https://img.shields.io/github/license/evandarwin/phpbb-docker)](https://github.com/evandarwin/docker-phpbb/blob/main/LICENSE)
[![Docker Image Size](https://img.shields.io/docker/image-size/evandarwin/phpbb/latest)](https://hub.docker.com/r/evandarwin/phpbb)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/EvanDarwin/phpbb-docker/docker-publish.yml)
[![Last Updated](https://img.shields.io/docker/last-updated/evandarwin/phpbb)](https://github.com/evandarwin/docker-phpbb/releases)
![Docker Image Version](https://img.shields.io/docker/v/evandarwin/phpbb)

Looking for a modern, secure, and hassle-free way to run phpBB in Docker? You've found it! This
image offers a thoughtfully pre-configured phpBB environment that's ready for production use with
minimal setup.

## Existing Users

<details>
<summary>If you installed this container before <b>2026-10-22</b>, then <b>PLEASE</b> read this section!</summary>

---

All tags have been re-released to address several serious issues. First, the issues:

- `/opt/phpbb/` was never actually declared as a volume
- Default admin passwords were generated insecurely in evandarwin/phpbb
- nginx conditional ordering meant some assets were not protected
- The image accepted `X-Forwarded-For` from all internal IPs, and now requires `TRUSTED_PROXIES`
- [CVE-2026-109618](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w) /
  [CVE-2026-109619](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
  (PHP2Shell)

### What the first start of the new image does

- **Upgrades your board automatically**, after writing a backup.

  See [How Upgrades Work](#how-upgrades-work).

- **Stops trusting `X-Forwarded-For` by default.** If a reverse proxy (nginx, Traefik, Caddy,
  Cloudflare, ...) sits in front of your forum, **you must** set `TRUSTED_PROXIES` to its address
  range, or to the string `cloudflare`. Unless you do, phpBB will see the Docker proxy's address for
  every visitor, so IP information and per-IP login limits will apply to everyone. If the proxy is
  another container, you can trust its whole Docker network instead, as long as the forum's port
  isn't also published.

  See [Using Behind a Reverse Proxy](#using-behind-a-reverse-proxy).

- **Warns about weak admin passwords.** Older images generated admin passwords far shorter than
  intended. If your board was created by one of them and you don't set `PHPBB_PASSWORD`, the log
  shows a `SECURITY WARNING` on every start. Change the admin password in the User Control Panel
  (Profile > Edit account settings), then silence the warning:

  ```bash
  docker exec <container> rm /opt/phpbb/phpbb/.change-admin-password
  ```

- **Stops using phpBB's code on your volume.** phpBB's code now lives read-only inside the image, at
  `/var/www/phpbb`. From your volume, the image uses only your board's data (see
  [Data Persistence](#data-persistence)). Everything else the older images put in
  `/opt/phpbb/phpbb/` is left untouched but no longer used, and you can delete it once the upgrade
  has succeeded:
  - Folders: `adm/`, `assets/`, `bin/`, `cache/`, `config/` (the folder, not `config.php`), `docs/`,
    `download/`, `includes/`, `phpbb/`, `vendor/`
  - Files: `app.php`, `common.php`, `composer.json`, `composer.lock`, `cron.php`, `faq.php`,
    `feed.php`, `index.php`, `mcp.php`, `memberlist.php`, `posting.php`, `report.php`, `search.php`,
    `ucp.php`, `viewforum.php`, `viewonline.php`, `viewtopic.php`, `web.config`
- **Stops applying edits to phpBB's own code.** If you patched phpBB's PHP files, or added files
  next to `index.php` (a custom page, `robots.txt`, a site verification file), they stay on your
  volume but are no longer used or served. Move them into a derived image; see
  [Customizing phpBB](#customizing-phpbb).
- **Disables the web installer.** `/install/` answers 403. Installs and upgrades run automatically
  from the command line inside the container.

### The Volume

This issue only applies if you used the container without mounting a volume to `/opt/phpbb` -
removing a container deletes everything stored inside it, so check before you update:

```sh
docker inspect -f '{{range .Mounts}}{{println .Name .Destination}}{{end}}' <container>
```

If a line ends in `/opt/phpbb`, your data is on a volume, and you can [update](#updating) as usual.

If none does, you **DID NOT** provide a `-v phpbb_data:/opt/phpbb` argument in some form, quickly
back it up before you update (and properly mount a volume this time).

```sh
docker cp <container>:/opt/phpbb ./phpbb-backup
```

From v2 on, `/opt/phpbb` is declared as a volume, so Docker always stores it outside the container.
Previous values are still respected and this change does not affect that configuration.

This change is directed at avoiding data loss for new installs.

</details>

## Why Choose This Image?

This image was created after Bitnami / Broadcom deprecated their official phpBB container; as a
modern alternative that prioritizes:

### 🛡️ Security Enhancements

- **Defense in Depth**: Multiple layers of protection including:
  - Non-root execution with proper file permissions
  - Daily builds across all versions for the latest alpine updates
  - phpBB's code is owned by root and read-only, so even a compromised board can't modify it
  - Protection against common web attacks
  - Nginx configuration to protect sensitive files and directories
  - Disabled dangerous PHP functions like `exec` and `shell_exec`
  - `open_basedir` restrictions to limit file access

### ⚡ Performance Optimizations

- **PHP Opcache**: Pre-configured for optimal performance
- **Nginx**: Lightweight and fast web server with optimized settings
- **Static File Caching**: Properly configured for optimal browser caching
- **Tuned PHP Settings**: Balanced for good performance while maintaining stability

### 🧰 Convenience Features

- **Auto-configuration**: Just set environment variables and go
- **Automatic Upgrades**: Pull a newer image and your board upgrades itself, with a backup first
- **Multi-DB Support**: Choose MySQL, MariaDB, PostgreSQL, or SQLite based on your needs
- **Health Checks**: Built-in container health monitoring
  - The DB is excluded from the health check, so a DB failure will not cascade to your forum
    container also
- **Smart Defaults**: Works out-of-the-box, but remains highly customizable

## Quick Start (It's Really That Easy!)

The recommended method for running this image is via **Docker Compose**, as it makes upgrading
between tags much easier.

<details open>
<summary><b>docker-compose.yml</b></summary>
Here's a complete example using Docker Compose with MySQL, behind a
reverse proxy on the same host (see [Using Behind a Reverse Proxy](#using-behind-a-reverse-proxy)).
Replace the values in braces:

```yaml
services:
  phpbb:
    image: evandarwin/phpbb:3
    ports:
      # Only the host's reverse proxy can reach the forum
      - '127.0.0.1:8080:8080'
    environment:
      - PHPBB_FORUM_NAME=My Amazing Forum
      - PHPBB_FORUM_DESCRIPTION=Welcome to my phpBB forum
      - PHPBB_USERNAME=admin
      - PHPBB_PASSWORD={admin_password}
      - PHPBB_EMAIL=admin@example.com
      - PHPBB_DATABASE_DRIVER=mysqli
      - PHPBB_DATABASE_HOST=mysql
      - PHPBB_DATABASE_NAME=phpbb
      - PHPBB_DATABASE_USER=phpbb
      - PHPBB_DATABASE_PASSWORD={database_password}
      - SERVER_NAME=forums.example.com
      - SERVER_PROTOCOL=https://
      - COOKIE_SECURE=true
      # The host's reverse proxy connects from the gateway of the network below
      - TRUSTED_PROXIES=172.30.0.1
    volumes:
      - phpbb_data:/opt/phpbb
    depends_on:
      - mysql
    restart: unless-stopped

  mysql:
    image: mysql:8.0
    environment:
      - MYSQL_ROOT_PASSWORD={root_password}
      - MYSQL_DATABASE=phpbb
      - MYSQL_USER=phpbb
      - MYSQL_PASSWORD={database_password}
    volumes:
      - mysql_data:/var/lib/mysql
    restart: unless-stopped
    healthcheck:
      test: ['CMD-SHELL', 'mysqladmin ping -h localhost -u root -p"$$MYSQL_ROOT_PASSWORD"']
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s

networks:
  default:
    ipam:
      config:
        - subnet: 172.30.0.0/24

volumes:
  phpbb_data:
  mysql_data:
```

For PostgreSQL, set `PHPBB_DATABASE_DRIVER=postgres` and `PHPBB_DATABASE_HOST=postgres`, and replace
the MySQL service with:

```yaml
postgres:
  image: postgres:15
  environment:
    - POSTGRES_PASSWORD={database_password}
    - POSTGRES_USER=phpbb
    - POSTGRES_DB=phpbb
  volumes:
    - postgres_data:/var/lib/postgresql/data
  restart: unless-stopped
  healthcheck:
    test: ['CMD', 'pg_isready', '-U', 'phpbb']
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 30s
```

</details>

Start it with `docker compose up -d`. Once the install finishes (a few seconds), log in as `admin`
with your `{admin_password}`. Leave `PHPBB_PASSWORD` out to have one generated instead: the log
shows it once, right after the install.

---

<details>
<summary>Plain <code>docker run</code>, with SQLite</summary>

```bash
docker run -d \
  --name phpbb \
  -p 127.0.0.1:8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Awesome Forum" \
  -e TRUSTED_PROXIES=172.17.0.1 \
  evandarwin/phpbb:3
```

The container will log the generated admin password, once - so write it down somewhere!

By default, it uses SQLite stored on the volume, but for Kubernetes or multi-container installs
you'll likely want to read [Real-World Examples](#real-world-examples) for true MySQL and PostgreSQL
installs.

</details>

## Available Tags

- `latest` - Latest phpBB version with all the good stuff
- `<version>` - Specific phpBB version (e.g., `3.3.19`)
- `<major>.<minor>` - Latest patch version of a minor release (e.g., `3.3`)
- `<major>` - Latest minor.patch version of a major release (e.g., `3`)

All images are built on Alpine Linux 3.24: phpBB 3.x with PHP 8.4 (nobody's complained yet).

## The Admin Account

The first start installs phpBB and creates an admin account from `PHPBB_USERNAME` (default `admin`)
and `PHPBB_PASSWORD`.

- If `PHPBB_PASSWORD` is empty, a random 12-character password (from every printable ASCII character
  except space) is generated and shown **once** in the log, in a framed block right after the
  install. Save it then; it is never shown again.
- Any characters work in `PHPBB_PASSWORD`, including quotes and symbols. phpBB requires 6 to 30
  characters, and counts `&` as 5, `<` and `>` as 4, and `"` as 6 characters toward that limit.
- These variables only matter for the first install. Changing them later does nothing; change the
  password in phpBB itself.

## Environment Variables

Except for the proxy, header, debug and PHP settings, which are read on every start, these are only
read when phpBB is first installed. To change them on an existing board, use phpBB's Administration
Control Panel. The database settings are the exception: phpBB keeps them in
`/opt/phpbb/phpbb/config.php`, so change them there, and keep the variables matching, because the
image uses them on every start to check that the database is reachable.

<details>
<summary>Forum Configuration</summary>

| Variable                  | Description                                    | Default          |
| ------------------------- | ---------------------------------------------- | ---------------- |
| `PHPBB_FORUM_NAME`        | Name of the forum                              | "My phpBB Forum" |
| `PHPBB_FORUM_DESCRIPTION` | Description of the forum                       | "A phpBB Forum"  |
| `PHPBB_LANGUAGE`          | Language for the board (phpBB ships with `en`) | "en"             |

</details>

<details>
<summary>Admin User</summary>

| Variable         | Description                          | Default                      |
| ---------------- | ------------------------------------ | ---------------------------- |
| `PHPBB_USERNAME` | Username for the administrative user | "admin"                      |
| `PHPBB_PASSWORD` | Password for the admin user          | "" (auto-generated if empty) |
| `PHPBB_EMAIL`    | Admin user email                     | "admin@example.com"          |

</details>

<details>
<summary>Database Configuration</summary>

| Variable                                           | Description                                                                                | Default                   |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------- |
| `PHPBB_DATABASE_DRIVER`                            | `sqlite3`, `mysqli` (MySQL and MariaDB) or `postgres`                                      | "sqlite3"                 |
| `PHPBB_DATABASE_HOST`                              | Database host address                                                                      | "localhost"               |
| `PHPBB_DATABASE_PORT`                              | Database port                                                                              | "" (uses default port)    |
| `PHPBB_DATABASE_NAME`                              | Database name                                                                              | "phpbb"                   |
| `PHPBB_DATABASE_USER` or `PHPBB_DATABASE_USERNAME` | Database username                                                                          | "phpbb_user"              |
| `PHPBB_DATABASE_PASSWORD` or `PHPBB_DATABASE_PASS` | Database password                                                                          | ""                        |
| `PHPBB_DATABASE_SQLITE_PATH`                       | SQLite database file; must be under `/opt/phpbb` (see [SQLite](#sqlite-database-location)) | "/opt/phpbb/phpbb.sqlite" |
| `PHPBB_TABLE_PREFIX`                               | Prefix for database tables                                                                 | "phpbb\_"                 |

</details>

<details>
<summary>Email / SMTP</summary>

| Variable        | Description                       | Default       |
| --------------- | --------------------------------- | ------------- |
| `SMTP_HOST`     | SMTP server address; enables SMTP | "" (disabled) |
| `SMTP_PORT`     | SMTP server port                  | "25"          |
| `SMTP_USER`     | SMTP username                     | ""            |
| `SMTP_PASSWORD` | SMTP password                     | ""            |
| `SMTP_AUTH`     | SMTP authentication method        | ""            |

</details>

<details>
<summary>HTTP Configuration</summary>

| Variable          | Description                                      | Default     |
| ----------------- | ------------------------------------------------ | ----------- |
| `SERVER_PROTOCOL` | Server protocol (`http://` or `https://`)        | "http://"   |
| `SERVER_NAME`     | Server hostname                                  | "localhost" |
| `SERVER_PORT`     | Server port, 1 to 65535                          | "8080"      |
| `SCRIPT_PATH`     | Base path for the phpBB installation             | "/"         |
| `COOKIE_SECURE`   | Whether to use secure cookies: `true` or `false` | "false"     |

</details>

<details>
<summary>Proxy and Headers</summary>

| Variable                  | Description                                                                                                                                                                                        | Default              |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `TRUSTED_PROXIES`         | Proxies whose `X-Forwarded-For` gives the visitor's address: addresses or ranges, separated by spaces or commas, also recognizes `cloudflare` as a value, to use Cloudflare's pre-published ranges | "" (trusts none)     |
| `CONTENT_SECURITY_POLICY` | Replaces the image's `Content-Security-Policy` header; can't contain double quotes, backslashes, `$` or line breaks                                                                                | "" (the image's own) |

</details>

<details>
<summary>Debugging</summary>

| Variable      | Description                                                                                                              | Default |
| ------------- | ------------------------------------------------------------------------------------------------------------------------ | ------- |
| `PHPBB_DEBUG` | `true` runs phpBB in debug mode, which shows errors, stack traces and page timings to visitors; for troubleshooting only | "false" |

</details>

<details>
<summary>PHP Configuration</summary>

| Variable           | Description                                                                          | Default |
| ------------------ | ------------------------------------------------------------------------------------ | ------- |
| `PHP_MEMORY_LIMIT` | PHP's `memory_limit`                                                                 | "128M"  |
| `PHP_CUSTOM_INI`   | php.ini lines (multiple lines), applied after `PHP_MEMORY_LIMIT` and can override it | ""      |

</details>

## Data Persistence

Mount one named volume (or host directory) at `/opt/phpbb`. Everything important and mutable your
board writes lives there:

```text
/opt/phpbb/
├── phpbb.sqlite             SQLite database (when using SQLite at the default path)
├── backups/                 backups written before each upgrade (created by the first one)
└── phpbb/
    ├── config.php
    ├── files/               attachments
    ├── images/              including uploaded avatars
    ├── ext/                 extensions
    ├── styles/
    ├── language/
    ├── store/
    └── .phpbb-dist-base/    phpBB's originals of its bundled files, for merging upgrades
```

In the [Quick Start](#quick-start-its-really-that-easy), that's the `phpbb_data` volume:

```yaml
volumes:
  - phpbb_data:/opt/phpbb
```

The logs live in `/var/log/phpbb`, outside the volume; mount that separately to keep them (see
[Accessing Logs](#accessing-logs)).

The container runs as UID 100 and GID 101 unless you give it another user with `--user` (`user:` in
Compose), for example to match the owner of a host directory. `/opt/phpbb` must be writable by that
user; when it isn't, the log says so and gives the command that fixes it.

## How Upgrades Work

On every start, the image compares the phpBB version recorded in your board's database with its own.

**When the image is newer**, it upgrades the board:

1. It merges phpBB's bundled styles, language packs, extensions and images into your copies on the
   volume. This is a three-way merge against the originals your copies came from: your edits are
   kept, phpBB's changes are applied, files you added are left alone, and files you deleted stay
   deleted.
2. If one of your edits conflicts with a change phpBB made, the upgrade **stops before anything is
   changed**. The log names the file and prints the conflict. Fix the file on the volume, or put
   phpBB's original back, then restart the container. The originals are in
   `/opt/phpbb/phpbb/.phpbb-dist-base/`, or, for boards made by the older images, in
   `/usr/share/phpbb-legacy-base/` inside the image.
3. It writes a backup to `/opt/phpbb/backups/phpbb-<old version>-<time>.zip`: everything on the
   volume (except earlier backups and the merge originals) plus, for MySQL and PostgreSQL, a dump of
   the database in `database/database.sql`. If the dump fails, the backup holds the files only and
   the log says so.
4. phpBB's own command-line updater migrates the database, and then the merged files are written. If
   writing them fails, the container stops, and the next start finishes the upgrade.

**When the image is older** than the database, it refuses to start: downgrades aren't supported.
Restore a backup instead.

**When the database can't be reached**, the board starts anyway without upgrading, and the log says
so. The next start that reaches the database runs the upgrade.

### Restoring a backup

The zip holds the contents of `/opt/phpbb` as they were before the upgrade, including `phpbb.sqlite`
for SQLite boards. For MySQL and PostgreSQL, `database/database.sql` is made with phpBB's own backup
code and restores into an **empty** database:

```bash
mysql -u phpbb -p phpbb_restored < database.sql
psql -v ON_ERROR_STOP=1 -U phpbb -d phpbb_restored < database.sql
```

## Customizing phpBB

- **Styles, templates, language packs and images**: edit them on the volume
  (`/opt/phpbb/phpbb/styles/` and so on). Upgrades keep your edits and merge phpBB's changes in.
- **Extensions**: phpBB's supported way to change how the board behaves. Put them in
  `/opt/phpbb/phpbb/ext/` and enable them in the Administration Control Panel. Upgrades never touch
  extensions you added.
- **phpBB's own code, or extra files at the web root** (such as `robots.txt`): build your own image
  on top of this one. phpBB's code is read-only in the container, and edits to it on the volume
  aren't used.

  ```dockerfile
  FROM evandarwin/phpbb:3.3.19
  COPY robots.txt /var/www/phpbb/robots.txt
  COPY patches/includes/functions.php /var/www/phpbb/includes/functions.php
  ```

  Pin the tag you build from, and port your patches to each new phpBB release before rebuilding:
  your copies replace phpBB's files and are not merged.

## Custom PHP Configuration

You can customize your PHP settings by providing PHP.ini directives through the `PHP_CUSTOM_INI`
environment variable:

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHP_CUSTOM_INI="upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 60" \
  evandarwin/phpbb:latest
```

They're applied on every start, after the image's own settings and `PHP_MEMORY_LIMIT`, so they can
override both. Raising `post_max_size` also raises the web server's request size limit, which always
follows it. PHP reports a value it can't use in the log and ignores it; after a syntax error, it
ignores the lines that follow as well. You can also mount an `.ini` file into `/etc/php84/conf.d/`.

## Real-World Examples

<details>
<summary>MySQL or MariaDB Setup (Most Common)</summary>

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_DATABASE_DRIVER="mysqli" \
  -e PHPBB_DATABASE_HOST="mysql_container" \
  -e PHPBB_DATABASE_NAME="phpbb_db" \
  -e PHPBB_DATABASE_USER="phpbb_user" \
  -e PHPBB_DATABASE_PASSWORD="secure_password" \
  evandarwin/phpbb:latest
```

</details>

<details>
<summary>PostgreSQL Setup</summary>

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_DATABASE_DRIVER="postgres" \
  -e PHPBB_DATABASE_HOST="postgres_container" \
  -e PHPBB_DATABASE_NAME="phpbb_db" \
  -e PHPBB_DATABASE_USER="phpbb_user" \
  -e PHPBB_DATABASE_PASSWORD="secure_password" \
  evandarwin/phpbb:latest
```

</details>

<details>
<summary>SQLite Setup (Great for Small Forums)</summary>

SQLite is the default, stored at `/opt/phpbb/phpbb.sqlite` on the volume:

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  evandarwin/phpbb:latest
```

</details>

<details>
<summary>Complete Setup with Email</summary>

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_EMAIL="admin@example.com" \
  -e SMTP_HOST="smtp.example.com" \
  -e SMTP_PORT="587" \
  -e SMTP_USER="smtp_user" \
  -e SMTP_PASSWORD="smtp_password" \
  -e PHPBB_DATABASE_DRIVER="mysqli" \
  -e PHPBB_DATABASE_HOST="mysql_container" \
  -e PHPBB_DATABASE_NAME="phpbb_db" \
  -e PHPBB_DATABASE_USER="phpbb_user" \
  -e PHPBB_DATABASE_PASSWORD="secure_password" \
  evandarwin/phpbb:latest
```

</details>

## Building Your Own Images

You can build your own phpBB Docker images using the provided build script:

```bash
PHPBB_VERSION=3.3.19 ./scripts/build.sh
```

Without `PHPBB_VERSION`, the script picks the newest release tag on phpBB's GitHub, which can be a
pre-release, so set it explicitly. The build fails if phpBB can't be downloaded.

To choose the PHP version, build with Docker directly; PHP 8.4 is the default:

```bash
docker build --build-arg PHPBB_VERSION=3.3.19 --build-arg PHP_VERSION=8.5 .
```

## Using Behind a Reverse Proxy

When using this container behind a reverse proxy like Traefik or Nginx:

1. Set the `SERVER_NAME` to your domain name
2. Set `SERVER_PROTOCOL` to `https://` if using SSL/TLS
3. Set `COOKIE_SECURE=true` for secure cookies
4. Set `TRUSTED_PROXIES` to your proxy's address or network (or `cloudflare` behind Cloudflare), so
   phpBB sees each visitor's address instead of the proxy's. Nothing is trusted by default, because
   a trusted `X-Forwarded-For` lets anyone who can reach the container directly pick their address.

<details>
<summary>Traefik, in a container</summary>

Traefik reaches the forum over a shared Docker network, and the forum publishes no port, so only
containers on that network can connect to it. Create the network once with a fixed range:

```sh
docker network create --subnet 172.30.0.0/24 proxy
```

```yaml
services:
  phpbb:
    image: evandarwin/phpbb:latest
    environment:
      - SERVER_NAME=forums.example.com
      - SERVER_PROTOCOL=https://
      - COOKIE_SECURE=true
      - TRUSTED_PROXIES=172.30.0.0/24
      # Other configuration...
    networks:
      - proxy
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.phpbb.rule=Host(`forums.example.com`)'
      - 'traefik.http.routers.phpbb.entrypoints=websecure'
      - 'traefik.http.routers.phpbb.tls=true'

networks:
  proxy:
    external: true
```

</details>

<details>
<summary>nginx, on the host</summary>

The forum's port is published on `127.0.0.1` only, so nothing outside the host can reach it. The
host's nginx connects through that port and arrives from the gateway of the forum's Docker network,
so the network gets a fixed range, and its gateway, `172.30.0.1`, is the trusted proxy:

```yaml
services:
  phpbb:
    image: evandarwin/phpbb:latest
    ports:
      - '127.0.0.1:8080:8080'
    environment:
      - SERVER_NAME=forums.example.com
      - SERVER_PROTOCOL=https://
      - COOKIE_SECURE=true
      - TRUSTED_PROXIES=172.30.0.1
      # Other configuration...

networks:
  default:
    ipam:
      config:
        - subnet: 172.30.0.0/24
```

nginx passes the visitor's headers through unchanged except `Host`, so forward it exactly, and add
the visitor's address to `X-Forwarded-For`. The forum's nginx takes the visitor's address from there
and ignores anything a visitor added themselves:

```nginx
server {
  listen 443 ssl;
  server_name forums.example.com;
  # ssl_certificate ...

  # The forum accepts requests up to PHP's post_max_size (32M by default)
  client_max_body_size 32m;

  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
```

</details>

## Security Best Practices

This Docker image implements numerous security best practices:

- **Non-root execution**: All processes run as a non-privileged user
- **Read-only code**: phpBB's code is owned by root, so the board can't modify it
- **No web installer**: `/install/` is blocked; installs and upgrades run from the command line
- **Security headers**: Comprehensive set of headers to protect against XSS, clickjacking, and more
- **Protected sensitive files**: Nginx blocks access to configuration and system files, following
  phpBB's own Nginx sample configuration
- **PHP hardening**: Restricted functions, open_basedir limitations, and proper error handling
- **Secure default settings**: Sensible security defaults that don't sacrifice usability
- Automated security scanning with **Docker Scout**
- CI uses pinned actions, and is run daily to rebuild each tag with security updates daily

## SQLite Database Location

By default, the SQLite database is stored at `/opt/phpbb/phpbb.sqlite`. That's on the volume, so it
persists, and outside everything the web server serves, so it can't be downloaded.

If you set `PHPBB_DATABASE_SQLITE_PATH` yourself:

- Keep it under `/opt/phpbb`. PHP may only open files there, in `/tmp` and in two directories of the
  image, and only `/opt/phpbb` is kept when the container is recreated.
- Don't put it directly in `/opt/phpbb/phpbb/`; the installer refuses that path.

As a last line of defense, the Nginx configuration also refuses to serve `.sqlite`, `.sqlite3`,
`.db` and `.sql` files anywhere.

## Container Health Monitoring

This Docker image includes a built-in health check. It:

- Runs every 30 seconds after a 30-second startup period
- Asks PHP-FPM for its status through nginx, so it fails if either one stops; it uses a socket
  inside the container, so it takes no port
- Doesn't touch the database, so a database outage doesn't mark the container unhealthy

This is particularly useful when using the container with orchestration systems like Docker Swarm,
Kubernetes, or Docker Compose with health checks.

## Troubleshooting Tips

### Common Issues and Solutions

1. **Database Connection Errors**:

   - Double-check your database credentials and connection settings
   - Verify network connectivity between containers
   - For MySQL, ensure the user has proper privileges
   - A new install needs the database to be reachable; an existing board starts without it (see
     [How Upgrades Work](#how-upgrades-work))

2. **An Upgrade Stopped With a Conflict**:

   - The log names the file and prints the conflicting lines; nothing was changed
   - Fix the file on the volume, or put phpBB's original back (see
     [How Upgrades Work](#how-upgrades-work)), then restart the container

3. **Permission Issues**:

   - The container runs as UID 100 and GID 101 by default, or as the user you give it with `--user`;
     `/opt/phpbb` must be writable by that user, and the log gives the command that fixes it when it
     isn't

4. **PHP Configuration**:

   - Use `PHP_CUSTOM_INI`, or mount an `.ini` file into `/etc/php84/conf.d/` (see
     [Custom PHP Configuration](#custom-php-configuration))

5. **Nginx Logs**:
   - Container logs include nginx access and error logs
   - You can view them with `docker logs <container_name>`

### Accessing Logs

nginx's access and error logs and PHP-FPM's error log are written to `/var/log/phpbb`, which you can
mount on its own to keep them, and every new line is also forwarded to the Docker logging system. If
`/var/log/phpbb` isn't writable, they go to the Docker logging system only:

```bash
# View all logs
docker logs <container_name>

# View only recent logs
docker logs --tail 100 <container_name>

# Follow logs in real-time
docker logs -f <container_name>
```

## Running the Tests

`tests/run.sh` builds the image (and an older one to upgrade from) and runs every `tests/test_*.sh`
against real containers: fresh installs, installer input, the read-only code and blocked paths, and
upgrades of SQLite, MariaDB, MySQL and PostgreSQL boards. It needs Docker and network access.

```bash
tests/run.sh                          # every test
tests/run.sh tests/test_security.sh   # just these
```

## Need Help or Want to Contribute?

Contributions are always welcome! Whether it's reporting bugs, suggesting features, or submitting
pull requests, your input helps make this project better for everyone.

If you're using this image in production, I'd love to hear about your experience!

## License

Licensed under the [MIT license](./LICENSE). This license applies to the Docker container only.

phpBB itself is licensed under GPL-2.0: https://www.phpbb.com/downloads/license/
