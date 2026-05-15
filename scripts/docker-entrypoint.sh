#!/bin/sh
set -eu

PHPBB_ROOT=$PHPBB_ROOT

log() {
  echo "[$(hostname)] $1"
}

handle_error() {
  log "ERROR: An unexpected error occurred at line $1, exiting..."
  exit 1
}
trap 'handle_error $LINENO' ERR

# Validate required environment variables
validate_environment() {
  local missing_vars=0
  local generated_password=""
  
  # Required variables list - using eval for POSIX-compatible variable indirection
  for var in PHPBB_USERNAME; do
    eval val="\$${var}"
    if [ -z "${val:-}" ]; then
      log "ERROR: $var environment variable is not set"
      missing_vars=$((missing_vars + 1))
    fi
  done
  
  # Generate secure password if not provided
  if [ -z "${PHPBB_PASSWORD:-}" ]; then
    # Generate a secure random password using /dev/urandom
    generated_password=$(head -c 16 /dev/urandom | tr -dc 'a-zA-Z0-9!@#$%^&*()-_=+' | head -c 16)
    export PHPBB_PASSWORD="$generated_password"
    log "SECURITY NOTICE: Generated secure password for admin user: $generated_password"
    log "IMPORTANT: Write down this password now as it will not be shown again!"
  fi
  
  # Conditionally required variables
  if [ ! -f "${PHPBB_ROOT}/phpbb/index.php" ] && [ -z "${PHPBB_VERSION:-}" ]; then
    log "ERROR: PHPBB_VERSION environment variable is required for initial installation"
    missing_vars=$((missing_vars + 1))
  fi
  
  [ $missing_vars -eq 0 ] || return 1
  return 0
}

# Ensure container is not run as root for security
check_not_root() {
  if [ "$(id -u)" = "0" ]; then
    log "ERROR: This container should not be run as root"
    return 1
  fi
  return 0
}

#######################################
# SETUP FUNCTIONS
#######################################

# Setup PHP version by removing dots for Alpine compatibility
setup_php_version() {
  # Default to PHP 84 if not set
  PHP_VERSION=$(echo "${PHP_VERSION:-84}" | tr -d '.')
  log "Using PHP version: ${PHP_VERSION}"
  return 0
}

# Install phpBB if not already installed
install_phpbb() {
  if [ ! -f "$PHPBB_ROOT/phpbb/index.php" ] || \
     [ ! -f "$PHPBB_ROOT/phpbb/store/index.htm" ] || \
     [ ! -f "$PHPBB_ROOT/phpbb/files/index.htm" ] || \
     [ ! -f "$PHPBB_ROOT/phpbb/images/index.htm" ] || \
     [ ! -f "$PHPBB_ROOT/phpbb/ext/index.htm" ] || \
     [ ! -d "$PHPBB_ROOT/phpbb/styles/all/" ] ; then
    log "phpBB files not found at $PHPBB_ROOT/phpbb, running install script..."
    if ! /opt/.docker/install-phpbb.sh "${PHPBB_VERSION}"; then
      log "ERROR: Failed to install phpBB. Exiting container."
      return 1
    fi
  fi
  return 0
}

# allow to keep config.php in separate $PHPBB_ROOT/config folder
# copying from there at startup and copying back in `install-from-yml.sh`
copy_config_php() {
  mkdir -p "$PHPBB_ROOT/phpbb"
  if [ -f "$PHPBB_ROOT/config/config.php" ] ; then
    log "copy $PHPBB_ROOT/config/config.php to phpbb installation"
    # Double-check config/config.php permissions
    chmod 640 "$PHPBB_ROOT/config/config.php" || {
      log "ERROR: Failed to set $PHPBB_ROOT/phpbb/config.php permissions"
      return 1
    }
    if ! cp "$PHPBB_ROOT/config/config.php" "$PHPBB_ROOT/phpbb/config.php" ; then
      log "ERROR: couldn't copy $PHPBB_ROOT config/config.php to phpbb/config.php"
      return 1
    fi
    # Double-check phpbb/config.php permissions again
    chmod 640 "$PHPBB_ROOT/phpbb/config.php" || {
      log "ERROR: Failed to set $PHPBB_ROOT/phpbb/config.php permissions"
      return 1
    }
  fi
  return 0
}

