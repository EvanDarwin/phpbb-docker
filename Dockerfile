FROM alpine:3.24

ARG PHPBB_VERSION
ARG PHP_VERSION=8.4
ENV PHP_VERSION="${PHP_VERSION/./}"
ENV PHPBB_ROOT="/opt/phpbb"
ENV PHPBB_CODE="/var/www/phpbb"
ENV PHPBB_DIST="/usr/share/phpbb-dist"
ENV PHPBB_LEGACY_BASE="/usr/share/phpbb-legacy-base"
ENV PHPBB_VERSION="${PHPBB_VERSION}"

# phpBB configuration environment variables
ENV PHPBB_FORUM_NAME="My phpBB Forum" \
    PHPBB_FORUM_DESCRIPTION="A phpBB Forum" \
    PHPBB_USERNAME="admin" \
    PHPBB_PASSWORD="" \
    PHPBB_EMAIL="admin@example.com" \
    PHPBB_DATABASE_DRIVER="sqlite3" \
    PHPBB_DATABASE_SQLITE_PATH="${PHPBB_ROOT}/phpbb.sqlite" \
    PHPBB_DATABASE_HOST="localhost" \
    PHPBB_DATABASE_NAME="" \
    PHPBB_DATABASE_USER="" \
    PHPBB_DATABASE_USERNAME="" \
    PHPBB_DATABASE_PASSWORD="" \
    PHPBB_DATABASE_PASS="" \
    SMTP_HOST="" \
    SMTP_PORT="25" \
    SMTP_USER="" \
    SMTP_PASSWORD="" \
    SERVER_PROTOCOL="http://" \
    SERVER_NAME="localhost" \
    SERVER_PORT="8080" \
    SCRIPT_PATH="/" \
    COOKIE_SECURE="false" \
    PHPBB_DEBUG="false" \
    TRUSTED_PROXIES="" \
    CONTENT_SECURITY_POLICY="" \
    PHP_MEMORY_LIMIT="128M" \
    PHP_CUSTOM_INI=""

# Create non-root user for running the application
RUN addgroup -S phpbb && \
    adduser -S -G phpbb -H -h ${PHPBB_ROOT} phpbb && \
    mkdir -p ${PHPBB_ROOT} /opt/.docker && \
    chown -R phpbb:phpbb ${PHPBB_ROOT}

