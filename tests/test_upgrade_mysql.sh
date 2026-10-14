#!/bin/sh
# MySQL-family boards: one made by the last published image is migrated and dumped
# into the backup; when the dump fails, a files-only backup is still made; boards
# whose database is down at boot still start; MySQL 8.0 boards install, upgrade and
# are dumped.
. "$(dirname "$0")/lib.sh"

version=$(image_phpbb_version "$IMAGE")
old_version=$(image_phpbb_version "$OLD_IMAGE")
net=$(c net)
docker network create "$net" >/dev/null
launch db mariadb:11 --network "$net" -e MARIADB_RANDOM_ROOT_PASSWORD=yes -e MARIADB_DATABASE=phpbb \
  -e MARIADB_USER=phpbb -e MARIADB_PASSWORD=dbpass
launch mysql8 mysql:8.0 --network "$net" -e MYSQL_RANDOM_ROOT_PASSWORD=yes -e MYSQL_DATABASE=phpbb \
  -e MYSQL_USER=phpbb -e MYSQL_PASSWORD=dbpass
mariadb_up() { docker exec "$(c db)" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; }
for _ in $(seq 60); do mariadb_up && break; sleep 2; done
root_password=$(logs db | sed -n 's/.*GENERATED ROOT PASSWORD: //p')
docker exec "$(c db)" mariadb -uroot -p"$root_password" -e "CREATE DATABASE phpbb2; GRANT ALL ON phpbb2.* TO 'phpbb'@'%';
  CREATE DATABASE phpbb3; GRANT ALL ON phpbb3.* TO 'phpbb'@'%';"

# board_env DATABASE [DB CONTAINER]
board_env() { echo "--network $net -e PHPBB_DATABASE_DRIVER=mysqli -e PHPBB_DATABASE_HOST=$(c "${2:-db}") -e PHPBB_DATABASE_NAME=$1 -e PHPBB_DATABASE_USER=phpbb -e PHPBB_DATABASE_PASSWORD=dbpass"; }
db_version() { docker exec "$(c db)" mariadb -uphpbb -pdbpass "$1" -N -e "SELECT config_value FROM phpbb_config WHERE config_name='version'"; }
mysql8_version() { docker exec "$(c mysql8)" mysql -uphpbb -pdbpass phpbb -N -e "SELECT config_value FROM phpbb_config WHERE config_name='version'" 2>/dev/null; }
backup_entry_count() { docker exec "$(c "$1")" sh -c "unzip -l /opt/phpbb/backups/*.zip | grep -c ' database/database.sql\$'"; }
dumped_version() { docker exec "$(c "$1")" sh -c "unzip -p /opt/phpbb/backups/*.zip database/database.sql | grep -o \"'version', *'[0-9.]*'\" | head -1"; }

echo "MariaDB board from the last published image (phpBB $LEGACY_PHPBB_VERSION)"
# shellcheck disable=SC2046
legacy_board legacy1 board1 $(board_env phpbb)
# shellcheck disable=SC2046
start up1 "$IMAGE" -v "$(vol board1):/opt/phpbb" $(board_env phpbb) -e PHPBB_PASSWORD="$T_PASSWORD"
check "container is running" running up1
check_eq "database upgraded to phpBB $version" "$version" "$(db_version phpbb)"
check_eq "admin logs in" 2 "$(login up1 admin "$T_PASSWORD")"
check_eq "backup includes a database dump" 1 "$(backup_entry_count up1)"
check_has "the dump is of the database before the upgrade" "'$LEGACY_PHPBB_VERSION'" "$(dumped_version up1)"
docker exec "$(c db)" mariadb -uroot -p"$root_password" -e "CREATE DATABASE restored; GRANT ALL ON restored.* TO 'phpbb'@'%';"
docker exec "$(c up1)" sh -c 'unzip -p /opt/phpbb/backups/*.zip database/database.sql' \
  | docker exec -i "$(c db)" mariadb -uphpbb -pdbpass restored
check_eq "the dump restores into an empty database" "$LEGACY_PHPBB_VERSION" "$(db_version restored)"

