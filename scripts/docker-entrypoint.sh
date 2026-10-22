#!/bin/sh
set -eu

log() {
  echo "[$(hostname)] $1"
}

handle_error() {
  log "ERROR: An unexpected error occurred at line $1, exiting..."
  exit 1
}
trap 'handle_error $LINENO' ERR

# Set by validate_environment when it generates the admin password for a new install
GENERATED_PASSWORD=""

# Validate required environment variables
validate_environment() {
  local missing_vars=0
  local escaped_length

  # Required variables list - using eval for POSIX-compatible variable indirection
  for var in PHPBB_USERNAME; do
    eval val="\$${var}"
    if [ -z "${val:-}" ]; then
      log "ERROR: $var environment variable is not set"
      missing_vars=$((missing_vars + 1))
    fi
  done
  
  # Generate a password for a new install if none was provided; an existing
  # board already has one, and a new one would only be logged, never used
  if [ -z "${PHPBB_PASSWORD:-}" ] && [ ! -s "${PHPBB_ROOT:-/opt/phpbb}/phpbb/config.php" ]; then
    # Generate a 12-character password from /dev/urandom, discarding bytes outside
    # the charset until we have enough. Charset is all printable ASCII: the installer
    # quotes it safely in its YAML and stores it the way phpBB's login reads it.
    # phpBB's installer caps the password at 30 characters after HTML-escaping, where
    # & < > " grow to 4-6 characters, so draw again in the rare case it would not fit
    while :; do
      GENERATED_PASSWORD=$(tr -dc '\041-\176' < /dev/urandom | head -c 12)
      escaped_length=$(printf '%s' "$GENERATED_PASSWORD" | awk '{ n = length($0); n += 4 * gsub(/&/, ""); n += 3 * gsub(/[<>]/, ""); n += 5 * gsub(/"/, ""); print n }')
      [ "$escaped_length" -le 30 ] && break
    done
    export PHPBB_PASSWORD="$GENERATED_PASSWORD"
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

# The read-only code in PHPBB_CODE links into this data directory on the volume.
# A new or bind-mounted volume starts empty, so copy in whatever is missing from
# the image's pristine copies; volumes from earlier versions already have it all.
DATA_DIR="${PHPBB_ROOT:-/opt/phpbb}/phpbb"
prepare_data_dir() {
  local item
  if [ ! -w "$PHPBB_ROOT" ] || { [ -e "$DATA_DIR" ] && [ ! -w "$DATA_DIR" ]; }; then
    log "WARNING: $PHPBB_ROOT isn't writable by the container's user ($(id -u):$(id -g)); please run: docker exec -u root $(hostname) chown -R $(id -u):$(id -g) $PHPBB_ROOT"
  fi
  mkdir -p "$DATA_DIR" || { log "ERROR: Could not create $DATA_DIR"; return 1; }
  for item in store files images ext styles language config.php; do
    if [ ! -e "$DATA_DIR/$item" ]; then
      log "Creating $DATA_DIR/$item"
      if ! cp -R "$PHPBB_DIST/$item" "$DATA_DIR/$item"; then
        # Remove the partial copy, or the next boot would take it as complete
        rm -rf "${DATA_DIR:?}/$item"
        log "ERROR: Could not create $DATA_DIR/$item"
        return 1
      fi
    fi
  done
  return 0
}

# Configure phpBB if not already configured
configure_phpbb() {
  # Check if config.php exists and is not empty
  if [ ! -s "$DATA_DIR/config.php" ]; then
    log "Configuration file not found or is empty, running YML-based installer..."
    if ! /opt/.docker/install-from-yml.sh; then
      log "ERROR: Failed to configure phpBB. Exiting container."
      return 1
    fi
  else
    log "phpBB already configured, skipping installation"
  fi
  return 0
}

# PHP that boots phpBB the way bin/phpbbcli.php --safe-mode does, leaving the
# board's config.php settings and $phpbb_container set for the code after it
PHPBB_BOOTSTRAP='
  define("IN_PHPBB", true);
  $phpbb_root_path = rtrim(getenv("PHPBB_CODE"), "/") . "/";
  $phpEx = "php";
  require($phpbb_root_path . "includes/startup.php");
  require($phpbb_root_path . "phpbb/class_loader.php");
  $phpbb_class_loader = new \phpbb\class_loader("phpbb\\", "{$phpbb_root_path}phpbb/", $phpEx);
  $phpbb_class_loader->register();
  $phpbb_config_php_file = new \phpbb\config_php_file($phpbb_root_path, $phpEx);
  extract($phpbb_config_php_file->get_all());
  @define("PHPBB_ENVIRONMENT", "production");
  require($phpbb_root_path . "includes/constants.php");
  require($phpbb_root_path . "includes/functions.php");
  $phpbb_container_builder = new \phpbb\di\container_builder($phpbb_root_path, $phpEx);
  $phpbb_container_builder->with_config($phpbb_config_php_file);
  $phpbb_container_builder->without_extensions();
  $phpbb_container_builder->without_cache();
  // phpBB services read the container from this global, as in bin/phpbbcli.php
  $phpbb_container = $phpbb_container_builder->get_container();
'

# Compare the phpBB version recorded in the board's database with the code's.
# Prints "same", "older:<db version>" or "newer:<db version>". The connection
# attempt is bounded so an unreachable database host can't hold up the boot.
phpbb_db_version_state() {
  PGCONNECT_TIMEOUT=10 "php${PHP_VERSION}" -d default_socket_timeout=10 -r "$PHPBB_BOOTSTRAP"'
    $db_version = $phpbb_container->get("config")["version"];
    $cmp = version_compare($db_version, PHPBB_VERSION);
    echo ($cmp === 0) ? "same" : (($cmp < 0 ? "older:" : "newer:") . $db_version);'
}

# Pristine copy of phpBB's bundled styles, language packs, extensions and images
# for the version the volume's copies came from. It is saved on the volume after
# every install or upgrade; volumes made by earlier images of this project (all
# phpBB 3.3.15) have none, so the image keeps that release's copy for them.
BUNDLED_DIRS="styles language ext images"
BASE_DIR="$DATA_DIR/.phpbb-dist-base"

merge_base_dir() {
  if [ -f "$BASE_DIR/VERSION" ]; then
    echo "$BASE_DIR"
  elif [ -f "$BASE_DIR.old/VERSION" ]; then
    # save_bundled_base was stopped between its two renames: the previous base is
    # still the one the volume's files came from (or merges cleanly with them)
    echo "$BASE_DIR.old"
  else
    echo "$PHPBB_LEGACY_BASE"
  fi
}

save_bundled_base() {
  local dir
  rm -rf "${BASE_DIR:?}.new" && mkdir -p "$BASE_DIR.new" || { log "ERROR: Could not create $BASE_DIR.new"; return 1; }
  for dir in $BUNDLED_DIRS; do
    cp -R "$PHPBB_DIST/$dir" "$BASE_DIR.new/$dir" || { log "ERROR: Could not save phpBB's $dir to $BASE_DIR.new"; return 1; }
  done
  echo "$PHPBB_VERSION" > "$BASE_DIR.new/VERSION" || { log "ERROR: Could not write $BASE_DIR.new/VERSION"; return 1; }
  # Swap by renaming, and keep the previous base as .old until the new one is in
  # place, so a stop at any point leaves merge_base_dir a base to use
  if [ -e "$BASE_DIR" ]; then
    rm -rf "${BASE_DIR:?}.old" && mv "$BASE_DIR" "$BASE_DIR.old" \
      || { log "ERROR: Could not move $BASE_DIR aside"; return 1; }
  fi
  mv "$BASE_DIR.new" "$BASE_DIR" || { log "ERROR: Could not replace $BASE_DIR with $BASE_DIR.new"; return 1; }
  rm -rf "${BASE_DIR:?}.old"
  return 0
}

# Three-way merge of the bundled files into a staging directory, changing nothing
# on the volume: base = merge_base_dir, ours = the volume, theirs = this image.
# Files the admin didn't change take phpBB's new version, files phpBB didn't change
# keep the admin's, and files both changed go through diff3's merge. Files the
# admin added are never looked at. The staged files are listed in .updates and the
# files to remove in .deletes. Returns 1 after logging every conflict, or 2 if the
# staging directory can't be written.
stage_bundled_merge() {
  local base="$1" stage="$2" rel b o t rc conflicts=0
  if ! : > "$stage/.updates" || ! : > "$stage/.deletes" \
      || ! (cd "$base" && find $BUNDLED_DIRS -type f && cd "$PHPBB_DIST" && find $BUNDLED_DIRS -type f) > "$stage/.all" \
      || ! sort -u "$stage/.all" > "$stage/.files"; then
    log "ERROR: Could not list the files to merge in $stage"
    return 2
  fi

  while IFS= read -r rel; do
    b="$base/$rel"; o="$DATA_DIR/$rel"; t="$PHPBB_DIST/$rel"
    if [ ! -f "$t" ]; then
      # Removed by phpBB: remove it too, unless the admin changed it
      if [ -f "$o" ] && [ -f "$b" ] && cmp -s "$o" "$b"; then
        echo "$rel" >> "$stage/.deletes" || { log "ERROR: Could not write $stage/.deletes"; return 2; }
      fi
    elif [ ! -e "$o" ]; then
      # New in this version, or deleted by the admin (kept deleted unless phpBB changed it)
      if [ ! -f "$b" ]; then
        stage_file "$t" "$stage" "$rel" || return 2
      elif ! cmp -s "$b" "$t"; then
        conflicts=$((conflicts + 1))
        log "ERROR: $rel was deleted from the volume but changed in phpBB ${PHPBB_VERSION}"
      fi
    elif cmp -s "$o" "$t" || { [ -f "$b" ] && cmp -s "$t" "$b"; }; then
      :  # already up to date, or unchanged by phpBB: keep the admin's file
    elif [ -f "$b" ] && cmp -s "$o" "$b"; then
      stage_file "$t" "$stage" "$rel" || return 2
    else
      mkdir -p "$(dirname "$stage/$rel")" || { log "ERROR: Could not stage $rel in $stage"; return 2; }
      rc=0
      # -E merges changes made identically on both sides (as on a volume where an
      # earlier, interrupted upgrade already wrote them); diff3's default reports them
      # as conflicts
      diff3 -m -E -L "volume" -L "phpBB $(cat "$base/VERSION")" -L "phpBB ${PHPBB_VERSION}" \
        "$o" "$( [ -f "$b" ] && echo "$b" || echo /dev/null )" "$t" > "$stage/$rel" 2> "$stage/.merge-error" || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$rel" >> "$stage/.updates" || { log "ERROR: Could not write $stage/.updates"; return 2; }
      elif [ "$rc" -eq 1 ]; then
        conflicts=$((conflicts + 1))
        log "ERROR: $rel was changed on the volume and in phpBB ${PHPBB_VERSION}, and the changes conflict:"
        awk '/^<<<<<<< /{show=1; printf "  at line %d:\n", NR} show{print "    " $0} /^>>>>>>> /{show=0}' "$stage/$rel" \
          | while IFS= read -r line; do log "$line"; done
      else
        # Exit 2: diff3 can't merge it at all, as with binary files
        conflicts=$((conflicts + 1))
        log "ERROR: $rel was changed on the volume and in phpBB ${PHPBB_VERSION}, and can't be merged: $(cat "$stage/.merge-error")"
      fi
    fi
  done < "$stage/.files"

  [ "$conflicts" -eq 0 ] || return 1
  return 0
}

# Copy $1 into the staging directory $2 as $3, and list it in .updates
stage_file() {
  mkdir -p "$(dirname "$2/$3")" && cp "$1" "$2/$3" && echo "$3" >> "$2/.updates" \
    || { log "ERROR: Could not stage $3 in $2"; return 1; }
}

# Write the staged files to the volume (each replaced in one rename, so a failure
# never leaves a half-written file) and remove the ones phpBB removed
apply_bundled_merge() {
  local stage="$1" rel
  while IFS= read -r rel; do
    if ! mkdir -p "$(dirname "$DATA_DIR/$rel")" || ! cp "$stage/$rel" "$DATA_DIR/$rel.phpbb-new" \
        || ! mv "$DATA_DIR/$rel.phpbb-new" "$DATA_DIR/$rel"; then
      rm -f "$DATA_DIR/$rel.phpbb-new"
      log "ERROR: Could not write $DATA_DIR/$rel"
      return 1
    fi
  done < "$stage/.updates"
  while IFS= read -r rel; do
    rm -f "${DATA_DIR:?}/$rel" || { log "ERROR: Could not remove $DATA_DIR/$rel"; return 1; }
  done < "$stage/.deletes"
  return 0
}

# Upgrade backups: everything on the volume, plus a dump of MySQL and PostgreSQL
# databases, which don't live on the volume
BACKUP_DIR="${PHPBB_ROOT:-/opt/phpbb}/backups"

# Dump the board's MySQL or PostgreSQL database into $1/database.sql with phpBB's
# own backup code (what ACP > Maintenance > Backup uses), over phpBB's own database
# connection. Nothing to do for SQLite, whose file is on the volume; returns 1 if
# the dump fails.
dump_database() {
  local out="$1/database.sql"
  if ! "php${PHP_VERSION}" -r "$PHPBB_BOOTSTRAP"'
      $db = $phpbb_container->get("dbal.conn");
      if ($db->get_sql_layer() === "sqlite3") exit(0);
      // The extractor calls helper functions defined with the ACP backup module
      require($phpbb_root_path . "includes/acp/acp_database.php");
      $extractor = $phpbb_container->get("dbal.extractor");
      // In "download" mode the extractor writes the dump to standard output
      $extractor->init_extractor("text", "backup", time(), true, false);
      $extractor->write_start($table_prefix);
      foreach ($phpbb_container->get("dbal.tools")->sql_list_tables() as $table) {
        if ($table_prefix === "" || stripos($table, $table_prefix) === 0) {
          $extractor->write_table($table);
          $extractor->write_data($table);
        }
      }
      $extractor->write_end();' > "$out"; then
    rm -f "$out"
    return 1
  fi
  [ -s "$out" ] || { rm -f "$out"; return 0; }
  # phpBB's PostgreSQL dumps drop each table without IF EXISTS, all in one
  # transaction, so they can't be restored into an empty database; add it, leaving
  # COPY data alone. MySQL dumps already use IF EXISTS and have no COPY blocks.
  if ! awk 'copy { print; if ($0 == "\\.") copy = 0; next }
      /^COPY .* FROM stdin;$/ { copy = 1 }
      /^DROP TABLE [^ ;]+;$/ { sub(/^DROP TABLE /, "DROP TABLE IF EXISTS ") }
      { print }' "$out" > "$out.tmp" || ! mv "$out.tmp" "$out"; then
    rm -f "$out" "$out.tmp"
    return 1
  fi
  return 0
}

# Zip everything on the volume (except earlier backups and the saved merge base)
# and any database dump into $BACKUP_DIR, as the board was before upgrading from $1.
# A failed database dump still leaves a backup of the files; a failed zip returns 1.
backup_before_upgrade() {
  local zip dump_dir
  zip="$BACKUP_DIR/phpbb-$1-$(date -u +%Y%m%dT%H%M%SZ).zip"
  mkdir -p "$BACKUP_DIR" || { log "ERROR: Could not create $BACKUP_DIR"; return 1; }
  dump_dir=$(mktemp -d) || { log "ERROR: Could not create a directory for the database dump"; return 1; }
  if ! dump_database "$dump_dir"; then
    log "WARNING: Could not dump the database; the backup will contain the files on the volume only"
  fi
  if ! BACKUP_ZIP="$zip.partial" BACKUP_DUMPS="$dump_dir" "php${PHP_VERSION}" -r '
      $root = rtrim(getenv("PHPBB_ROOT"), "/");
      $base = $root . "/phpbb/.phpbb-dist-base";
      $skip = array($root . "/backups", $base, $base . ".new", $base . ".old");
      $zip = new ZipArchive();
      if ($zip->open(getenv("BACKUP_ZIP"), ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) exit(1);
      $files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
      foreach ($files as $file) {
        $path = $file->getPathname();
        foreach ($skip as $skipped) { if ($path === $skipped || strpos($path, $skipped . "/") === 0) continue 2; }
        $name = substr($path, strlen($root) + 1);
        if ($file->isDir()) $zip->addEmptyDir($name); else $zip->addFile($path, $name);
      }
      foreach (glob(getenv("BACKUP_DUMPS") . "/*") as $dump) $zip->addFile($dump, "database/" . basename($dump));
      exit($zip->close() ? 0 : 1);' || ! mv "$zip.partial" "$zip"; then
    rm -rf "$dump_dir" "$zip.partial"
    return 1
  fi
  rm -rf "$dump_dir"
  log "Backed up the board to $zip ($(du -h "$zip" | cut -f1))"
  return 0
}

# The board's database couldn't tell its phpBB version: start without upgrading.
# The merge base says which phpBB the board was last set up for, so the warning
# can say whether an upgrade is waiting.
skip_upgrade() {
  local last
  last=$(cat "$(merge_base_dir)/VERSION" 2>/dev/null || echo unknown)
  log "WARNING: $1"
  if [ "$last" = "$PHPBB_VERSION" ]; then
    log "         Starting anyway; the board was already up to date with phpBB ${PHPBB_VERSION}."
  else
    log "         Starting without upgrading: this image has phpBB ${PHPBB_VERSION}, and the board was last set up"
    log "         for phpBB $last. Restart the container once the database is reachable to upgrade it."
  fi
}

# Bring an existing board up to this image's phpBB version. Every file merge is
# worked out first; the database is only touched once all of them are clean, then
# phpBB's official CLI updater migrates it (database only: the code comes from the
# image), and finally the merged files are written to the volume. A database that
# can't be reached never stops the container: the upgrade waits for the next boot.
upgrade_phpbb() {
  local state needs_db=false needs_files=false stage base from update_dir merge_rc=0 rc=0
  [ "$NEW_INSTALL" = false ] || return 0

  if ! state=$(phpbb_db_version_state); then
    skip_upgrade "Could not read the board's phpBB version from its database (error above)."
    return 0
  fi
  case "$state" in
    same) ;;
    older:*) needs_db=true ;;
    newer:*)
      log "ERROR: The database is from phpBB ${state#newer:}, newer than this image's phpBB ${PHPBB_VERSION}. Downgrades are not supported."
      return 1 ;;
    *)
      skip_upgrade "Unexpected answer reading the board's phpBB version from its database: $state"
      return 0 ;;
  esac
  [ "$(cat "$BASE_DIR/VERSION" 2>/dev/null)" = "$PHPBB_VERSION" ] || needs_files=true
  [ "$needs_db" = true ] || [ "$needs_files" = true ] || return 0

  stage=$(mktemp -d) || { log "ERROR: Could not create a directory to stage the upgrade in"; return 1; }
  if [ "$needs_files" = true ]; then
    base=$(merge_base_dir)
    log "Merging phpBB's bundled styles, language packs, extensions and images from $(cat "$base/VERSION") to ${PHPBB_VERSION}..."
    stage_bundled_merge "$base" "$stage" || merge_rc=$?
    if [ "$merge_rc" -ne 0 ]; then
      rm -rf "$stage"
      if [ "$merge_rc" -eq 1 ]; then
        log "ERROR: Upgrade to phpBB ${PHPBB_VERSION} stopped before changing anything. Resolve the conflicts above in"
        log "       $DATA_DIR (or restore phpBB's original file there), then restart the container."
      else
        log "ERROR: Upgrade to phpBB ${PHPBB_VERSION} stopped before changing anything: the merged files could not be staged"
      fi
      return 1
    fi
  fi

  # Back up before the first change, if anything is going to change at all
  if [ "$needs_db" = true ] || [ -s "$stage/.updates" ] || [ -s "$stage/.deletes" ]; then
    from=${state#older:}
    [ "$needs_db" = true ] || from=$(cat "$(merge_base_dir)/VERSION")
    if ! backup_before_upgrade "$from"; then
      rm -rf "$stage"
      log "ERROR: Upgrade to phpBB ${PHPBB_VERSION} stopped before changing anything: the backup could not be written"
      return 1
    fi
  fi

  if [ "$needs_db" = true ]; then
    log "Updating the database from phpBB ${state#older:} to ${PHPBB_VERSION}..."
    if ! update_dir=$(mktemp -d) || ! printf 'updater:\n    type: db_only\n' > "$update_dir/update-config.yml"; then
      rm -rf "$stage" "$update_dir"
      log "ERROR: Upgrade to phpBB ${PHPBB_VERSION} stopped before changing anything: could not write the updater's settings"
      return 1
    fi
    (cd "$PHPBB_CODE" && "php${PHP_VERSION}" install/phpbbcli.php update "$update_dir/update-config.yml") || rc=$?
    rm -rf "$update_dir"
    # phpbbcli.php can exit 0 after a failed step, so confirm against the database
    state=$(phpbb_db_version_state) || state=unknown
    if [ "$rc" -ne 0 ] || [ "$state" != same ]; then
      rm -rf "$stage"
      log "ERROR: The phpBB database update did not complete (exit $rc, database now: $state)"
      return 1
    fi
  fi

  # Saving the new merge base marks the upgrade done, so it comes last: if any
  # write fails, the next boot merges again (files already written compare equal)
  if [ "$needs_files" = true ] && { ! apply_bundled_merge "$stage" || ! save_bundled_base; }; then
    rm -rf "$stage"
    log "ERROR: Could not write all of phpBB ${PHPBB_VERSION}'s merged files to $DATA_DIR."
    log "       Restart the container to finish the upgrade."
    return 1
  fi
  rm -rf "$stage"
  log "Board is up to date with phpBB ${PHPBB_VERSION}"
  return 0
}

