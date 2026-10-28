#!/bin/sh
set -eu
log() { echo "[$(hostname)] $1"; }
trap 'log "ERROR at line $LINENO"; [ -n "${TEMP_DIR:-}" ] && rm -rf "$TEMP_DIR"' ERR

# Check required vars and fail fast
for var in PHPBB_USERNAME PHPBB_PASSWORD; do
  # Fix: using eval to get variable value in POSIX sh instead of ${!var:-}
  eval "val=\$$var"
  [ -z "${val:-}" ] && log "ERROR: $var not set" && exit 1
done
PHPBB_ROOT="${PHPBB_ROOT:-/opt/phpbb}"

# Find PHP and create temp dir
PHP_EXECUTABLE=$(command -v "php${PHP_VERSION:-}" 2>/dev/null || command -v php || { log "ERROR: PHP not found"; exit 1; })
TEMP_DIR=$(mktemp -d) && chmod 700 "$TEMP_DIR" && CONFIG_YML="${TEMP_DIR}/config.yml"

# Database validation of configuration params
validate_db_config() {
  local driver="${PHPBB_DATABASE_DRIVER:-sqlite3}"
  case "$driver" in
    mysqli)
      # More strict validation for MySQL
      if [ -z "${PHPBB_DATABASE_USER:-${PHPBB_DATABASE_USERNAME:-}}" ]; then
        log "WARNING: MySQL database user not specified"
      fi
      if [ -z "${PHPBB_DATABASE_HOST:-}" ]; then
        log "WARNING: MySQL database host not specified, defaulting to 'localhost'"
      fi
      ;;
    postgres)
      # More strict validation for PostgreSQL
      if [ -z "${PHPBB_DATABASE_USER:-${PHPBB_DATABASE_USERNAME:-}}" ]; then
        log "WARNING: PostgreSQL database user not specified"
      fi
      if [ -z "${PHPBB_DATABASE_HOST:-}" ]; then
        log "WARNING: PostgreSQL database host not specified, defaulting to 'localhost'"
      fi
      ;;
    sqlite3)
      # Set default SQLite path to be within phpBB root but not in public dir
      if [ -z "${PHPBB_DATABASE_SQLITE_PATH:-}" ]; then
        export PHPBB_DATABASE_SQLITE_PATH="${PHPBB_ROOT}/phpbb.sqlite"
        log "Setting default SQLite database path to ${PHPBB_DATABASE_SQLITE_PATH}"
      fi
      
      # Check if the database is in the public directory using proper path comparison
      if [ -n "${PHPBB_DATABASE_SQLITE_PATH:-}" ]; then
        # Get directory part of the SQLite path
        db_dir=$(dirname "${PHPBB_DATABASE_SQLITE_PATH}")
        public_dir="${PHPBB_ROOT}/phpbb"
        
        # Compare actual directory paths instead of using string replacement
        if [ "$db_dir" = "$public_dir" ]; then
          log "ERROR: SQLite database cannot be stored in the public phpBB directory (${PHPBB_ROOT}/phpbb)"
          log "       Please use a path outside the web root, such as ${PHPBB_ROOT}/phpbb.sqlite"
          return 1
        fi
        
        # Check SQLite directory permission
        if [ ! -d "$db_dir" ]; then
          log "Creating SQLite database directory: $db_dir"
          mkdir -p "$db_dir" || {
            log "ERROR: Failed to create SQLite database directory: $db_dir"
            return 1
          }
        fi
        
        # Ensure directory is writable
        if [ ! -w "$db_dir" ]; then
          log "ERROR: SQLite database directory is not writable: $db_dir"
          return 1
        fi
      fi
      ;;
    *) log "ERROR: Unsupported database driver: $driver" && return 1 ;;
  esac
  return 0
}

