#!/bin/sh
# A PostgreSQL board installed at an older phpBB is upgraded, and the database
# dump in its backup restores into an empty database.
. "$(dirname "$0")/lib.sh"

version=$(image_phpbb_version "$IMAGE")
old_version=$(image_phpbb_version "$OLD_IMAGE")
net=$(c net)
docker network create "$net" >/dev/null
launch db postgres:15 --network "$net" -e POSTGRES_USER=phpbb -e POSTGRES_PASSWORD=dbpass -e POSTGRES_DB=phpbb
# The image's first start runs a temporary server without networking, so wait for TCP
for _ in $(seq 60); do docker exec "$(c db)" pg_isready -h 127.0.0.1 -U phpbb >/dev/null 2>&1 && break; sleep 2; done

board_env="--network $net -e PHPBB_DATABASE_DRIVER=postgres -e PHPBB_DATABASE_HOST=$(c db) -e PHPBB_DATABASE_NAME=phpbb -e PHPBB_DATABASE_USER=phpbb -e PHPBB_DATABASE_PASSWORD=dbpass"
db_version() { docker exec "$(c db)" psql -U phpbb -d "$1" -tAc "SELECT config_value FROM phpbb_config WHERE config_name='version'"; }

echo "PostgreSQL board from this image at phpBB $old_version"
# shellcheck disable=SC2086
start old1 "$OLD_IMAGE" -v "$(vol board1):/opt/phpbb" $board_env -e PHPBB_PASSWORD="$T_PASSWORD"
check "installs" running old1
check_eq "installed phpBB $old_version" "$old_version" "$(db_version phpbb)"
docker stop "$(c old1)" >/dev/null
# shellcheck disable=SC2086
start up1 "$IMAGE" -v "$(vol board1):/opt/phpbb" $board_env
check "upgraded container is running" running up1
check_eq "database upgraded to phpBB $version" "$version" "$(db_version phpbb)"
check_eq "admin logs in" 2 "$(login up1 admin "$T_PASSWORD")"
check_lacks "database dumped into the backup" "Could not dump the database" "$(logs up1)"
docker exec "$(c db)" psql -U phpbb -d phpbb -c 'CREATE DATABASE restored' >/dev/null
restore_check "the dump restores into an empty database" up1 docker exec -i "$(c db)" psql -q -v ON_ERROR_STOP=1 -U phpbb -d restored
check_eq "the restored board is from before the upgrade" "$old_version" "$(db_version restored)"
# shellcheck disable=SC2086
launch lost1 "$IMAGE" -v "$(vol lost1):/opt/phpbb" $board_env -e PHPBB_PASSWORD="$T_PASSWORD"
wait_up lost1
check_eq "a new volume isn't installed over that board's database" 1 "$(exit_code lost1)"
check_has "and the log says why" "config.php is missing, but the database already holds a phpBB board" "$(logs lost1)"
check_eq "and the board is untouched" "$version" "$(db_version phpbb)"
# A role that can reach the server but not the board's database, so the check itself fails
docker exec "$(c db)" psql -U phpbb -d phpbb -c "CREATE ROLE outsider LOGIN PASSWORD 'outpass'; REVOKE CONNECT ON DATABASE phpbb FROM PUBLIC" >/dev/null
launch lost2 "$IMAGE" -v "$(vol lost2):/opt/phpbb" --network "$net" -e PHPBB_DATABASE_DRIVER=postgres -e PHPBB_DATABASE_HOST="$(c db)" \
  -e PHPBB_DATABASE_NAME=phpbb -e PHPBB_DATABASE_USER=outsider -e PHPBB_DATABASE_PASSWORD=outpass -e PHPBB_PASSWORD="$T_PASSWORD"
wait_up lost2
check_eq "when the check can't read the database, it isn't installed over either" 1 "$(exit_code lost2)"
check_has "and the log says the check failed" "SQL error during migration check, install skipped:" "$(logs lost2)"
check_has "with the database's error" "permission denied for database \"phpbb\"" "$(logs lost2)"
check_eq "and the board is untouched" "$version" "$(db_version phpbb)"

finish