# Configure phpBB if not already configured
configure_phpbb() {
  # Check if config.php exists and is not empty
  if [ ! -f "$PHPBB_ROOT/phpbb/config.php" ] || [ ! -s "$PHPBB_ROOT/phpbb/config.php" ]; then
    log "Configuration file not found or is empty, running YML-based installer..."
    if ! /opt/.docker/install-from-yml.sh; then
      log "ERROR: Failed to configure phpBB. Exiting container."
      return 1
    fi
  else
    log "phpBB already configured, skipping installation"

    # Even if installation was skipped, ensure the install directory is removed
    INSTALL_DIR="$PHPBB_ROOT/phpbb/install"
    if [ -d "$INSTALL_DIR" ]; then
      log "install directory found: likely a new docker image/installation and mounted subvolumes only -> update database migration"
      if ! /opt/.docker/update-db-migration.sh; then
        log "ERROR: Failed to update and run database migration."
        return 1
      fi
      
      log "SECURITY: Removing phpBB install directory..."
      if rm -rf "$INSTALL_DIR"; then
        log "SECURITY: Successfully removed phpBB install directory"
      else
        log "WARNING: Failed to remove phpBB install directory. This is a security risk!"
      fi
    fi
  fi
  return 0
}

# Apply custom PHP.ini options if provided
apply_custom_php_ini() {
  if [ -n "${PHP_CUSTOM_INI:-}" ]; then
    log "Applying custom PHP.ini options..."
    # Use a secure temporary file with restricted permissions
    PHP_TMP_FILE=$(mktemp)
    chmod 600 "$PHP_TMP_FILE"
    
    echo "${PHP_CUSTOM_INI}" > "$PHP_TMP_FILE"
    if ! cat "$PHP_TMP_FILE" >> "/etc/php${PHP_VERSION}/php.ini"; then
      rm -f "$PHP_TMP_FILE"
      log "ERROR: Failed to apply custom PHP.ini options."
      return 1
    fi
    rm -f "$PHP_TMP_FILE"
    log "Custom PHP.ini options applied successfully"
  fi
  return 0
}

# Setup log forwarding to Docker logs more efficiently
setup_log_forwarding() {
  local LOG_DIR="/tmp/docker-logs"
  mkdir -p "$LOG_DIR"
  
  # Create symbolic links for logs to redirect to stdout/stderr
  ln -sf /dev/stdout "$LOG_DIR/nginx-access.log"
  ln -sf /dev/stderr "$LOG_DIR/nginx-error.log"
  ln -sf /dev/stderr "$LOG_DIR/php-error.log"
  
  # Create empty log files if they don't exist
  mkdir -p "/var/log/nginx" "/var/log/php${PHP_VERSION}"
  touch "/var/log/nginx/access.log" "/var/log/nginx/error.log" "/var/log/php${PHP_VERSION}/error.log"
  
  # Consolidate log forwarding with a single process
  log "Setting up log forwarding..."
  # Redirect all logs to a single tail command
  {
    tail -F "/var/log/nginx/access.log" | sed -e 's/^/[nginx:access] /' &
    tail -F "/var/log/nginx/error.log" | sed -e 's/^/[nginx:error] /' &
    tail -F "/var/log/php${PHP_VERSION}/error.log" | sed -e 's/^/[php:error] /' &
  } >> /dev/stderr &
  
  return 0
}

# Start PHP-FPM service with better monitoring
start_php_fpm() {
  log "Starting PHP-FPM..."
  php-fpm${PHP_VERSION} -F &
  PHP_FPM_PID=$!

  # Check if PHP-FPM started successfully with a proper timeout
  local i=0
  local max_attempts=5
  while [ $i -lt $max_attempts ]; do
    if kill -0 $PHP_FPM_PID 2>/dev/null; then
      log "PHP-FPM started successfully with PID $PHP_FPM_PID"
      break
    fi
    i=$((i + 1))
    if [ $i -eq $max_attempts ]; then
      log "ERROR: PHP-FPM failed to start properly after $max_attempts attempts."
      return 1
    fi
    log "Waiting for PHP-FPM to start (attempt $i/$max_attempts)..."
    sleep 1
  done
  
  # Add more comprehensive trap to monitor PHP-FPM process and exit if it dies
  trap 'if ! kill -0 $PHP_FPM_PID 2>/dev/null; then log "PHP-FPM process died unexpectedly. Exiting container."; exit 1; fi' TERM INT QUIT HUP
  
  return 0
}

