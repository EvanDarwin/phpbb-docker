#!/bin/sh
set -eu
log() { echo "[$(hostname)] $1"; }
trap 'log "ERROR at line $LINENO"; [ -n "${TEMP_DIR:-}" ] && rm -rf "$TEMP_DIR"' ERR

# Check required vars and fail fast
PHPBB_ROOT="${PHPBB_ROOT:-/opt/phpbb}"

# Find PHP and create temp dir
PHP_EXECUTABLE=$(command -v "php${PHP_VERSION:-}" 2>/dev/null || command -v php || { log "ERROR: PHP not found"; exit 1; })
TEMP_DIR=$(mktemp -d) && chmod 700 "$TEMP_DIR" && CONFIG_YML="${TEMP_DIR}/update-config.yml"

# Generate YAML config - more readable format
cat > "$CONFIG_YML" << EOF
updater:
   type: db_only

EOF
chmod 600 "$CONFIG_YML"

# Run installer & cleanup
cd "${PHPBB_ROOT}/phpbb" || { log "ERROR: Cannot access ${PHPBB_ROOT}/phpbb"; exit 1; }
[ ! -f "install/phpbbcli.php" ] && log "ERROR: CLI installer missing" && exit 1

$PHP_EXECUTABLE install/phpbbcli.php update "$CONFIG_YML"
RESULT=$?

# Check if config file was properly created
if [ ! $RESULT -eq 0 ]; then
  log "ERROR: 'php install/phpbbcli.php update $CONFIG_YML' failed with return code $RESULT"
fi

# Only remove install directory if installation was successful
if [ $RESULT -eq 0 ] && [ -d "install" ]; then
  rm -rf "install" 
  log "SECURITY: Removed install dir after successful installation"
fi

[ -n "${TEMP_DIR:-}" ] && rm -rf "$TEMP_DIR"
exit $RESULT