# Install version marker: 1 = installed by an image from before the password
# generator fix (it could create admin passwords as short as 6 characters),
# 2 = installed by this image. The marker and the warning flag sit next to
# config.php so they persist exactly when the install does.
INSTALL_VERSION_FILE="${PHPBB_ROOT:-/opt/phpbb}/phpbb/.docker-install-version"
PASSWORD_WARNING_FILE="${PHPBB_ROOT:-/opt/phpbb}/phpbb/.change-admin-password"
NEW_INSTALL=false

# Classify the install before configure_phpbb runs, while a new install still
# has no config.php. An existing install without a marker was made by an older
# image; flag it once if its admin password may have been generated by it.
classify_install() {
  if [ ! -s "${PHPBB_ROOT:-/opt/phpbb}/phpbb/config.php" ]; then
    NEW_INSTALL=true
    return 0
  fi
  [ -f "$INSTALL_VERSION_FILE" ] && return 0

  # Create the flag before the marker, so a failed flag write is retried next boot
  if [ -z "${PHPBB_PASSWORD:-}" ] && ! touch "$PASSWORD_WARNING_FILE"; then
    log "WARNING: Could not create $PASSWORD_WARNING_FILE"
    return 0
  fi
  if ! echo 1 > "$INSTALL_VERSION_FILE"; then
    log "WARNING: Could not write $INSTALL_VERSION_FILE"
  fi
  return 0
}

