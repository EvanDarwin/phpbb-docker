#!/bin/sh
# Helpers for the container tests. Each test file sources this, runs its checks
# and exits with the number of failed checks. Every container, volume and
# network a test creates is named after T_PREFIX and removed on exit.

: "${IMAGE:?IMAGE must name the image under test (tests/run.sh sets it)}"
: "${OLD_IMAGE:?OLD_IMAGE must name an image with an older phpBB (tests/run.sh sets it)}"

# The last image published before this layout (phpBB 3.3.15, with the weak
# password generator), kept under a tag that is never moved. The digest is what
# docker pulls, so a moved tag can't change what the upgrade tests start from.
LEGACY_IMAGE="evandarwin/phpbb:pinned-bad-3.3.15@sha256:76a0f62071f2356c7be6bb3a89f2f5cf0b69f9e4ac2d508050c61fabe651b990"
LEGACY_PHPBB_VERSION=3.3.15

T_PREFIX="phpbbtest-$(basename "$0" .sh)-$$"
T_PASSWORD=TestPassw0rd123
T_FAILED=0
DATA=/opt/phpbb/phpbb

cleanup() {
  ids=$(docker ps -aq --filter "name=^$T_PREFIX-")
  [ -z "$ids" ] || docker rm -fv $ids >/dev/null 2>&1
  ids=$(docker volume ls -q --filter "name=^$T_PREFIX-")
  [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1
  ids=$(docker network ls -q --filter "name=^$T_PREFIX-")
  [ -z "$ids" ] || docker network rm $ids >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ok() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; T_FAILED=$((T_FAILED + 1)); }

# check DESCRIPTION COMMAND...: passes when the command succeeds
check() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# check_fails DESCRIPTION COMMAND...: passes when the command fails
check_fails() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}

# check_eq DESCRIPTION EXPECTED ACTUAL
check_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}

# check_has DESCRIPTION NEEDLE HAYSTACK / check_lacks DESCRIPTION NEEDLE HAYSTACK
check_has() {
  case "$3" in *"$2"*) ok "$1" ;; *) fail "$1 (missing [$2])" ;; esac
}
check_lacks() {
  case "$3" in *"$2"*) fail "$1 (found [$2])" ;; *) ok "$1" ;; esac
}

finish() {
  [ "$T_FAILED" -eq 0 ] || echo "  $T_FAILED check(s) failed"
  exit "$T_FAILED"
}

c() { echo "$T_PREFIX-$1"; }
vol() { echo "$T_PREFIX-$1"; }

# Wait until the entrypoint reaches nginx, reports an error, or the container exits
wait_up() {
  for _ in $(seq 240); do
    docker logs "$(c "$1")" 2>&1 | grep -qE 'Starting nginx|ERROR' && { sleep 2; return 0; }
    [ "$(docker inspect -f '{{.State.Status}}' "$(c "$1")" 2>/dev/null)" = exited ] && return 0
    sleep 1
  done
}

# launch NAME IMAGE [docker run options...]: run detached without waiting
launch() {
  name=$1; image=$2; shift 2
  docker run -d --name "$(c "$name")" "$@" "$image" >/dev/null
}

# start NAME IMAGE [docker run options...]: run detached and wait for startup
start() {
  launch "$@"
  wait_up "$1"
}

running() { [ "$(docker inspect -f '{{.State.Status}}' "$(c "$1")")" = running ]; }
exit_code() { docker inspect -f '{{.State.ExitCode}}' "$(c "$1")"; }
logs() { docker logs "$(c "$1")" 2>&1; }

# Run a shell command against a volume in a throwaway container of the image under test
on_volume() { docker run --rm -v "$(vol "$1"):/opt/phpbb" --entrypoint sh "$IMAGE" -c "$2"; }

# SQLite query against a board's database on a volume
sqlite_query() { on_volume "$1" "sqlite3 /opt/phpbb/phpbb.sqlite \"$2\""; }
db_version_on() { sqlite_query "$1" "SELECT config_value FROM phpbb_config WHERE config_name='version'"; }

# HTTP status of a path, requested from inside the container
http_code() { docker exec "$(c "$1")" curl -s -o /dev/null -w '%{http_code}' "http://localhost:8080$2"; }

# login NAME USERNAME PASSWORD: log in through phpBB's real login form from inside
# the container and print the resulting user id (1 = still anonymous)
login() {
  docker exec -i -e U="$2" -e P="$3" "$(c "$1")" sh -s <<'EOF'
jar=$(mktemp); base=http://localhost:8080
page=$(curl -s -c "$jar" -b "$jar" "$base/ucp.php?mode=login")
field() { printf '%s' "$page" | sed -n "s/.*name=\"$1\" value=\"\([^\"]*\)\".*/\1/p" | head -1; }
tok=$(field form_token); ct=$(field creation_time); sid=$(field sid)
# phpBB rejects a form submitted in the same second it was generated
sleep 2
curl -s -c "$jar" -b "$jar" -o /dev/null --data-urlencode "username=$U" --data-urlencode "password=$P" \
  --data-urlencode "form_token=$tok" --data-urlencode "creation_time=$ct" --data-urlencode "sid=$sid" \
  --data-urlencode "redirect=./index.php" --data-urlencode "login=Login" "$base/ucp.php?mode=login"
awk -F '\t' '$6 ~ /_u$/ {print $7}' "$jar" | tail -1
rm -f "$jar"
EOF
}

# The generated admin password from a container's first-start banner
banner_password() { logs "$1" | sed -n 's/^\[[0-9a-f]*\]   Password: //p' | head -1; }

image_phpbb_version() { docker run --rm --entrypoint printenv "$1" PHPBB_VERSION; }

# legacy_board NAME VOLUME [docker run options...]: a board installed by the last
# published image, left stopped so a newer image can take over its volume
legacy_board() {
  name=$1; volume=$2; shift 2
  docker run -d --name "$(c "$name")" -v "$(vol "$volume"):/opt/phpbb" -e PHPBB_PASSWORD="$T_PASSWORD" "$@" "$LEGACY_IMAGE" >/dev/null
  wait_up "$name"
  docker stop "$(c "$name")" >/dev/null
}
