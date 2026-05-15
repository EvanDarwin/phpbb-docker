FROM alpine:edge

ARG PHPBB_VERSION
ENV PHP_VERSION="${PHP_VERSION:-8.4}"
ENV PHP_VERSION="${PHP_VERSION/./}"
ENV PHPBB_ROOT="/opt/phpbb"
ENV PHPBB_VERSION="${PHPBB_VERSION}"

# phpBB configuration environment variables
ENV PHPBB_FORUM_NAME="My phpBB Forum" \
    PHPBB_FORUM_DESCRIPTION="A phpBB Forum" \
    PHPBB_USERNAME="admin" \
    PHPBB_PASSWORD="" \
    PHPBB_FIRST_NAME="Admin" \
    PHPBB_LAST_NAME="User" \
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
    SMTP_PROTOCOL="" \
    SERVER_PROTOCOL="http://" \
    SERVER_NAME="localhost" \
    SERVER_PORT="8080" \
    SCRIPT_PATH="/" \
    COOKIE_SECURE="false" \
    PHP_MEMORY_LIMIT="128M" \
    PHP_CUSTOM_INI=""

# Create non-root user for running the application
RUN addgroup -S phpbb && \
    adduser -S -G phpbb -H -h ${PHPBB_ROOT} phpbb && \
    mkdir -p ${PHPBB_ROOT} /opt/.docker && \
    chown -R phpbb:phpbb ${PHPBB_ROOT}

# Group packages by functionality for better organization and layer efficiency
RUN apk update && \
    # Core PHP packages
    apk add --virtual .php-deps --no-cache \
    php${PHP_VERSION} \
    php${PHP_VERSION}-cli \
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
    php${PHP_VERSION}-json \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-exif \
    php${PHP_VERSION}-fileinfo \
    php${PHP_VERSION}-dom \
    # Performance and security
    php${PHP_VERSION}-opcache \
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
    rsync \
    unzip \
    libcap \
    ca-certificates \
    mysql-client \
    postgresql-client \
    sqlite && \
    # Cleanup to reduce layer size
    rm -rf /var/cache/apk/*

# Configure PHP-FPM and security settings
RUN sed -i "s/user = nobody/user = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    sed -i "s/group = nobody/group = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    sed -i "s/;listen.owner = nobody/listen.owner = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    sed -i "s/;listen.group = nobody/listen.group = phpbb/g" /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    echo "security.limit_extensions = .php" >> /etc/php${PHP_VERSION}/php-fpm.d/www.conf && \
    # Allow nginx to bind to privileged ports
    setcap cap_net_bind_service=+ep /usr/sbin/nginx && \
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
    echo "open_basedir = ${PHPBB_ROOT}:/tmp" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "expose_php = Off" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "max_execution_time = 30" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "memory_limit = 128M" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "post_max_size = 32M" >> /etc/php${PHP_VERSION}/php.ini && \
    echo "upload_max_filesize = 24M" >> /etc/php${PHP_VERSION}/php.ini && \
    # Create necessary directories with proper permissions
    mkdir -p /var/lib/nginx /var/log/nginx /var/log/php${PHP_VERSION} /run/nginx && \
    chown -R phpbb:phpbb /var/lib/nginx /var/log/nginx /var/log/php${PHP_VERSION} /run/nginx && \
    touch /run/nginx.pid && \
    chown phpbb:phpbb /run/nginx.pid

# Copy scripts and configurations
COPY scripts/install-phpbb.sh scripts/docker-entrypoint.sh scripts/install-from-yml.sh scripts/update-db-migration.sh /opt/.docker/
COPY config/nginx.conf /etc/nginx/http.d/default.conf

# Download and install phpBB during the build
RUN if [ -z "${PHPBB_VERSION}" ]; then \
    echo "ERROR: PHPBB_VERSION build argument is not set" && exit 1; \
    fi && \
    echo "Installing phpBB version: ${PHPBB_VERSION}" && \
    # Extract major.minor version from the full version
    MAJOR_MINOR_VERSION=$(echo "${PHPBB_VERSION}" | grep -oE '^[0-9]+\.[0-9]+') && \
    if [ -z "${MAJOR_MINOR_VERSION}" ]; then \
    echo "ERROR: Could not extract major.minor version from ${PHPBB_VERSION}" && exit 1; \
    fi && \
    # Download and extract phpBB
    DOWNLOAD_URL="https://download.phpbb.com/pub/release/${MAJOR_MINOR_VERSION}/${PHPBB_VERSION}/phpBB-${PHPBB_VERSION}.zip" && \
    echo "Downloading from: ${DOWNLOAD_URL}" && \
    cd /tmp && \
    curl -L -o phpbb.zip "${DOWNLOAD_URL}" && \
    unzip phpbb.zip && \
    rm phpbb.zip && \
    # Move files to destination and set up directories
    mkdir -p ${PHPBB_ROOT}/phpbb && \
    mv "phpBB3"/* ${PHPBB_ROOT}/phpbb/ && \
    rm -rf "phpBB3" && \
    mkdir -p ${PHPBB_ROOT}/phpbb/config && \
    touch ${PHPBB_ROOT}/phpbb/config/config.php && \
    chown -R phpbb:phpbb ${PHPBB_ROOT} && \
    # Set base permissions
    chmod -v 0750 ${PHPBB_ROOT} ${PHPBB_ROOT}/phpbb ${PHPBB_ROOT}/phpbb/* && \
    mkdir -p ${PHPBB_ROOT}/phpbb/images/avatars/uploads && \
    # Set writable directory permissions
    chmod -v 0770 ${PHPBB_ROOT}/phpbb/store ${PHPBB_ROOT}/phpbb/cache ${PHPBB_ROOT}/phpbb/files ${PHPBB_ROOT}/phpbb/images/avatars/uploads/ && \
    chmod 0640 ${PHPBB_ROOT}/phpbb/config/config.php && \
    # Set subdirectory permissions
    find ${PHPBB_ROOT}/phpbb/cache -type d -exec chmod 750 {} \; && \
    find ${PHPBB_ROOT}/phpbb/store -type d -exec chmod 750 {} \; 2>/dev/null || true && \
    find ${PHPBB_ROOT}/phpbb/files -type d -exec chmod 750 {} \; 2>/dev/null || true && \
    # Make vendor directory read-only for security
    if [ -d "${PHPBB_ROOT}/phpbb/vendor" ]; then \
    chmod -R 555 "${PHPBB_ROOT}/phpbb/vendor" && \
    echo "SECURITY: Vendor directory is now properly protected (read-only)"; \
    fi && \
    echo "phpBB ${PHPBB_VERSION} has been installed successfully!"

# Set proper permissions for the scripts
RUN chmod 755 /opt/.docker/*.sh && \
    chown -R root:phpbb /opt/.docker && \
    chmod 750 /opt/.docker && \
    # Create SQLite database file with proper permissions
    touch ${PHPBB_ROOT}/phpbb.sqlite && \
    chown phpbb:phpbb ${PHPBB_ROOT}/phpbb.sqlite && \
    chmod 0640 ${PHPBB_ROOT}/phpbb.sqlite && \
    # Cleanup unnecessary files
    rm -rf /tmp/* /var/cache/apk/*

# Set working directory
WORKDIR ${PHPBB_ROOT}

# Expose port 8080
EXPOSE 8080

# Add healthcheck to verify the service is running
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

# Switch to non-root user for running the container
USER phpbb

ENTRYPOINT ["/opt/.docker/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