# Test database connection before installation
test_db_connection() {
  local driver="${PHPBB_DATABASE_DRIVER:-sqlite3}"
  local host="${PHPBB_DATABASE_HOST:-localhost}"
  local port="${PHPBB_DATABASE_PORT:-}"
  local user="${PHPBB_DATABASE_USER:-${PHPBB_DATABASE_USERNAME:-phpbb_user}}"
  local pass="${PHPBB_DATABASE_PASSWORD:-${PHPBB_DATABASE_PASS:-}}"
  local name="${PHPBB_DATABASE_NAME:-phpbb}"
  local db_path="${PHPBB_DATABASE_SQLITE_PATH:-/phpbb.sqlite}"
  local db_state
  
  log "Testing database connection with driver: $driver"
  
  case "$driver" in
    mysqli)
      # Set default MySQL port if not specified
      [ -z "$port" ] && port="3306"
      
      # Connect with PHP's mysqli, as phpBB does, and check whether the database exists
      log "Testing MySQL connection to $host:$port..."
      if ! db_state=$(DB_HOST="$host" DB_PORT="$port" DB_USER="$user" DB_PASS="$pass" DB_NAME="$name" \
          "$PHP_EXECUTABLE" -d default_socket_timeout=10 -r '
            mysqli_report(MYSQLI_REPORT_OFF);
            $db = mysqli_init();
            if (!@$db->real_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASS"), null, (int) getenv("DB_PORT"))) {
              fwrite(STDERR, mysqli_connect_error() . "\n");
              exit(1);
            }
            echo @$db->select_db(getenv("DB_NAME")) ? "exists" : "missing";'); then
        log "ERROR: Failed to connect to MySQL database"
        return 1
      fi

      if [ "$db_state" = missing ]; then
        log "Database '$name' doesn't exist, will be created during installation"
      fi

      log "MySQL connection successful"
      ;;
      
    postgres)
      # Set default PostgreSQL port if not specified
      [ -z "$port" ] && port="5432"
      
      if command -v psql > /dev/null 2>&1; then
        log "Testing PostgreSQL connection to $host:$port..."
        
        # Create temporary pgpass file to avoid password prompt
        if [ -n "$pass" ]; then
          PGPASS_FILE="${TEMP_DIR}/pgpass"
          echo "$host:$port:*:$user:$pass" > "$PGPASS_FILE"
          chmod 600 "$PGPASS_FILE"
          export PGPASSFILE="$PGPASS_FILE"
        fi
        
        if ! PGCONNECT_TIMEOUT=10 psql -h "$host" -p "$port" -U "$user" -c "SELECT 1" postgres > /dev/null 2>&1; then
          log "ERROR: Failed to connect to PostgreSQL database"
          [ -n "${PGPASSFILE:-}" ] && unset PGPASSFILE
          return 1
        fi
        
        # Test if database exists
        if ! PGCONNECT_TIMEOUT=10 psql -h "$host" -p "$port" -U "$user" -c "SELECT 1" "$name" > /dev/null 2>&1; then
          log "Database '$name' doesn't exist, will be created during installation"
        fi
        
        [ -n "${PGPASSFILE:-}" ] && unset PGPASSFILE
        log "PostgreSQL connection successful"
      else
        log "WARNING: psql client not found, skipping connection test"
      fi
      ;;
      
    sqlite3)
      if command -v sqlite3 > /dev/null 2>&1; then
        log "Testing SQLite database at $db_path"
        
        # For SQLite, just check if we can access or create the file
        db_dir=$(dirname "$db_path")
        if [ ! -d "$db_dir" ]; then
          log "Creating SQLite database directory: $db_dir"
          mkdir -p "$db_dir" || {
            log "ERROR: Failed to create SQLite database directory: $db_dir"
            return 1
          }
        fi
        
        # Test if we can write to the database
        if [ -f "$db_path" ] && [ ! -w "$db_path" ]; then
          log "ERROR: SQLite database file exists but is not writable: $db_path"
          return 1
        elif [ ! -f "$db_path" ] && [ ! -w "$db_dir" ]; then
          log "ERROR: SQLite database directory is not writable: $db_dir"
          return 1
        fi
        
        # Test if we can open/create the database
        if ! echo "SELECT 1;" | sqlite3 "$db_path" > /dev/null 2>&1; then
          log "ERROR: Failed to access or create SQLite database: $db_path"
          return 1
        fi
        
        log "SQLite database test successful"
      else
        log "WARNING: sqlite3 client not found, skipping connection test"
      fi
      ;;
  esac

  return 0
}

