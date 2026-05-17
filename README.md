# evandarwin/phpbb-docker

[![Docker Pulls](https://img.shields.io/docker/pulls/evandarwin/phpbb.svg)](https://hub.docker.com/r/evandarwin/phpbb)
[![Docker Image Size](https://img.shields.io/docker/image-size/evandarwin/phpbb/latest)](https://hub.docker.com/r/evandarwin/phpbb)
[![License](https://img.shields.io/github/license/evandarwin/docker-phpbb)](https://github.com/evandarwin/docker-phpbb/blob/main/LICENSE)
[![Latest Release](https://img.shields.io/github/v/tag/evandarwin/docker-phpbb?label=version)](https://github.com/evandarwin/docker-phpbb/releases)
[![Docker Stars](https://img.shields.io/docker/stars/evandarwin/phpbb.svg)](https://hub.docker.com/r/evandarwin/phpbb)

Looking for a modern, secure, and hassle-free way to run phpBB in Docker? You've found it! This
image offers a thoughtfully pre-configured phpBB environment that's ready for production use with
minimal setup.

## Why Choose This Image?

After Bitnami/Broadcom deprecated their official phpBB container (which had become outdated), I
created this project to give the community a modern alternative that prioritizes:

- **Security**: Runs as non-root, includes hardened Nginx config, secure headers, and protection
  against common attacks
- **Performance**: Pre-configured with PHP opcache, Nginx (instead of Apache), and optimized
  settings
- **Simplicity**: Works out-of-the-box with sensible defaults while remaining highly customizable
- **Flexibility**: Supports MySQL, PostgreSQL, and SQLite with easy configuration
- **Currency**: Daily builds ensure you always have the latest phpBB version and security patches

## Quick Start (It's Really That Easy!)

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Awesome Forum" \
  -e PHPBB_DATABASE_HOST="db" \
  -e PHPBB_DATABASE_NAME="phpbb" \
  -e PHPBB_DATABASE_USER="phpbb" \
  -e PHPBB_DATABASE_PASSWORD="secret" \
  evandarwin/phpbb:latest
```

Then just open http://localhost:8080 in your browser, and you're ready to go!

## Available Tags

- `latest` - Latest phpBB version with all the good stuff
- `<version>` - Specific phpBB version (e.g., `3.3.15`)
- `<major>.<minor>` - Latest patch version of a minor release (e.g., `3.3`)
- `<major>` - Latest minor.patch version of a major release (e.g., `3`)

All images are built on Alpine Linux for minimal size and maximum security.

## Pre-Configured Features You'll Love

This image comes with numerous thoughtful pre-configurations that save you time and enhance
security:

### 🛡️ Security Enhancements

- **Defense in Depth**: Multiple layers of protection including:
  - Non-root execution with proper file permissions
  - Protection against common web attacks
  - Nginx configuration to protect sensitive files and directories
  - Disabled dangerous PHP functions like `exec` and `shell_exec`
  - Open basedir restrictions to limit file access

### ⚡ Performance Optimizations

- **PHP Opcache**: Pre-configured for optimal performance
- **Nginx**: Lightweight and fast web server with optimized settings
- **Static File Caching**: Properly configured for optimal browser caching
- **Tuned PHP Settings**: Balanced for good performance while maintaining stability

### 🧰 Convenience Features

- **Auto-configuration**: Just set environment variables and go
- **Multi-DB Support**: Choose MySQL, PostgreSQL, or SQLite based on your needs
- **Health Checks**: Built-in container health monitoring
- **Smart Defaults**: Works out-of-the-box, but remains highly customizable

## Required Environment Variables

This container requires the following environment variables to be set for proper operation:

- `PHPBB_USERNAME`: Username for the administrative user (required for first installation)
- `PHPBB_PASSWORD`: Password for the administrative user (required for first installation)

These variables are mandatory for generating the database during first initialization.

> **Note about password generation**: If `PHPBB_PASSWORD` is omitted, a secure random password will
> be automatically generated and printed in the console logs during first startup. Be sure to check
> the logs with `docker logs container_name` to retrieve this password, as it will only be shown
> once and cannot be recovered later.
>
> **Important**: phpBB has a maximum password length of 30 characters. Passwords longer than this
> will be rejected during user creation.

By default, the container uses a SQLite database configuration that is automatically written to the
mounted volume at `/opt/phpbb/phpbb.sqlite` unless you specify a different database configuration.
This provides a simple setup with minimal configuration while ensuring your data is properly
persisted.

## Environment Variables

The following environment variables can be used to configure the initial phpBB installation.
Note that only the PHP configuration variables have any effect if you already have
an existing `config.php` (with database connection information) and database from a previous installation.

### Forum Configuration

| Variable                  | Description                         | Default          |
| ------------------------- | ----------------------------------- | ---------------- |
| `PHPBB_FORUM_NAME`        | Name of the forum                   | "My phpBB Forum" |
| `PHPBB_FORUM_DESCRIPTION` | Description of the forum            | "A phpBB Forum"  |
| `PHPBB_LANGUAGE`          | Language for the phpBB installation | "en"             |

### Admin User

| Variable           | Description                                     | Default                      |
| ------------------ | ----------------------------------------------- | ---------------------------- |
| `PHPBB_USERNAME`   | Username for the administrative user (Required) | "admin"                      |
| `PHPBB_PASSWORD`   | Password for the admin user (Required)          | "" (auto-generated if empty) |
| `PHPBB_FIRST_NAME` | First name of the admin user                    | "Admin"                      |
| `PHPBB_LAST_NAME`  | Last name of the admin user                     | "User"                       |
| `PHPBB_EMAIL`      | Admin user email                                | "admin@example.com"          |

### Database Configuration

| Variable                                           | Description                                                      | Default                   |
| -------------------------------------------------- | ---------------------------------------------------------------- | ------------------------- |
| `PHPBB_DATABASE_DRIVER`                            | Database driver type (see note below)                            | "sqlite3"                 |
| `PHPBB_DATABASE_HOST`                              | Database host address                                            | "localhost"               |
| `PHPBB_DATABASE_PORT`                              | Database port                                                    | "" (uses default port)    |
| `PHPBB_DATABASE_NAME`                              | Database name                                                    | "phpbb"                   |
| `PHPBB_DATABASE_USER` or `PHPBB_DATABASE_USERNAME` | Database username                                                | "phpbb_user"              |
| `PHPBB_DATABASE_PASSWORD` or `PHPBB_DATABASE_PASS` | Database password                                                | ""                        |
| `PHPBB_DATABASE_SQLITE_PATH`                       | Full path for SQLite database file (used when driver is sqlite3) | "/opt/phpbb/phpbb.sqlite" |
| `PHPBB_TABLE_PREFIX`                               | Prefix for database tables                                       | "phpbb\_"                 |

### Email / SMTP

| Variable                     | Description                | Default       |
| ---------------------------- | -------------------------- | ------------- |
| **Email/SMTP Configuration** |                            |               |
| `SMTP_HOST`                  | SMTP server address        | "" (disabled) |
| `SMTP_PORT`                  | SMTP server port           | "25"          |
| `SMTP_USER`                  | SMTP username              | ""            |
| `SMTP_PASSWORD`              | SMTP password              | ""            |
| `SMTP_AUTH`                  | SMTP authentication method | ""            |
| `SMTP_PROTOCOL`              | SMTP protocol              | ""            |

### HTTP Configuration

| Variable          | Description                           | Default     |
| ----------------- | ------------------------------------- | ----------- |
| `SERVER_PROTOCOL` | Server protocol (http:// or https://) | "http://"   |
| `SERVER_NAME`     | Server hostname                       | "localhost" |
| `SERVER_PORT`     | Server port                           | "80"        |
| `SCRIPT_PATH`     | Base path for the phpBB installation  | "/"         |
| `COOKIE_SECURE`   | Whether to use secure cookies         | "false"     |

### PHP Configuration

| Variable           | Description                                | Default |
| ------------------ | ------------------------------------------ | ------- |
| `PHP_MEMORY_LIMIT` | PHP memory limit                           | "128M"  |
| `PHP_CUSTOM_INI`   | Custom PHP.ini directives (multiple lines) | ""      |

## Data Persistence

There are two main approaches to persist your phpBB data:

### 1. Simple Volume Mounting

Mount a single volume to keep everything in one place:

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Awesome Forum" \
  -e PHPBB_DATABASE_HOST="db" \
  -e PHPBB_DATABASE_NAME="phpbb" \
  -e PHPBB_DATABASE_USER="phpbb" \
  -e PHPBB_DATABASE_PASSWORD="secret" \
  evandarwin/phpbb:latest
```

### 2. Granular Control with Multiple Volumes (Upgrade Path)

For more control over specific data directories:

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_config:/opt/phpbb/config \
  -v phpbb_store:/opt/phpbb/phpbb/store \
  -v phpbb_files:/opt/phpbb/phpbb/files \
  -v phpbb_images:/opt/phpbb/phpbb/images \
  -v phpbb_ext:/opt/phpbb/phpbb/ext \
  -v phpbb_style:/opt/phpbb/phpbb/styles \
  -e PHPBB_DATABASE_HOST="db" \
  -e PHPBB_DATABASE_NAME="phpbb" \
  -e PHPBB_DATABASE_USER="phpbb" \
  -e PHPBB_DATABASE_PASSWORD="secret" \
  evandarwin/phpbb:latest
```
Here, the /opt/phpbb/config directory is used to persist the `config.php` file only, it is copied to/from there during container startup/installation.
The `store`, `files` and `images` folders should be persisted; adding `ext` and `styles` folders gives you the option to install custom extensions and styles.

The `config.php` needs to be a local file with initial write permissions for the first setup.
The write permissions need to be for the phpbb user in the container, likely UID 100, GUID 101, see also [Issue #3](https://github.com/EvanDarwin/phpbb-docker/issues/3).
Once the initial installation ran and setup created the database tables and `config.php`, the `config` folder can also be mounted read-only:
```bash
docker ... -v phpbb_config:/opt/phpbb/config:ro ...
```

If you have (a backup of) an existing installation with database and config.php, you can restore these folders and the database from the backup.

## Upgrade path
If you mount the full `/opt/phpbb` folder persistently (option 1 above), the docker container will not upgrade to new versions correctly (at least as of now), since the volume mount hides the updated forum files of the container.

However, if you choose option 2 to mount only the `config.php` and folders `store`, `files` and `images` persistently, and optionally `ext` and `styles`,
then upgrading the docker volume is equivalent to a [full upgrade](https://www.phpbb.com/support/docs/en/3.3/ug/upgradeguide/update_full/).

In that case, the container is setup to automatically perform database migrations as well on startup.

## Custom PHP Configuration

You can customize your PHP settings by providing PHP.ini directives through the `PHP_CUSTOM_INI`
environment variable:

```bash
docker run -d \
  -p 8080:8080 \
  -v phpbb_data:/opt/phpbb \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_DATABASE_HOST="mysql_container" \
  -e PHPBB_DATABASE_NAME="phpbb_db" \
  -e PHPBB_DATABASE_USER="phpbb_user" \
  -e PHPBB_DATABASE_PASSWORD="secure_password" \
  -e PHP_CUSTOM_INI="upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 60" \
  evandarwin/phpbb:latest
```

These directives will be appended to the PHP.ini file during container startup.

## Real-World Examples

### MySQL Setup (Most Common)

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

### PostgreSQL Setup

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

### SQLite Setup (Great for Small Forums)

```bash
docker run -d \
  -p 8080:8080 \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_DATABASE_DRIVER="sqlite3" \
  -e PHPBB_DATABASE_SQLITE_PATH="/opt/phpbb/data/phpbb.sqlite3" \
  -v phpbb_data:/opt/phpbb \
  evandarwin/phpbb:latest
```

### Complete Setup with Email

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
  -e PHPBB_DATABASE_HOST="mysql_container" \
  -e PHPBB_DATABASE_NAME="phpbb_db" \
  -e PHPBB_DATABASE_USER="phpbb_user" \
  -e PHPBB_DATABASE_PASSWORD="secure_password" \
  evandarwin/phpbb:latest
```

## Building Your Own Images

You can build your own phpBB Docker images using the provided build script:

```bash
# Build the latest phpBB with PHP 8.4
./scripts/build.sh

# Build a specific phpBB version
PHPBB_VERSION=3.3.10 ./scripts/build.sh
```

The build script automatically fetches the latest phpBB release version from GitHub if you don't
specify a version.

## Docker Compose Example (Production-Ready)

Here's a complete example using Docker Compose with MySQL:

```yaml
volumes:
  phpbb_config:
  phpbb_files:
  phpbb_store:
  phpbb_images:
  phpbb_ext:
  phpbb_styles:
  mysql_data:

networks:
  phpbb-net:
    driver: bridge

services:
  phpbb:
    image: evandarwin/phpbb:latest
    ports:
      - '8080:8080'
    environment:
      PHPBB_FORUM_NAME: My Amazing Forum
      PHPBB_FORUM_DESCRIPTION: Welcome to my phpBB forum
      PHPBB_USERNAME: admin
      PHPBB_PASSWORD: secure_password # <- CHANGE THIS!
      PHPBB_EMAIL: admin@example.com
      PHPBB_DATABASE_DRIVER: mysqli
      PHPBB_DATABASE_HOST: mysql
      PHPBB_DATABASE_NAME: phpbb
      PHPBB_DATABASE_USER: phpbb
      PHPBB_DATABASE_PASSWORD: mysql_password # <- CHANGE THIS!
      SERVER_NAME: forums.example.com
      COOKIE_SECURE: false
    volumes:
      - phpbb_config:/opt/phpbb/config  # other path: no typo! should only contain config.php
      - phpbb_files:/opt/phpbb/phpbb/files
      - phpbb_store:/opt/phpbb/phpbb/store
      - phpbb_images:/opt/phpbb/phpbb/images
      - phpbb_ext:/opt/phpbb/phpbb/ext  # optional
      - phpbb_styles:/opt/phpbb/phpbb/styles  # optional
    depends_on:
      - mysql
    restart: unless-stopped
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:8080/']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - phpbb-net

  mysql:
    image: mariadb:latest
    environment:
      MARIADB_RANDOM_ROOT_PASSWORD: yes
      MARIADB_DATABASE: phpbb
      MARIADB_USER: phpbb
      MARIADB_PASSWORD: mysql_password # <- CHANGE THIS!
    volumes:
      - mysql_data:/var/lib/mysql
    restart: unless-stopped
    networks:
      - phpbb-net
```

For PostgreSQL, replace the MySQL service with:

```yaml
postgres:
  image: postgres:15
  environment:
    POSTGRES_PASSWORD: postgres_password
    POSTGRES_USER: phpbb
    POSTGRES_DB: phpbb
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

## Using Behind a Reverse Proxy

When using this container behind a reverse proxy like Traefik or Nginx:

1. Set the `SERVER_NAME` to your domain name
2. Set `SERVER_PROTOCOL` to `https://` if using SSL/TLS
3. Set `COOKIE_SECURE=true` for secure cookies

Example Docker Compose configuration with Traefik:

```yaml
services:
  phpbb:
    image: evandarwin/phpbb:latest
    environment:
      - SERVER_NAME=forums.example.com
      - SERVER_PROTOCOL=https://
      - COOKIE_SECURE=true
      # Other configuration...
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.phpbb.rule=Host(`forums.example.com`)'
      - 'traefik.http.routers.phpbb.entrypoints=websecure'
      - 'traefik.http.routers.phpbb.tls=true'
```

## Security Best Practices

This Docker image implements numerous security best practices:

- **Non-root execution**: All processes run as a non-privileged user
- **Security headers**: Comprehensive set of headers to protect against XSS, clickjacking, and more
- **Protected sensitive files**: Nginx blocks access to configuration and system files
- **PHP hardening**: Restricted functions, open_basedir limitations, and proper error handling
- **Secure default settings**: Sensible security defaults that don't sacrifice usability

## SQLite Database Security

### IMPORTANT: Secure Storage of SQLite Databases

When using SQLite as your database driver, it's **critically important** to store your database file
outside of the publicly accessible web directory.

The launcher script will reject it by default if it detects it; but... you know users. We also make
a best effort to prevent distributing files with database extensions at all, denied through the
nginx configuration (.sql, .db, et al).

#### Security Risks

Storing SQLite database files in publicly accessible locations presents severe security risks:

- **Data Theft**: If an attacker can directly download your .sqlite or .db file, they gain access to
  all forum data including user credentials
- **Data Manipulation**: Unauthorized modification of your database could lead to account takeovers
- **Privacy Violations**: Personal user information could be exposed, potentially violating privacy
  laws

#### Recommendations

1. Store your SQLite database in a directory that is:

   - NOT accessible from the web
   - NOT inside the `/opt/phpbb` public directory structure
   - Properly permission-restricted

2. When using the `PHPBB_DATABASE_SQLITE_PATH` environment variable:

   - Use a path like `/var/lib/phpbb/data/phpbb.sqlite3`
   - NEVER use a path within the phpBB root directory
   - The container is configured to reject SQLite paths that contain the phpBB root directory

3. Use volume mounting to persist your SQLite database:

```bash
docker run -d \
  -p 8080:8080 \
  -e PHPBB_FORUM_NAME="My Community" \
  -e PHPBB_DATABASE_DRIVER="sqlite3" \
  -e PHPBB_DATABASE_SQLITE_PATH="/var/lib/phpbb/data/phpbb.sqlite3" \
  -v phpbb_sqlite_data:/var/lib/phpbb/data \
  -v phpbb_data:/opt/phpbb \
  evandarwin/phpbb:latest
```

#### Additional Protection

The nginx configuration in this container will automatically block access to any .sqlite or .db
files, but this should be considered a last line of defense rather than your primary security
measure.

## Container Health Monitoring

This Docker image includes a built-in health check that verifies the web server is responding
properly. The health check:

- Runs every 30 seconds after a 30-second startup period
- Verifies that the Nginx web server is running and responding to HTTP requests
- Will automatically mark the container as unhealthy if the web server stops responding

This is particularly useful when using the container with orchestration systems like Docker Swarm,
Kubernetes, or Docker Compose with health checks.

## Troubleshooting Tips

### Common Issues and Solutions

1. **Database Connection Errors**:

   - Double-check your database credentials and connection settings
   - Verify network connectivity between containers
   - For MySQL, ensure the user has proper privileges

2. **Permission Issues**:

   - If mounting volumes, ensure they have the correct ownership and permissions
   - The container uses a non-root user with UID/GID different from the host, by default 100/101.
   - Docker populates *empty* volumes (but not mounts!) with the pre-existing folders.
   - Use a different entrypoint, e.g. `docker compose run --entrypoint sh -it phpbb` to trouble-shoot permissions in the volumes.

3. **PHP Configuration**:

   - If you need to adjust PHP settings beyond what's available through environment variables, you
     can mount a custom php.ini file

4. **Nginx Logs**:
   - Container logs include nginx access and error logs
   - You can view them with `docker logs <container_name>`

### Accessing Logs

All logs are forwarded to the Docker logging system:

```bash
# View all logs
docker logs <container_name>

# View only recent logs
docker logs --tail 100 <container_name>

# Follow logs in real-time
docker logs -f <container_name>
```

## Need Help or Want to Contribute?

Contributions are always welcome! Whether it's reporting bugs, suggesting features, or submitting
pull requests, your input helps make this project better for everyone.

If you're using this image in production, I'd love to hear about your experience!
