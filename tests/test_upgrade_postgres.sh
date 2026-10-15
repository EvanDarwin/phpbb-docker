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

finish