# Check database connectivity
check_database_connectivity() {
  local db_driver="${PHPBB_DATABASE_DRIVER:-sqlite3}"
  local db_host="${PHPBB_DATABASE_HOST:-localhost}"
  local db_user="${PHPBB_DATABASE_USER:-${PHPBB_DATABASE_USERNAME:-}}"
  local db_pass="${PHPBB_DATABASE_PASSWORD:-${PHPBB_DATABASE_PASS:-}}"
  local db_name="${PHPBB_DATABASE_NAME:-phpbb}"
  local db_port="${PHPBB_DATABASE_PORT:-}"
  local db_path="${PHPBB_DATABASE_SQLITE_PATH:-${PHPBB_ROOT}/phpbb.sqlite}"
  local result=0
  
  log "Checking database connectivity..."
  
  case "$db_driver" in
    mysqli)
      if [ -z "$db_user" ] || [ -z "$db_host" ]; then
        log "WARNING: Incomplete MySQL connection information, skipping connectivity check"
        return 0
      fi
      
      # Try connecting to MySQL with appropriate arguments
      if command -v mysql >/dev/null 2>&1; then
        log "Testing MySQL connection to $db_host..."
        if ! mysql -h "$db_host" ${db_port:+-P "$db_port"} -u "$db_user" ${db_pass:+-p"$db_pass"} -e "SELECT 1" >/dev/null 2>&1; then
          log "WARNING: Could not connect to MySQL server at $db_host. phpBB may not function correctly!"
          result=0  # Don't fail the container, just warn
        else
          log "MySQL connectivity test successful"
        fi
      else
        log "WARNING: MySQL client not available, skipping connectivity check"
      fi
      ;;
      
    postgres)
      if [ -z "$db_user" ] || [ -z "$db_host" ]; then
        log "WARNING: Incomplete PostgreSQL connection information, skipping connectivity check"
        return 0
      fi
      
      # Try connecting to PostgreSQL with appropriate arguments
      if command -v psql >/dev/null 2>&1; then
        log "Testing PostgreSQL connection to $db_host..."
        if ! PGPASSWORD="$db_pass" psql -h "$db_host" ${db_port:+-p "$db_port"} -U "$db_user" -d "$db_name" -c "SELECT 1" >/dev/null 2>&1; then
          log "WARNING: Could not connect to PostgreSQL server at $db_host. phpBB may not function correctly!"
          result=0  # Don't fail the container, just warn
        else
          log "PostgreSQL connectivity test successful"
        fi
      else
        log "WARNING: PostgreSQL client not available, skipping connectivity check"
      fi
      ;;
      
    sqlite3)
      # For SQLite, check that the database directory is writable
      local db_dir
      db_dir=$(dirname "$db_path")
      
      log "Testing SQLite database at $db_path..."
      if [ ! -d "$db_dir" ]; then
        log "WARNING: SQLite database directory $db_dir does not exist!"
        if ! mkdir -p "$db_dir" 2>/dev/null; then
          log "WARNING: Could not create SQLite database directory $db_dir. phpBB may not function correctly!"
          result=0  # Don't fail the container, just warn
        fi
      elif [ ! -w "$db_dir" ]; then
        log "WARNING: SQLite database directory $db_dir is not writable. phpBB may not function correctly!"
        result=0  # Don't fail the container, just warn
      else
        log "SQLite database directory check successful"
      fi
      ;;
      
    *)
      log "WARNING: Unknown database driver '$db_driver', skipping connectivity check"
      ;;
  esac
  
  return $result
}

#######################################
# MAIN EXECUTION
#######################################

main() {
  # Validate environment and setup
  check_not_root || exit 1
  validate_environment || exit 1
  setup_php_version || exit 1
  
  # Install and configure phpBB
  install_phpbb || exit 1
  copy_config_php || exit 1
  configure_phpbb || exit 1
  apply_custom_php_ini || exit 1
  
  # Check database connectivity
  check_database_connectivity || exit 1
  
  # Setup logging and start services
  setup_log_forwarding || exit 1
  start_php_fpm || exit 1
  
  # Execute the main command (likely nginx)
  log "Starting nginx..."
  exec "$@"
}

# Execute main function
main "$@"