# Mark a board installed by this image, after configure_phpbb succeeded
mark_new_install() {
  if [ "$NEW_INSTALL" = true ] && ! echo 2 > "$INSTALL_VERSION_FILE"; then
    log "WARNING: Could not write $INSTALL_VERSION_FILE"
  fi
  return 0
}

# Show a generated admin password once the installer has applied it: after the
# installer's output so it is not buried, but before later steps that could fail
# and exit, since the password is never shown or generated again
show_generated_password() {
  [ -n "$GENERATED_PASSWORD" ] || return 0
  log "=============================================================================="
  log "phpBB is installed. Log in as the admin with:"
  log ""
  log "  Username: ${PHPBB_USERNAME}"
  log "  Password: ${GENERATED_PASSWORD}"
  log ""
  log "Save this password now: it was generated for you and will not be shown again."
  log "=============================================================================="
  return 0
}

# Repeat the vulnerable install warning on every boot until the flag is deleted
warn_vulnerable_install() {
  [ -f "$PASSWORD_WARNING_FILE" ] || return 0
  log "SECURITY WARNING: This forum was created by an older, vulnerable version of this"
  log "image, which has since been updated for your security."
  log ""
  log "The insecure version generated default passwords far shorter than intended."
  log "If the admin password was generated automatically and never changed, please"
  log "change it now by going to User Control Panel > Profile > Edit account settings."
  log ""
  log "Once changed, you can delete this file to silence this warning:"
  log "   docker exec <container> rm $PASSWORD_WARNING_FILE"
  return 0
}