# A database that already holds a phpBB board means config.php went missing, not that
# this is a new install, so phpBB's installer must not run over it
refuse_existing_board() {
  local table="${TABLE_PREFIX}config" error
  # Exit 0: the board's config table exists. 2: it (or its database) doesn't. Anything
  # else: the check itself failed, and the output is the database's error.
  error=$(DB_DRIVER="$DB_DRIVER" DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_PASS="$DB_PASS" \
      DB_NAME="$DB_NAME" DB_TABLE="$table" "$PHP_EXECUTABLE" -r '
      $table = getenv("DB_TABLE");
      $options = array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 10);
      try {
        switch (getenv("DB_DRIVER")) {
          case "sqlite3":
            if (!is_file(getenv("DB_HOST")) || !filesize(getenv("DB_HOST"))) exit(2);
            $db = new PDO("sqlite:" . getenv("DB_HOST"), null, null, $options);
            $query = $db->prepare("SELECT count(*) FROM sqlite_master WHERE type = ? AND name = ?");
            $query->execute(array("table", $table));
            break;
          case "mysqli":
            $db = new PDO("mysql:host=" . getenv("DB_HOST") . ";port=" . (getenv("DB_PORT") ?: 3306),
              getenv("DB_USER"), getenv("DB_PASS"), $options);
            $query = $db->prepare("SELECT count(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = ?");
            $query->execute(array(getenv("DB_NAME"), $table));
            break;
          case "postgres":
            $dsn = "pgsql:host=" . getenv("DB_HOST") . ";port=" . (getenv("DB_PORT") ?: 5432) . ";dbname=";
            $db = new PDO($dsn . "postgres", getenv("DB_USER"), getenv("DB_PASS"), $options);
            $query = $db->prepare("SELECT count(*) FROM pg_database WHERE datname = ?");
            $query->execute(array(getenv("DB_NAME")));
            if (!$query->fetchColumn()) exit(2);
            $db = new PDO($dsn . getenv("DB_NAME"), getenv("DB_USER"), getenv("DB_PASS"), $options);
            $query = $db->prepare("SELECT count(to_regclass(?))");
            $query->execute(array($table));
            break;
          default:
            exit(1);
        }
        exit($query->fetchColumn() ? 0 : 2);
      } catch (Exception $e) {
        echo $e->getMessage();
        exit(1);
      }' 2>&1)
  case $? in
    0)
      log "ERROR: ${PHPBB_ROOT}/phpbb/config.php is missing, but the database already holds a phpBB board"
      log "       (its $table table exists), so the image won't install a new one over it."
      log "       Restore config.php to ${PHPBB_ROOT}/phpbb/config.php, or check that the board's volume is"
      log "       mounted at ${PHPBB_ROOT}."
      return 1 ;;
    2)
      return 0 ;;
    *)
      log "ERROR: SQL error during migration check, install skipped: $error"
      return 1 ;;
  esac
}

# Load config values - keep variables on separate lines for readability
ADMIN_NAME="$PHPBB_USERNAME"
ADMIN_PASS="$PHPBB_PASSWORD"
ADMIN_EMAIL="${PHPBB_EMAIL:-admin@example.com}"

BOARD_NAME="${PHPBB_FORUM_NAME:-My Board}"
BOARD_DESC="${PHPBB_FORUM_DESCRIPTION:-My amazing new phpBB board}"
BOARD_LANG="${PHPBB_LANGUAGE:-en}"

DB_DRIVER="${PHPBB_DATABASE_DRIVER:-mysqli}"
if [ "$DB_DRIVER" = "sqlite3" ]; then
  DB_HOST="${PHPBB_DATABASE_SQLITE_PATH:-/phpbb.sqlite}"
else
  DB_HOST="${PHPBB_DATABASE_HOST:-localhost}"
fi
DB_PORT="${PHPBB_DATABASE_PORT:-}"
DB_USER="${PHPBB_DATABASE_USER:-${PHPBB_DATABASE_USERNAME:-phpbb_user}}"
DB_PASS="${PHPBB_DATABASE_PASSWORD:-${PHPBB_DATABASE_PASS:-}}"
DB_NAME="${PHPBB_DATABASE_NAME:-phpbb}"
TABLE_PREFIX="${PHPBB_TABLE_PREFIX:-phpbb_}"

SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-25}"
SMTP_AUTH="${SMTP_AUTH:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASSWORD:-}"
if [ -n "$SMTP_HOST" ]; then
  SMTP_ENABLED="true"
  SMTP_DELIVERY="true"
else
  SMTP_ENABLED="false"
  SMTP_DELIVERY="false"
fi

SERVER_PROTOCOL="${SERVER_PROTOCOL:-http://}"
SERVER_NAME="${SERVER_NAME:-localhost}"
SERVER_PORT="${SERVER_PORT:-80}"
SCRIPT_PATH="${SCRIPT_PATH:-/}"
COOKIE_SECURE="${COOKIE_SECURE:-false}"

# Written to the YAML unquoted, as a boolean: quoted, "false" would be stored as
# text that phpBB treats as true, sending secure-only cookies over plain HTTP
case "$COOKIE_SECURE" in
  true|false) ;;
  *) log "ERROR: COOKIE_SECURE must be true or false, got: $COOKIE_SECURE"; exit 1 ;;
esac

