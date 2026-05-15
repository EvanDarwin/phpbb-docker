#!/bin/sh
# Using strict shell mode - halts execution on errors and unset variables
set -e
set -u

#######################################
# GLOBAL VARIABLES AND UTILITIES
#######################################

# Custom echo function for consistent prefixing
log() {
  echo "[$(hostname)] $1"
}

# Centralized error handler
handle_error() {
  log "ERROR: An unexpected error occurred at line $1, exiting..."
  exit 1
}

# Set up error trap for unexpected failures
trap 'handle_error $LINENO' ERR

#######################################
# VALIDATION FUNCTIONS
#######################################

# Validate command line arguments with better parsing
validate_arguments() {
  # Ensure a phpBB version is provided
  if [ -z "${1:-}" ]; then
    log "ERROR: No phpBB version specified"
    log "Usage: $0 <version>"
    return 1
  fi

  VERSION="$1"
  log "Installing phpBB version: $VERSION"

  # Extract major.minor version with more robust regex
  MAJOR_MINOR_VERSION=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')
  if [ -z "$MAJOR_MINOR_VERSION" ]; then
    log "ERROR: Could not extract major.minor version from $VERSION. Expected format: X.Y.Z"
    return 1
  fi
  
  # Validate version format more thoroughly
  if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
    log "WARNING: Version format seems unusual: $VERSION. Expected format like 3.3.8"
  fi
  
  return 0
}

# Validate required environment variables
validate_environment() {
  # Validate PHPBB_ROOT is set or use default
  if [ -z "${PHPBB_ROOT:-}" ]; then
    log "WARNING: PHPBB_ROOT environment variable is not set, using default: /opt/phpbb"
    PHPBB_ROOT="/opt/phpbb"
    export PHPBB_ROOT
  fi
  
  # Check if phpBB root is writable
  if [ ! -w "$PHPBB_ROOT" ] && [ -d "$PHPBB_ROOT" ]; then
    log "ERROR: phpBB root directory is not writable: $PHPBB_ROOT"
    return 1
  fi
  
  return 0
}

#######################################
# INSTALLATION FUNCTIONS
#######################################

# Download phpBB package from the official website with integrity checking
download_phpbb() {
  # Official phpBB download URL
  DOWNLOAD_URL="https://download.phpbb.com/pub/release/${MAJOR_MINOR_VERSION}/$VERSION/phpBB-$VERSION.zip"
  PACKAGE_FILE="/tmp/phpbb-${VERSION}.zip"
  log "Downloading from: $DOWNLOAD_URL"

  # Create temp directory with proper permissions
  TMP_DIR="/tmp/phpbb_install_$$"
  mkdir -p "$TMP_DIR" || { log "ERROR: Failed to create temporary directory"; return 1; }
  chmod 700 "$TMP_DIR"
  
  # Change to temporary directory
  cd "$TMP_DIR" || { log "ERROR: Failed to change to temporary directory"; return 1; }

  # Download the phpBB package with better error handling and retry
  log "Downloading phpBB package..."
  MAX_RETRIES=3
  retry_count=0
  
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if curl -L --fail -o "$PACKAGE_FILE" "$DOWNLOAD_URL"; then
      break
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -eq $MAX_RETRIES ]; then
        log "ERROR: Failed to download phpBB version $VERSION after $MAX_RETRIES attempts"
        rm -f "$PACKAGE_FILE"
        return 1
      fi
      
      log "Download failed, retrying ($retry_count/$MAX_RETRIES)..."
      sleep 2
    fi
  done
  
  # Validate file was downloaded
  if [ ! -f "$PACKAGE_FILE" ] || [ ! -s "$PACKAGE_FILE" ]; then
    log "ERROR: Downloaded file is missing or empty"
    return 1
  fi
  
  log "Download completed successfully: $(du -h "$PACKAGE_FILE" | cut -f1)"
  return 0
}

# Extract phpBB files from the downloaded package safely
extract_phpbb_files() {
  log "Extracting phpBB files..."
  
  # Extract the downloaded zip file with better error checking
  if ! unzip -q "$PACKAGE_FILE" -d "$TMP_DIR"; then
    log "ERROR: Failed to extract phpBB files"
    rm -f "$PACKAGE_FILE"
    return 1
  fi

  # Remove the zip file after extraction to save space
  rm -f "$PACKAGE_FILE"
  
  # Verify extracted directory exists
  if [ ! -d "$TMP_DIR/phpBB3" ]; then
    log "ERROR: Expected phpBB3 directory not found after extraction"
    return 1
  fi
  
  log "Extraction completed successfully"
  return 0
}

robust_copy () {
  # Move files to destination with rsync if available for better handling of existing files
  log "copy from $1 to $2"
  if command -v rsync >/dev/null 2>&1; then
    if ! rsync -a "$1" "$2"; then
      log "ERROR: Failed to rsync phpBB files to destination directory"
      return 1
    fi
  else
    # Fallback to cp if rsync is not available
    log "Rsync not available, using cp -a ..."
    if ! cp -a "${1%/}" "${2%/}"; then
      log "ERROR: Failed to copy phpBB files to destination directory"
      return 1
    fi
  fi
}