# PHP_MEMORY_LIMIT, then PHP_CUSTOM_INI, which can override it, into the directory
# PHP_INI_SCAN_DIR adds after PHP's own settings. Written on every start.
apply_custom_php_ini() {
  local ini="${PHP_INI_SCAN_DIR##*:}/environment.ini"
  if ! printf '%s\n%s\n' "${PHP_MEMORY_LIMIT:+memory_limit = $PHP_MEMORY_LIMIT}" "${PHP_CUSTOM_INI:-}" > "$ini"; then
    log "ERROR: Could not write $ini"
    return 1
  fi
  [ -z "${PHP_CUSTOM_INI:-}" ] || log "Applied PHP_CUSTOM_INI"
  return 0
}

# nginx trusts X-Forwarded-For only from TRUSTED_PROXIES: addresses or ranges,
# separated by spaces or commas, and "cloudflare" for Cloudflare's published ranges.
# Empty, the default, trusts nothing.
TRUSTED_PROXIES_CONF=/run/nginx/trusted-proxies.conf
CLOUDFLARE_IPS=/run/nginx/cloudflare-ips
configure_trusted_proxies() {
  local entry ranges=""
  for entry in $(echo "${TRUSTED_PROXIES:-}" | tr ',' ' '); do
    case "$entry" in
      cloudflare)
        cloudflare_ips || return 1
        ranges="$ranges $(cat "$CLOUDFLARE_IPS")" ;;
      *)
        if ! echo "$entry" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$'; then
          log "ERROR: TRUSTED_PROXIES: '$entry' is not an address, an address range or 'cloudflare'"
          return 1
        fi
        ranges="$ranges $entry" ;;
    esac
  done
  if ! for entry in $ranges; do echo "set_real_ip_from $entry;"; done > "$TRUSTED_PROXIES_CONF"; then
    log "ERROR: Could not write $TRUSTED_PROXIES_CONF"
    return 1
  fi
  # shellcheck disable=SC2086
  [ -z "$ranges" ] || log "Trusting X-Forwarded-For from $(set -- $ranges; echo $#) address ranges"
  return 0
}