# phpBB's installer requires an integer here, so coerce the value to a number the
# way JavaScript's +value would (PHP's is_numeric: whitespace, +, leading zeros and
# 8080.0 are fine) and refuse anything that is not a whole port number
PORT_INPUT="$SERVER_PORT"
SERVER_PORT=$(PORT="$PORT_INPUT" "$PHP_EXECUTABLE" -r '
  $v = getenv("PORT");
  if (is_numeric($v) && (float) $v == (int) $v && (int) $v >= 1 && (int) $v <= 65535) echo (int) $v;')
if [ -z "$SERVER_PORT" ]; then
  log "ERROR: SERVER_PORT must be a port number from 1 to 65535, got: $PORT_INPUT"
  exit 1
fi

# Validate database config and test connection before installation
validate_db_config || exit 1
test_db_connection || exit 1
refuse_existing_board || exit 1

# Convert a value the way phpBB's request layer converts form input, using phpBB's
# own type_cast_helper (newlines normalized, HTML-escaped, NFC-normalized, trimmed
# if $2 is "trim"). The CLI installer stores values as given, but phpBB expects the
# stored form of these fields to match what its forms would have stored.
phpbb_input() {
  PHPBB_INPUT_ROOT="${PHPBB_CODE}/" PHPBB_INPUT_VALUE="$1" PHPBB_INPUT_TRIM="$2" \
    "$PHP_EXECUTABLE" -r '
      define("IN_PHPBB", true);
      $root = getenv("PHPBB_INPUT_ROOT");
      require $root . "phpbb/request/type_cast_helper_interface.php";
      require $root . "phpbb/request/type_cast_helper.php";
      require $root . "includes/utf/utf_tools.php";
      $helper = new \phpbb\request\type_cast_helper();
      $helper->set_var($result, getenv("PHPBB_INPUT_VALUE"), "string", true, getenv("PHPBB_INPUT_TRIM") === "trim");
      echo $result;'
}

# Login reads the username trimmed and the password untrimmed; the SMTP password
# is decoded before use and the board name is printed into pages as stored.
# The database password is read raw by phpBB, so it is left as given.
ADMIN_NAME=$(phpbb_input "$ADMIN_NAME" trim)
ADMIN_PASS=$(phpbb_input "$ADMIN_PASS" untrimmed)
BOARD_NAME=$(phpbb_input "$BOARD_NAME" trim)
SMTP_PASS=$(phpbb_input "$SMTP_PASS" trim)

# Quote a value as a YAML single-quoted scalar, where the only escape is '' for '
yaml_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Generate YAML config - more readable format
cat > "$CONFIG_YML" << EOF
installer:
    admin:
        name: $(yaml_quote "$ADMIN_NAME")
        password: $(yaml_quote "$ADMIN_PASS")
        email: $(yaml_quote "$ADMIN_EMAIL")

    board:
        lang: $(yaml_quote "$BOARD_LANG")
        name: $(yaml_quote "$BOARD_NAME")
        description: $(yaml_quote "$BOARD_DESC")

    database:
        dbms: $(yaml_quote "$DB_DRIVER")
        dbhost: $(yaml_quote "$DB_HOST")
        dbport: $(yaml_quote "$DB_PORT")
        dbuser: $(yaml_quote "$DB_USER")
        dbpasswd: $(yaml_quote "$DB_PASS")
        dbname: $(yaml_quote "$DB_NAME")
        table_prefix: $(yaml_quote "$TABLE_PREFIX")

    email:
        enabled: ${SMTP_ENABLED}
        smtp_delivery: ${SMTP_DELIVERY}
        smtp_host: $(yaml_quote "$SMTP_HOST")
        smtp_port: $(yaml_quote "$SMTP_PORT")
        smtp_auth: $(yaml_quote "$SMTP_AUTH")
        smtp_user: $(yaml_quote "$SMTP_USER")
        smtp_pass: $(yaml_quote "$SMTP_PASS")

    server:
        cookie_secure: ${COOKIE_SECURE}
        server_protocol: $(yaml_quote "$SERVER_PROTOCOL")
        force_server_vars: false
        server_name: $(yaml_quote "$SERVER_NAME")
        server_port: ${SERVER_PORT}
        script_path: $(yaml_quote "$SCRIPT_PATH")

    extensions: ['phpbb/viglink']
EOF
chmod 600 "$CONFIG_YML"

# Run installer & cleanup
cd "$PHPBB_CODE" || { log "ERROR: Cannot access $PHPBB_CODE"; exit 1; }
[ ! -f "install/phpbbcli.php" ] && log "ERROR: CLI installer missing" && exit 1

$PHP_EXECUTABLE install/phpbbcli.php install "$CONFIG_YML"
RESULT=$?

# Check if config file was properly created
CONFIG_FILE="${PHPBB_ROOT}/phpbb/config.php"
if [ $RESULT -eq 0 ] && [ ! -s "$CONFIG_FILE" ]; then
  log "ERROR: Installation completed but config/config.php is empty or missing"
  log "       This indicates that the installation process failed to write configuration data"
  RESULT=1
fi

[ -n "${TEMP_DIR:-}" ] && rm -rf "$TEMP_DIR"
exit $RESULT