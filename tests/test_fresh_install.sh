#!/bin/sh
# Fresh installs: the generated admin password and its one-time banner, the
# install markers, and board data surviving container recreation.
. "$(dirname "$0")/lib.sh"

version=$(image_phpbb_version "$IMAGE")

echo "Generated admin password, 500 draws of the entrypoint's own generator"
samples=$(mktemp)
# Load the entrypoint's functions without running main (its last line), then draw
docker run --rm --entrypoint sh "$IMAGE" -c '
  sed "\$d" /opt/.docker/docker-entrypoint.sh > /tmp/entrypoint-functions.sh
  . /tmp/entrypoint-functions.sh
  PHPBB_ROOT=/tmp/no-board
  for i in $(seq 500); do unset PHPBB_PASSWORD; validate_environment; printf "%s\n" "$GENERATED_PASSWORD"; done' > "$samples"
check_eq "500 passwords generated" 500 "$(wc -l < "$samples" | tr -d ' ')"
check_eq "every one is 12 characters" 0 "$(awk 'length($0) != 12' "$samples" | wc -l | tr -d ' ')"
check_eq "every one is printable ASCII" 0 "$(LC_ALL=C grep -c '[^!-~]' "$samples")"
check_eq "every one fits phpBB's 30-character limit once HTML-escaped" 0 \
  "$(docker run --rm -i --entrypoint php$PHP_VERSION "$IMAGE" -r '$n = 0; while (($line = fgets(STDIN)) !== false) { if (strlen(htmlspecialchars(rtrim($line, "\n"), ENT_COMPAT, "UTF-8")) > 30) $n++; } echo $n;' < "$samples")"
check_eq "all distinct" 500 "$(sort -u "$samples" | wc -l | tr -d ' ')"
check_eq "the full charset is used, including & < > \" and \\" 5 "$(LC_ALL=C grep -o '[&<>"\\]' "$samples" | sort -u | wc -l | tr -d ' ')"
rm -f "$samples"

echo "Fresh install, no volume and no PHPBB_PASSWORD"
start fresh "$IMAGE"
check "container is running" running fresh
password=$(banner_password fresh)
check_eq "banner shows a 12-character password" 12 "$(printf '%s' "$password" | wc -c | tr -d ' ')"
check_eq "admin can log in with it" 2 "$(login fresh admin "$password")"
check_eq "install marker says this image installed it" 2 "$(docker exec "$(c fresh)" cat "$DATA/.docker-install-version")"
check_eq "merge base saved for phpBB $version" "$version" "$(docker exec "$(c fresh)" cat "$DATA/.phpbb-dist-base/VERSION")"
check_eq "/opt/phpbb is a volume" volume "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/phpbb"}}{{.Type}}{{end}}{{end}}' "$(c fresh)")"
check_lacks "no weak-password warning" "SECURITY WARNING" "$(logs fresh)"
check_lacks "no upgrade backup" "Backed up" "$(logs fresh)"

echo "Restart"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
docker restart "$(c fresh)" >/dev/null
wait_up fresh "$since"
after=$(docker logs --since "$since" "$(c fresh)" 2>&1)
check_lacks "no new password generated or shown" "Password:" "$after"
check_lacks "installer does not run again" "running YML-based installer" "$after"
check_eq "admin can still log in" 2 "$(login fresh admin "$password")"

echo "Compose recreate, no volumes in the compose file"
if docker compose version >/dev/null 2>&1; then
  compose_file=$(mktemp)
  printf 'services:\n  phpbb:\n    image: %s\n' "$IMAGE" > "$compose_file"
  project=$T_PREFIX-compose
  docker compose -p "$project" -f "$compose_file" up -d >/dev/null 2>&1
  first=$(docker compose -p "$project" -f "$compose_file" ps -q phpbb)
  wait_up compose-phpbb-1
  password=$(banner_password compose-phpbb-1)
  docker compose -p "$project" -f "$compose_file" up -d --force-recreate >/dev/null 2>&1
  second=$(docker compose -p "$project" -f "$compose_file" ps -q phpbb)
  wait_up compose-phpbb-1
  check "container was recreated" [ "$first" != "$second" ]
  check_lacks "board was not reinstalled" "running YML-based installer" "$(logs compose-phpbb-1)"
  check_eq "admin can log in with the first password" 2 "$(login compose-phpbb-1 admin "$password")"
  docker compose -p "$project" -f "$compose_file" down -v >/dev/null 2>&1
  rm -f "$compose_file"
else
  echo "  skip  docker compose is not available"
fi

echo "Running as the host's user (--user)"
# A volume owned by that user, as a bind mount from the host would be
docker volume create "$(vol hostuser)" >/dev/null
docker run --rm -v "$(vol hostuser):/opt/phpbb" --user root --entrypoint chown "$IMAGE" -R 1001:1001 /opt/phpbb
start hostuser "$IMAGE" --user 1001:1001 -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol hostuser):/opt/phpbb"
check "container is running" running hostuser
check "health check passes" healthy hostuser
check_eq "admin can log in" 2 "$(login hostuser admin "$T_PASSWORD")"
check_eq "the board's files belong to that user" "1001:1001" \
  "$(on_volume hostuser 'stat -c %u:%g /opt/phpbb/phpbb.sqlite /opt/phpbb/phpbb/config.php /opt/phpbb/phpbb/store 2>&1' | sort -u)"
# An existing board, moved to another user
start olduser "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol olduser):/opt/phpbb"
docker rm -f "$(c olduser)" >/dev/null
start newuser "$IMAGE" --user 1001:1001 -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol olduser):/opt/phpbb"
fix="docker exec -u root $(docker inspect -f '{{.Config.Hostname}}' "$(c newuser)") chown -R 1001:1001 /opt/phpbb"
check_eq "the log gives the exact command to give that user the volume" "$fix" \
  "$(logs newuser | sed -n 's/.*please run: //p')"
$fix
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
docker restart "$(c newuser)" >/dev/null
wait_up newuser "$since"
check_lacks "after running it, the warning is gone" "isn't writable" "$(docker logs --since "$since" "$(c newuser)" 2>&1)"
check_eq "and admin can log in" 2 "$(login newuser admin "$T_PASSWORD")"

echo "A board whose config.php is gone"
start gone "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol gone):/opt/phpbb"
docker rm -f "$(c gone)" >/dev/null
on_volume gone 'rm /opt/phpbb/phpbb/config.php'
launch gone2 "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol gone):/opt/phpbb"
wait_up gone2
check_eq "isn't installed over" 1 "$(exit_code gone2)"
check_has "and the log says why" "config.php is missing, but the database already holds a phpBB board" "$(logs gone2)"
check_fails "and no empty config.php is left behind" on_volume gone 'test -e /opt/phpbb/phpbb/config.php'

finish