# The Content-Security-Policy header: CONTENT_SECURITY_POLICY replaces the default.
# Images, video and frames may come from any HTTPS site, for [img] BBCode, remote
# avatars and embed extensions.
DEFAULT_CSP="default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; media-src 'self' https:; frame-src 'self' https:; font-src 'self'; frame-ancestors 'self'; form-action 'self'"
configure_csp() {
  local csp="${CONTENT_SECURITY_POLICY:-$DEFAULT_CSP}"
  # The value goes into nginx's configuration inside double quotes
  case "$csp" in
    *[\"\\\$]*|*"
"*)
      log "ERROR: CONTENT_SECURITY_POLICY can't contain double quotes, backslashes, \$ or line breaks"
      return 1 ;;
  esac
  if ! echo "add_header Content-Security-Policy \"$csp\" always;" > /run/nginx/content-security-policy.conf; then
    log "ERROR: Could not write /run/nginx/content-security-policy.conf"
    return 1
  fi
  [ -z "${CONTENT_SECURITY_POLICY:-}" ] || log "Using the Content-Security-Policy from CONTENT_SECURITY_POLICY"
  return 0
}

# nginx's request body limit follows PHP-FPM's post_max_size, so PHP's settings are the
# only place to change it. Both read 0 as no limit.
configure_body_limit() {
  local value bytes
  value=$("php-fpm${PHP_VERSION}" -i 2>/dev/null | sed -n 's/^post_max_size => \([^ ]*\) => .*/\1/p')
  bytes=$("php${PHP_VERSION}" -r 'echo max(0, ini_parse_quantity($argv[1]));' -- "$value" 2>/dev/null)
  case "$value:$bytes" in
    :*|*:|*:*[!0-9]*)
      log "ERROR: Could not read PHP-FPM's post_max_size for nginx's request body limit"
      return 1 ;;
  esac
  if ! echo "client_max_body_size $bytes;" > /run/nginx/client-max-body-size.conf; then
    log "ERROR: Could not write /run/nginx/client-max-body-size.conf"
    return 1
  fi
  log "Request body limit: $value, from PHP's post_max_size"
  return 0
}