# Move phpBB files to the destination directory with better error handling
move_files_to_destination() {
  log "Moving files to destination directory: $PHPBB_ROOT/phpbb"

  # Ensure destination directory exists
  mkdir -p "$PHPBB_ROOT/phpbb" || { log "ERROR: Failed to create phpBB root directory"; return 1; }

  if [ ! -f "$PHPBB_ROOT/phpbb/index.php" ] ; then
    robust_copy "$TMP_DIR/phpBB3/" "$PHPBB_ROOT/phpbb/"
  else
    # check for docker volumes mounted to subfolders that need to be populated
    if [ ! -f "$PHPBB_ROOT/store/index.htm" ] ; then
       robust_copy "$TMP_DIR/phpBB3/store/" "$PHPBB_ROOT/phpbb/store/"
    fi
    if [ ! -f "$PHPBB_ROOT/files/index.htm" ] ; then
       robust_copy "$TMP_DIR/phpBB3/files/" "$PHPBB_ROOT/phpbb/files/"
    fi
    if [ ! -f "$PHPBB_ROOT/images/index.htm" ] ; then
       robust_copy "$TMP_DIR/phpBB3/images/" "$PHPBB_ROOT/phpbb/images/"
    fi
    if [ ! -f "$PHPBB_ROOT/ext/index.htm" ] ; then
       robust_copy "$TMP_DIR/phpBB3/ext/" "$PHPBB_ROOT/phpbb/ext/"
    fi
    if [ ! -d "$PHPBB_ROOT/styles/all/" ] ; then
       robust_copy "$TMP_DIR/phpBB3/styles/" "$PHPBB_ROOT/phpbb/styles/"
    fi
  fi

  # Create empty config.php file to ensure we can set permissions
  # (config folder needs to to be overwritten)
  touch "$PHPBB_ROOT/phpbb/config/config.php" || { log "ERROR: Failed to create config.php file"; return 1; }
  
  log "Files moved successfully to $PHPBB_ROOT/phpbb"
  return 0
}

# Set up proper permissions for phpBB files and directories more efficiently
setup_permissions() {
  log "Setting up permissions..."
  
  # Create required directories all at once
  log "Creating required directories..."
  mkdir -p "$PHPBB_ROOT/phpbb/cache" \
           "$PHPBB_ROOT/phpbb/store" \
           "$PHPBB_ROOT/phpbb/files" \
           "$PHPBB_ROOT/phpbb/images/avatars/uploads" || {
    log "ERROR: Failed to create required directories"
    return 1
  }
  
  # Set ownership for all phpBB files
  log "Setting ownership to phpbb:phpbb..."
  if ! chown -R phpbb:phpbb "$PHPBB_ROOT"; then
    log "ERROR: Failed to set ownership of phpBB files"
    return 1
  fi

  # Set base permissions for phpBB directories and files (more efficiently)
  log "Setting base file permissions..."
  find "$PHPBB_ROOT/phpbb" -type d -exec chmod 750 {} \; || {
    log "ERROR: Failed to set directory permissions"
    return 1
  }
  
  find "$PHPBB_ROOT/phpbb" -type f -exec chmod 640 {} \; || {
    log "ERROR: Failed to set file permissions"
    return 1
  }
  
  # Set executable permissions for specific file types
  find "$PHPBB_ROOT/phpbb" -name "*.sh" -exec chmod 750 {} \; 2>/dev/null || true
  
  # Set writable permissions for directories that need it
  log "Setting writable directory permissions..."
  for dir in "$PHPBB_ROOT/phpbb/store" "$PHPBB_ROOT/phpbb/cache" "$PHPBB_ROOT/phpbb/files" "$PHPBB_ROOT/phpbb/images/avatars/uploads"; do
    chmod -R 770 "$dir" || {
      log "ERROR: Failed to set writable permissions on $dir"
      return 1
    }
  done

  # Double-check config.php permissions
  chmod 640 "$PHPBB_ROOT/phpbb/config/config.php" || {
    log "ERROR: Failed to set config.php permissions"
    return 1
  }
  
  log "Permissions set successfully"
  return 0
}

# Clean up temporary files
cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    log "Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
  fi
}

#######################################
# MAIN EXECUTION
#######################################

main() {
  # Validate arguments and environment
  validate_arguments "$1" || exit 1
  validate_environment || exit 1
  
  # Download and install phpBB
  download_phpbb || { cleanup; exit 1; }
  extract_phpbb_files || { cleanup; exit 1; }
  move_files_to_destination || { cleanup; exit 1; }
  setup_permissions || { cleanup; exit 1; }
  
  # Clean up temporary files
  cleanup
  
  log "phpBB $VERSION has been installed successfully!"
  return 0
}

# Execute main function with proper error handling and all arguments
main "$@"
