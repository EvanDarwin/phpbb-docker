#!/bin/sh
# Upgrading MariaDB boards: one made by the last published image is migrated and
# dumped into the backup; when the dump fails, a files-only backup is still made.
. "$(dirname "$0")/lib.sh"

version=$(image_phpbb_version "$IMAGE")
net=$(c net)
docker network create "$net" >/dev/null
launch db mariadb:11 --network "$net" -e MARIADB_RANDOM_ROOT_PASSWORD=yes -e MARIADB_DATABASE=phpbb \
  -e MARIADB_USER=phpbb -e MARIADB_PASSWORD=dbpass
for _ in $(seq 60); do docker exec "$(c db)" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break; sleep 2; done
root_password=$(logs db | sed -n 's/.*GENERATED ROOT PASSWORD: //p')
docker exec "$(c db)" mariadb -uroot -p"$root_password" -e "CREATE DATABASE phpbb2; GRANT ALL ON phpbb2.* TO 'phpbb'@'%';"

board_env() { echo "--network $net -e PHPBB_DATABASE_DRIVER=mysqli -e PHPBB_DATABASE_HOST=$(c db) -e PHPBB_DATABASE_NAME=$1 -e PHPBB_DATABASE_USER=phpbb -e PHPBB_DATABASE_PASSWORD=dbpass"; }
db_version() { docker exec "$(c db)" mariadb -uphpbb -pdbpass "$1" -N -e "SELECT config_value FROM phpbb_config WHERE config_name='version'"; }
backup_entry_count() { docker exec "$(c "$1")" sh -c "unzip -l /opt/phpbb/backups/*.zip | grep -c ' database/database.sql\$'"; }

echo "MariaDB board from the last published image (phpBB $LEGACY_PHPBB_VERSION)"
# shellcheck disable=SC2046
legacy_board legacy1 board1 $(board_env phpbb)
# shellcheck disable=SC2046
start up1 "$IMAGE" -v "$(vol board1):/opt/phpbb" $(board_env phpbb) -e PHPBB_PASSWORD="$T_PASSWORD"
check "container is running" running up1
check_eq "database upgraded to phpBB $version" "$version" "$(db_version phpbb)"
check_eq "admin logs in" 2 "$(login up1 admin "$T_PASSWORD")"
check_eq "backup includes a database dump" 1 "$(backup_entry_count up1)"
check_has "the dump is of the database before the upgrade" "'version','$LEGACY_PHPBB_VERSION'" \
  "$(docker exec "$(c up1)" sh -c "unzip -p /opt/phpbb/backups/*.zip database/database.sql | grep -o \"'version','[0-9.]*'\" | head -1")"

echo "MariaDB board from this image at phpBB $(image_phpbb_version "$OLD_IMAGE"), whose database dump fails"
stub=$(mktemp)
printf '#!/bin/sh\necho "simulated dump failure" >&2\nexit 2\n' > "$stub"
chmod 755 "$stub"
# shellcheck disable=SC2046
start old2 "$OLD_IMAGE" -v "$(vol board2):/opt/phpbb" $(board_env phpbb2) -e PHPBB_PASSWORD="$T_PASSWORD"
docker stop "$(c old2)" >/dev/null
# shellcheck disable=SC2046
start up2 "$IMAGE" -v "$(vol board2):/opt/phpbb" -v "$stub:/usr/bin/mariadb-dump:ro" $(board_env phpbb2) -e PHPBB_PASSWORD="$T_PASSWORD"
check "container is running" running up2
check_has "warns that the dump failed" "Could not dump the database; the backup will contain the files on the volume only" "$(logs up2)"
check_eq "backup has no database dump" 0 "$(backup_entry_count up2)"
check "backup of the files was still written" docker exec "$(c up2)" sh -c 'unzip -tq /opt/phpbb/backups/*.zip'
check_eq "database still upgraded to phpBB $version" "$version" "$(db_version phpbb2)"
rm -f "$stub"

finish
