#!/bin/sh
# Read-only code, blocked paths, and the base image.
. "$(dirname "$0")/lib.sh"

start web "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD"

echo "Read-only code"
check_fails "phpBB's code is not writable by the phpbb user" docker exec "$(c web)" touch /var/www/phpbb/test-write
check "the data on the volume is writable" docker exec "$(c web)" touch "$DATA/files/test-write"

echo "Blocked paths"
check_eq "board index loads" 200 "$(http_code web /)"
for path in /install/ /install/app.php /config.php /phpbb/session.php /.docker-install-version /.change-admin-password; do
  check_eq "$path is forbidden" 403 "$(http_code web "$path")"
done

check_eq "phpBB's bundled extension stays reachable" 200 "$(http_code web /ext/phpbb/viglink/styles/all/theme/viglink.css)"
check_eq "a missing topic answers 404" 404 "$(http_code web '/viewtopic.php?t=99999')"
check_has "with phpBB's own page, not nginx's" "The requested topic does not exist" \
  "$(docker exec "$(c web)" curl -s 'http://localhost:8080/viewtopic.php?t=99999')"

# A dotfile that exists answers exactly like one that doesn't, so scanners
# can't tell boards made by older images from newer ones
response() { docker exec "$(c web)" curl -s -D - "http://localhost:8080$1" | grep -vi '^date:'; }
check_eq "an existing marker file answers like a missing dotfile" "$(response /.no-such-file)" "$(response /.docker-install-version)"

echo "Base image"
check_has "PHP 8.4" "PHP 8.4." "$(docker exec "$(c web)" php84 -v | head -1)"
check_lacks "Alpine is a stable release, not edge" "_alpha" "$(docker exec "$(c web)" cat /etc/alpine-release)"

finish