# Cloudflare's ranges, as fetched when the image was built, and fetched again at
# boot once the copy is over a month old. A failed fetch keeps the copy.
cloudflare_ips() {
  if [ ! -f "$CLOUDFLARE_IPS" ] && ! { cp /usr/share/phpbb-docker/cloudflare-ips "$CLOUDFLARE_IPS" \
      && touch -r /usr/share/phpbb-docker/cloudflare-ips "$CLOUDFLARE_IPS"; }; then
    log "ERROR: Could not copy Cloudflare's IP ranges to $CLOUDFLARE_IPS"
    return 1
  fi
  if [ -n "$(find "$CLOUDFLARE_IPS" -mmin +43200)" ]; then
    log "Fetching Cloudflare's IP ranges, as the copy from $(date -r "$CLOUDFLARE_IPS" +%Y-%m-%d) is over a month old..."
    /opt/.docker/update-cloudflare-ips.sh "$CLOUDFLARE_IPS" \
      || log "WARNING: Could not fetch Cloudflare's IP ranges; using the copy from $(date -r "$CLOUDFLARE_IPS" +%Y-%m-%d)"
  fi
  return 0
}

# nginx and PHP-FPM log to links in /run that point at files in LOG_DIR, which can
# be mounted on its own; new lines are also forwarded to the container's output,
# each prefixed with its source (awk flushes each line, where sed would hold them
# in its buffer). If LOG_DIR can't be written, the links point at the container's
# output instead.
LOG_DIR=/var/log/phpbb
setup_log_forwarding() {
  if mkdir -p "$LOG_DIR" 2>/dev/null \
      && touch "$LOG_DIR/nginx-access.log" "$LOG_DIR/nginx-error.log" "$LOG_DIR/php-error.log" 2>/dev/null; then
    ln -sf "$LOG_DIR/nginx-access.log" /run/nginx/access.log \
      && ln -sf "$LOG_DIR/nginx-error.log" /run/nginx/error.log \
      && ln -sf "$LOG_DIR/php-error.log" /run/php-fpm/error.log \
      || { log "ERROR: Could not link the log files in /run"; return 1; }
    log "Logging to $LOG_DIR..."
    {
      tail -F "$LOG_DIR/nginx-access.log" | awk '{ print "[nginx:access] " $0; fflush() }' &
      tail -F "$LOG_DIR/nginx-error.log" | awk '{ print "[nginx:error] " $0; fflush() }' &
      tail -F "$LOG_DIR/php-error.log" | awk '{ print "[php:error] " $0; fflush() }' &
    } >> /dev/stderr &
  else
    log "WARNING: Could not write the logs in $LOG_DIR (a mounted directory must be writable by"
    log "         UID 100); logging to the container output only"
    ln -sf /dev/stdout /run/nginx/access.log \
      && ln -sf /dev/stderr /run/nginx/error.log \
      && ln -sf /dev/stderr /run/php-fpm/error.log \
      || { log "ERROR: Could not link the logs to the container output"; return 1; }
  fi
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
      
      # Connect with PHP's mysqli, as phpBB does; the connection attempt is bounded
      log "Testing MySQL connection to $db_host..."
      if ! DB_HOST="$db_host" DB_PORT="$db_port" DB_USER="$db_user" DB_PASS="$db_pass" \
          "php${PHP_VERSION}" -d default_socket_timeout=10 -r '
            mysqli_report(MYSQLI_REPORT_OFF);
            if (!@mysqli_init()->real_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASS"), null, (int) getenv("DB_PORT") ?: null)) {
              fwrite(STDERR, mysqli_connect_error() . "\n");
              exit(1);
            }'; then
        log "WARNING: Could not connect to MySQL server at $db_host. phpBB may not function correctly!"
        result=0  # Don't fail the container, just warn
      else
        log "MySQL connectivity test successful"
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
        if ! PGCONNECT_TIMEOUT=10 PGPASSWORD="$db_pass" psql -h "$db_host" ${db_port:+-p "$db_port"} -U "$db_user" -d "$db_name" -c "SELECT 1" >/dev/null 2>&1; then
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
  prepare_data_dir || exit 1
  classify_install || exit 1
  upgrade_phpbb || exit 1
  configure_phpbb || exit 1
  mark_new_install || exit 1
  if [ "$NEW_INSTALL" = true ]; then save_bundled_base || exit 1; fi
  show_generated_password || exit 1
  apply_custom_php_ini || exit 1
  
  # Check database connectivity
  check_database_connectivity || exit 1
  
  # Setup logging and start services
  configure_trusted_proxies || exit 1
  configure_csp || exit 1
  configure_body_limit || exit 1
  setup_log_forwarding || exit 1
  start_php_fpm || exit 1
  warn_vulnerable_install || exit 1

  # Execute the main command (likely nginx)
  log "Starting nginx..."
  exec "$@"
}

# Execute main function
main "$@"