# Group packages by functionality for better organization and layer efficiency
RUN apk update && \
    # OPcache is built into PHP from 8.5; earlier versions ship it as a package
    opcache=$([ "$PHP_VERSION" -ge 85 ] || echo "php${PHP_VERSION}-opcache") && \
    # Core PHP packages
    apk add --virtual .php-deps --no-cache \
    php${PHP_VERSION} \
    php${PHP_VERSION}-fpm \
    # Database drivers
    php${PHP_VERSION}-pdo \
    php${PHP_VERSION}-pdo_mysql \
    php${PHP_VERSION}-pdo_pgsql \
    php${PHP_VERSION}-pdo_sqlite \
    php${PHP_VERSION}-mysqli \
    php${PHP_VERSION}-sqlite3 \
    php${PHP_VERSION}-pgsql \
    # Content processing
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-sodium \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-exif \
    php${PHP_VERSION}-fileinfo \
    php${PHP_VERSION}-dom \
    # Performance and security
    $opcache \
    php${PHP_VERSION}-session \
    php${PHP_VERSION}-simplexml \
    php${PHP_VERSION}-ctype \
    php${PHP_VERSION}-openssl \
    php${PHP_VERSION}-tokenizer \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-pecl-imagick && \
    # Install web server, tools, and database clients (needed for runtime)
    apk add --no-cache \
    nginx \
    curl \
    diffutils \
    unzip \
    ca-certificates \
    mysql-client \
    postgresql-client \
    sqlite && \
    # Cleanup to reduce layer size
    rm -rf /var/cache/apk/*

# PHP also reads the settings the entrypoint writes from PHP_MEMORY_LIMIT and
# PHP_CUSTOM_INI, after its own conf.d (which the leading colon keeps)
ENV PHP_INI_SCAN_DIR=":/run/php-fpm/conf.d"

# Configure PHP-FPM and security settings
RUN sed -i "s/user = nobody/user = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    sed -i "s/group = nobody/group = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    echo "security.limit_extensions = .php" >> /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    echo "ping.path = /fpm-ping" >> /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    sed -i "s|^listen = 127.0.0.1:9000$|listen = /run/php-fpm/php-fpm.sock|" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    grep -q "^listen = /run/php-fpm/php-fpm.sock$" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    # Logs go to links the entrypoint points at /var/log/phpbb, or at the container's
    # output when that can't be written
    sed -i "s|^;error_log = log/php${PHP_VERSION}/error.log$|error_log = /run/php-fpm/error.log|" /etc/php${PHP_VERSION}/php-fpm.conf && \
    grep -q "^error_log = /run/php-fpm/error.log$" /etc/php${PHP_VERSION}/php-fpm.conf && \
    sed -i "s|/var/log/nginx/error.log|/run/nginx/error.log|; s|/var/log/nginx/access.log|/run/nginx/access.log|" /etc/nginx/nginx.conf && \
    ! grep -q "/var/log/nginx/" /etc/nginx/nginx.conf && \
    # Optimize PHP with opcache for better performance
    echo "opcache.memory_consumption=128" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.interned_strings_buffer=8" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.max_accelerated_files=4000" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.revalidate_freq=60" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.fast_shutdown=1" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.enable_cli=0" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.validate_timestamps=1" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    echo "opcache.save_comments=1" >> /etc/php${PHP_VERSION}/conf.d/00_opcache.ini && \
    # Set PHP security configuration
    echo "disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,eval" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "open_basedir = ${PHPBB_CODE}:${PHPBB_ROOT}:/var/cache/phpbb:/tmp" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "expose_php = Off" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "max_execution_time = 30" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "memory_limit = 128M" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "post_max_size = 32M" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "upload_max_filesize = 24M" >> /etc/php${PHP_VERSION}/php.ini && \
    # Create necessary directories with proper permissions
    mkdir -p /var/lib/nginx /var/log/nginx /var/log/phpbb /run/nginx /run/php-fpm/conf.d && \
    chown -R phpbb:phpbb /var/lib/nginx /var/log/nginx /var/log/phpbb /run/nginx /run/php-fpm && \
    # Writable by whichever user the container runs as (--user), like /tmp
    chmod 755 /var/lib/nginx && \
    chmod 1777 /var/lib/nginx/tmp /var/log/nginx /var/log/phpbb /run/nginx /run/php-fpm /run/php-fpm/conf.d && \
    touch /run/nginx.pid && \
    chown phpbb:phpbb /run/nginx.pid

# Copy scripts and configurations
COPY scripts/docker-entrypoint.sh scripts/install-from-yml.sh scripts/update-cloudflare-ips.sh /opt/.docker/
COPY config/nginx.conf /etc/nginx/http.d/default.conf
COPY patches/ /tmp/phpbb-patches/

# Install phpBB's code read-only (owned by root) at PHPBB_CODE. Everything a board
# writes lives on the PHPBB_ROOT volume, in the same layout earlier versions of this
# image used, and is linked into the code tree. Pristine copies of those files are
# kept in PHPBB_DIST to populate new volumes and to merge phpBB's updated styles,
# language packs, extensions and images into the volume on upgrade. Every earlier
# image of this project shipped phpBB 3.3.15, so that release's pristine copies are
# kept in PHPBB_LEGACY_BASE as the merge base for their volumes. The cache stays in
# the container.
RUN set -e; \
    if [ -z "${PHPBB_VERSION}" ]; then echo "ERROR: PHPBB_VERSION build argument is not set"; exit 1; fi; \
    MAJOR_MINOR_VERSION=$(echo "${PHPBB_VERSION}" | grep -oE '^[0-9]+\.[0-9]+'); \
    DOWNLOAD_URL="https://download.phpbb.com/pub/release/${MAJOR_MINOR_VERSION}/${PHPBB_VERSION}/phpBB-${PHPBB_VERSION}.zip"; \
    echo "Downloading from: ${DOWNLOAD_URL}"; \
    cd /tmp; \
    curl -fsSL -o phpbb.zip "${DOWNLOAD_URL}"; \
    unzip -q phpbb.zip; \
    rm phpbb.zip; \
    test -f phpBB3/index.php; \
    mkdir -p "$(dirname "${PHPBB_CODE}")" "${PHPBB_DIST}"; \
    mv phpBB3 "${PHPBB_CODE}"; \
    # Fixes to phpBB for this image's layout; the build fails unless each applies exactly
    apk add --no-cache --virtual .patch patch; \
    for p in /tmp/phpbb-patches/*.patch; do patch -p1 --forward --fuzz=0 -d "${PHPBB_CODE}" < "$p"; done; \
    apk del .patch; \
    rm -rf /tmp/phpbb-patches; \
    for item in store files images ext styles language config.php; do mv "${PHPBB_CODE}/$item" "${PHPBB_DIST}/$item"; done; \
    rm -rf "${PHPBB_CODE}/cache"; \
    LEGACY_BASE_VERSION=3.3.15; \
    mkdir -p "${PHPBB_LEGACY_BASE}"; \
    if [ "${PHPBB_VERSION}" = "${LEGACY_BASE_VERSION}" ]; then \
      for dir in styles language ext images; do cp -R "${PHPBB_DIST}/$dir" "${PHPBB_LEGACY_BASE}/$dir"; done; \
    else \
      curl -fsSL -o legacy.zip "https://download.phpbb.com/pub/release/3.3/${LEGACY_BASE_VERSION}/phpBB-${LEGACY_BASE_VERSION}.zip"; \
      unzip -q legacy.zip 'phpBB3/styles/*' 'phpBB3/language/*' 'phpBB3/ext/*' 'phpBB3/images/*'; \
      for dir in styles language ext images; do mv "phpBB3/$dir" "${PHPBB_LEGACY_BASE}/$dir"; done; \
      rm -rf legacy.zip phpBB3; \
    fi; \
    echo "${LEGACY_BASE_VERSION}" > "${PHPBB_LEGACY_BASE}/VERSION"; \
    # The board can't remove install/ from read-only code, so phpBB is told to allow it;
    # nginx denies /install/ instead, leaving the installer reachable only from the CLI
    printf '\ncore:\n    allow_install_dir: true\n' >> "${PHPBB_CODE}/config/production/config.yml"; \
    chown -R root:root "${PHPBB_CODE}" "${PHPBB_DIST}" "${PHPBB_LEGACY_BASE}"; \
    chmod -R u=rwX,go=rX "${PHPBB_CODE}" "${PHPBB_DIST}" "${PHPBB_LEGACY_BASE}"; \
    for item in store files images ext styles language config.php; do ln -s "${PHPBB_ROOT}/phpbb/$item" "${PHPBB_CODE}/$item"; done; \
    ln -s /var/cache/phpbb "${PHPBB_CODE}/cache"; \
    mkdir -p /var/cache/phpbb "${PHPBB_ROOT}/phpbb"; \
    chown phpbb:phpbb /var/cache/phpbb "${PHPBB_ROOT}" "${PHPBB_ROOT}/phpbb"; \
    chmod 1777 /var/cache/phpbb; \
    echo "phpBB ${PHPBB_VERSION} installed at ${PHPBB_CODE}"

# phpBB's debug environment for PHPBB_DEBUG, read-only like the rest of its code
COPY config/phpbb-debug/ ${PHPBB_CODE}/config/debug/

# Set proper permissions for the scripts
RUN chmod 755 /opt/.docker/*.sh && \
    chown -R root:phpbb /opt/.docker && \
    chmod 755 /opt/.docker && \
    # Cloudflare's IP ranges for TRUSTED_PROXIES=cloudflare, refreshed at boot when stale
    mkdir -p /usr/share/phpbb-docker && \
    /opt/.docker/update-cloudflare-ips.sh /usr/share/phpbb-docker/cloudflare-ips && \
    # Create SQLite database file with proper permissions
    touch ${PHPBB_ROOT}/phpbb.sqlite && \
    chown phpbb:phpbb ${PHPBB_ROOT}/phpbb.sqlite && \
    chmod 0640 ${PHPBB_ROOT}/phpbb.sqlite && \
    # Cleanup unnecessary files
    rm -rf /tmp/* /var/cache/apk/*

# Board data must survive container recreation, even when no volume is given
VOLUME ["/opt/phpbb"]

# Set working directory
WORKDIR ${PHPBB_ROOT}

# Expose port 8080
EXPOSE 8080

# Add healthcheck to verify the service is running
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fs --unix-socket /run/nginx/health.sock http://localhost/fpm-ping || exit 1

# Switch to non-root user for running the container
USER phpbb

ENTRYPOINT ["/opt/.docker/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]