echo "MariaDB board from this image at phpBB $old_version, whose database dump fails"
# shellcheck disable=SC2046
start old2 "$OLD_IMAGE" -v "$(vol board2):/opt/phpbb" $(board_env phpbb2) -e PHPBB_PASSWORD="$T_PASSWORD"
docker stop "$(c old2)" >/dev/null
# phpBB's backup code doesn't quote table names, so it fails on this one, which
# phpBB's updater never reads
docker exec "$(c db)" mariadb -uphpbb -pdbpass phpbb2 -e 'CREATE TABLE `phpbb_zz broken` (a INT)'
# shellcheck disable=SC2046
start up2 "$IMAGE" -v "$(vol board2):/opt/phpbb" $(board_env phpbb2) -e PHPBB_PASSWORD="$T_PASSWORD"
check "container is running" running up2
check_has "warns that the dump failed" "Could not dump the database; the backup will contain the files on the volume only" "$(logs up2)"
check_eq "backup has no database dump" 0 "$(backup_entry_count up2)"
check "backup of the files was still written" docker exec "$(c up2)" sh -c 'unzip -tq /opt/phpbb/backups/*.zip'
check_eq "database still upgraded to phpBB $version" "$version" "$(db_version phpbb2)"

echo "MariaDB boards whose database is down at boot"
# shellcheck disable=SC2046
start old3 "$OLD_IMAGE" -v "$(vol board3):/opt/phpbb" $(board_env phpbb3) -e PHPBB_PASSWORD="$T_PASSWORD"
docker stop "$(c old3)" "$(c up1)" "$(c up2)" >/dev/null
docker stop "$(c db)" >/dev/null
# shellcheck disable=SC2046
start down1 "$IMAGE" -v "$(vol board1):/opt/phpbb" $(board_env phpbb)
check "board on phpBB $version: container is running" running down1
check_has "says why it could not read the version" "Could not read the board's phpBB version from its database" "$(logs down1)"
check_has "and that the board is up to date" "the board was already up to date with phpBB $version" "$(logs down1)"
check_eq "web server answers" 200 "$(http_code down1 /styles/prosilver/theme/stylesheet.css)"
# shellcheck disable=SC2046
start down3 "$IMAGE" -v "$(vol board3):/opt/phpbb" $(board_env phpbb3)
check "board on phpBB $old_version: container is running" running down3
check_has "says the upgrade waits for the database" "this image has phpBB $version, and the board was last set up" "$(logs down3)"
check_fails "no backup written" docker exec "$(c down3)" test -e /opt/phpbb/backups
docker stop "$(c down1)" "$(c down3)" >/dev/null
docker start "$(c db)" >/dev/null
for _ in $(seq 60); do mariadb_up && break; sleep 2; done
check_eq "database left at phpBB $old_version" "$old_version" "$(db_version phpbb3)"
# shellcheck disable=SC2046
start up3 "$IMAGE" -v "$(vol board3):/opt/phpbb" $(board_env phpbb3)
check "with the database back, the next boot upgrades" running up3
check_eq "database upgraded to phpBB $version" "$version" "$(db_version phpbb3)"

echo "MySQL 8.0 board from this image at phpBB $old_version"
# The image's first start runs a temporary server without networking, so wait for TCP
for _ in $(seq 90); do docker exec "$(c mysql8)" mysql -h127.0.0.1 -uphpbb -pdbpass -e 'SELECT 1' phpbb >/dev/null 2>&1 && break; sleep 2; done
# shellcheck disable=SC2046
start old4 "$OLD_IMAGE" -v "$(vol board4):/opt/phpbb" $(board_env phpbb mysql8) -e PHPBB_PASSWORD="$T_PASSWORD"
check "installs" running old4
check_eq "installed phpBB $old_version" "$old_version" "$(mysql8_version)"
docker stop "$(c old4)" >/dev/null
# shellcheck disable=SC2046
start up4 "$IMAGE" -v "$(vol board4):/opt/phpbb" $(board_env phpbb mysql8)
check "upgraded container is running" running up4
check_eq "database upgraded to phpBB $version" "$version" "$(mysql8_version)"
check_eq "admin logs in" 2 "$(login up4 admin "$T_PASSWORD")"
check_has "the backup holds a dump of the database before the upgrade" "'$old_version'" "$(dumped_version up4)"
check_lacks "no false connection warning" "Could not connect to MySQL server" "$(logs up4)"

finish
