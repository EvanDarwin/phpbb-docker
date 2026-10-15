#!/bin/sh
# Read-only code, blocked paths, and the base image.
. "$(dirname "$0")/lib.sh"

start web "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD"

echo "Read-only code"
check_fails "phpBB's code is not writable by the phpbb user" docker exec "$(c web)" touch /var/www/phpbb/test-write
check "the data on the volume is writable" docker exec "$(c web)" touch "$DATA/files/test-write"

echo "Blocked paths"
check_eq "board index loads" 200 "$(http_code web /)"
for path in /install/ /install/app.php /config.php /phpbb/session.php /.docker-install-version /.change-admin-password /.git/config /board.sqlite /backup.DB \
    /files/ /images/avatars/upload/1.jpg /composer.json /ext/acme/demo/vendor/autoload.php /ext/acme/demo/tests/bootstrap.php; do
  check_eq "$path is forbidden" 403 "$(http_code web "$path")"
done
# File names that merely start with a blocked directory's name
for path in /assets/cache.png /assets/files.css /assets/binoculars.svg /assets/docs-icon.png /assets/testsuite.js /assets/configurator.js; do
  check_eq "$path is not blocked" 404 "$(http_code web "$path")"
done

check_eq "phpBB's bundled extension stays reachable" 200 "$(http_code web /ext/phpbb/viglink/styles/all/theme/viglink.css)"
check_eq "a missing topic answers 404" 404 "$(http_code web '/viewtopic.php?t=99999')"
check_has "with phpBB's own page, not nginx's" "The requested topic does not exist" \
  "$(docker exec "$(c web)" curl -s 'http://localhost:8080/viewtopic.php?t=99999')"

headers() { docker exec "$(c web)" curl -s -o /dev/null -D - "http://localhost:8080$1" | tr -d '\r'; }
check_has "static files get the security headers" "X-Content-Type-Options: nosniff" \
  "$(headers /styles/prosilver/theme/stylesheet.css)"
check_eq "pages send phpBB's Referrer-Policy, once" 1 "$(headers / | grep -ci '^referrer-policy:')"
check_has "static files get a Referrer-Policy" "Referrer-Policy: strict-origin-when-cross-origin" \
  "$(headers /styles/prosilver/theme/stylesheet.css)"
check_has "so do nginx's own error pages" "Referrer-Policy: strict-origin-when-cross-origin" "$(headers /config.php)"

# A dotfile that exists answers exactly like one that doesn't, so scanners
# can't tell boards made by older images from newer ones
response() { docker exec "$(c web)" curl -s -D - "http://localhost:8080$1" | grep -vi '^date:'; }
check_eq "an existing marker file answers like a missing dotfile" "$(response /.no-such-file)" "$(response /.docker-install-version)"

echo "Health check"
check "passes" healthy web
check_lacks "PHP-FPM's ping isn't served on the public port" "pong" "$(docker exec "$(c web)" curl -s http://localhost:8080/fpm-ping)"
check_eq "nothing listens on TCP but nginx on 8080" "0.0.0.0:8080 :::8080" \
  "$(docker exec "$(c web)" netstat -ltn | awk '$1 ~ /^tcp/ {print $4}' | sort | tr '\n' ' ' | sed 's/ $//')"

echo "Base image"
check_has "PHP 8.4" "PHP 8.4." "$(docker exec "$(c web)" php84 -v | head -1)"
check_lacks "Alpine is a stable release, not edge" "_alpha" "$(docker exec "$(c web)" cat /etc/alpine-release)"
check_fails "git is not installed (merges use diffutils' diff3)" docker exec "$(c web)" sh -c 'command -v git'

docker exec "$(c web)" sh -c 'kill $(pidof php-fpm84 | tr " " "\n" | sort -n | head -1)'
sleep 2
check_fails "health check fails once PHP-FPM is down" healthy web

finish
