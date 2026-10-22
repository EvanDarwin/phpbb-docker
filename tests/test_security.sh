#!/bin/sh
# Read-only code, blocked paths, and the base image.
. "$(dirname "$0")/lib.sh"

start web "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD"

echo "Read-only code"
check_fails "phpBB's code is not writable by the phpbb user" docker exec "$(c web)" touch /var/www/phpbb/test-write
check "the data on the volume is writable" docker exec "$(c web)" touch "$DATA/files/test-write"

echo "Blocked paths"
check_eq "board index loads" 200 "$(http_code web /)"
for path in /install/ /install/app.php /config.php /phpbb/session.php /.docker-install-version /.change-admin-password /.git/config /board.sqlite /backup.DB /dump.sql /settings.YML \
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
check_eq "static files send one Cache-Control and no Expires" "Cache-Control: public, max-age=2592000" \
  "$(headers /styles/prosilver/theme/stylesheet.css | grep -iE '^(cache-control|expires):')"
check_eq "pages send phpBB's Referrer-Policy, once" 1 "$(headers / | grep -ci '^referrer-policy:')"
check_has "static files get a Referrer-Policy" "Referrer-Policy: strict-origin-when-cross-origin" \
  "$(headers /styles/prosilver/theme/stylesheet.css)"
check_has "so do nginx's own error pages" "Referrer-Policy: strict-origin-when-cross-origin" "$(headers /config.php)"
check_has "the CSP allows images, video and frames from any HTTPS site" \
  "img-src 'self' data: https:; media-src 'self' https:; frame-src 'self' https:" "$(headers /)"
check_has "static files get the CSP too" "Content-Security-Policy: default-src 'self'" "$(headers /styles/prosilver/theme/stylesheet.css)"
check_lacks "no Cross-Origin-Embedder-Policy" "Cross-Origin-Embedder-Policy" "$(headers /)"
check_lacks "no FLoC opt-out (FLoC no longer exists)" "interest-cohort" "$(headers /)"
check_lacks "no X-Permitted-Cross-Domain-Policies (Flash and Acrobat only)" "X-Permitted-Cross-Domain-Policies" "$(headers /)"
check_has "Permissions-Policy turns off features a forum never uses" \
  "Permissions-Policy: accelerometer=(), bluetooth=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), magnetometer=(), microphone=(), midi=(), payment=(), screen-wake-lock=(), serial=(), usb=(), xr-spatial-tracking=()" "$(headers /)"
start csp "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e CONTENT_SECURITY_POLICY="default-src 'self'; img-src *"
check_eq "CONTENT_SECURITY_POLICY replaces it" "Content-Security-Policy: default-src 'self'; img-src *" \
  "$(docker exec "$(c csp)" curl -s -o /dev/null -D - http://localhost:8080/ | tr -d '\r' | grep -i '^content-security-policy:')"
launch cspbad "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e CONTENT_SECURITY_POLICY='default-src "self"'
wait_up cspbad
check_eq "a value nginx's configuration can't hold stops the container" 1 "$(exit_code cspbad)"
check_has "and says why" "CONTENT_SECURITY_POLICY can't contain double quotes" "$(logs cspbad)"

# assets PATH: the scripts and stylesheets a page links, as paths from the web root
assets() {
  docker exec "$(c web)" curl -s "http://localhost:8080$1" | grep -oE '(src|href)="[^"]+\.(js|css)[^"]*"' \
    | sed -E 's/^(src|href)="//; s/"$//; s/&amp;/\&/g; s#^(\./|\.\./)+#/#'
}
for page in / /app.php/help/faq; do
  check_lacks "$page links no asset by its filesystem path" "/opt/" "$(assets "$page")"
  failed=""
  for asset in $(assets "$page"); do
    [ "$(http_code web "$asset")" = 200 ] || failed="$failed $asset"
  done
  check_eq "every script and stylesheet on $page loads" "" "$failed"
done

# A dotfile that exists answers exactly like one that doesn't, so scanners
# can't tell boards made by older images from newer ones
response() { docker exec "$(c web)" curl -s -D - "http://localhost:8080$1" | grep -vi '^date:'; }
check_eq "an existing marker file answers like a missing dotfile" "$(response /.no-such-file)" "$(response /.docker-install-version)"

# phpBB names the page after the script nginx says ran (<body class="section-...">): always
# app.php, never a name taken from the URL, even when the path holds a newline
for path in /x.php/y /app.php/a%0ab; do
  check_has "$path runs as app.php" "section-app/" "$(docker exec "$(c web)" curl -s "http://localhost:8080$path")"
done
check_eq "a file that isn't PHP can't run as PHP" 404 "$(http_code web /styles/prosilver/theme/stylesheet.css/x.php)"

echo "Health check"
check "passes" healthy web
check_lacks "PHP-FPM's ping isn't served on the public port" "pong" "$(docker exec "$(c web)" curl -s http://localhost:8080/fpm-ping)"
check_eq "nothing listens on TCP but nginx on 8080" "0.0.0.0:8080 :::8080" \
  "$(docker exec "$(c web)" netstat -ltn | awk '$1 ~ /^tcp/ {print $4}' | sort | tr '\n' ' ' | sed 's/ $//')"

echo "Uploads"
# post_size BYTES: the HTTP status for a POST body of that size
post_size() { docker exec "$(c web)" sh -c "head -c $1 /dev/zero | curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/octet-stream' --data-binary @- http://127.0.0.1:8080/index.php"; }
check_eq "nginx's body limit is PHP's post_max_size" "client_max_body_size 33554432;" \
  "$(docker exec "$(c web)" cat /run/nginx/client-max-body-size.conf)"
check_lacks "so a 30 MB request reaches PHP" 413 "$(post_size 31457280)"
check_eq "and a 40 MB one doesn't" 413 "$(post_size 41943040)"
ini=$(mktemp)
echo "post_max_size = 64M" > "$ini"
chmod 644 "$ini"
start bigpost "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$ini:/etc/php$PHP_VERSION/conf.d/99-test.ini:ro"
check_eq "raising post_max_size raises nginx's limit" "client_max_body_size 67108864;" \
  "$(docker exec "$(c bigpost)" cat /run/nginx/client-max-body-size.conf)"
rm -f "$ini"
check_has "PHP-FPM confines PHP to the board with open_basedir from php.ini" "/var/www/phpbb:/opt/phpbb:/var/cache/phpbb:/tmp" \
  "$(docker exec "$(c web)" php-fpm$PHP_VERSION -i | grep '^open_basedir')"

echo "PHP settings"
# php_setting NAME SETTING: PHP-FPM's value for SETTING
php_setting() { docker exec "$(c "$1")" php-fpm$PHP_VERSION -i | sed -n "s/^$2 => \([^ ]*\) => .*/\1/p"; }
start phpmem "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e PHP_MEMORY_LIMIT=512M
check_eq "PHP_MEMORY_LIMIT sets PHP-FPM's memory_limit" 512M "$(php_setting phpmem memory_limit)"
start phpini "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e PHP_MEMORY_LIMIT=512M -e "PHP_CUSTOM_INI=memory_limit = 256M
post_max_size = 48M"
check "PHP_CUSTOM_INI doesn't stop the container" running phpini
check_eq "PHP_CUSTOM_INI sets PHP-FPM's settings, over PHP_MEMORY_LIMIT" "256M 48M" \
  "$(php_setting phpini memory_limit) $(php_setting phpini post_max_size)"
check_eq "and nginx's body limit follows" "client_max_body_size 50331648;" \
  "$(docker exec "$(c phpini)" cat /run/nginx/client-max-body-size.conf)"

echo "Logs"
docker exec "$(c web)" curl -s -o /dev/null http://127.0.0.1:8080/log-probe
sleep 2
check_has "access log lines reach the container log right away" "[nginx:access] 127.0.0.1 - - " "$(logs web | grep ' /log-probe ')"
check_eq "every log is in /var/log/phpbb" "nginx-access.log nginx-error.log php-error.log" "$(docker exec "$(c web)" ls /var/log/phpbb | tr '\n' ' ' | sed 's/ $//')"
check "the access log has the request" docker exec "$(c web)" grep -q ' /log-probe ' /var/log/phpbb/nginx-access.log
check "PHP-FPM's log is written" docker exec "$(c web)" test -s /var/log/phpbb/php-error.log
check_lacks "nothing else logs to /var/log" "access.log" "$(docker exec "$(c web)" sh -c 'find /var/log -type f ! -path "/var/log/phpbb/*"')"
start mounted "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol logs):/var/log/phpbb"
docker exec "$(c mounted)" curl -s -o /dev/null http://127.0.0.1:8080/log-probe
check "a volume mounted there gets the logs" docker run --rm -v "$(vol logs):/logs" --entrypoint grep "$IMAGE" -q ' /log-probe ' /logs/nginx-access.log
start rologs "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -v "$(vol rologs):/var/log/phpbb:ro"
check "a read-only mount there doesn't stop the container" running rologs
check_has "it warns" "Could not write the logs in /var/log/phpbb" "$(logs rologs)"
docker exec "$(c rologs)" curl -s -o /dev/null http://127.0.0.1:8080/log-probe
sleep 1
check_has "and logs to the container output instead" '"GET /log-probe HTTP' "$(logs rologs)"
check "the health check passes" healthy rologs

echo "Base image"
php=$(echo "$PHP_VERSION" | sed 's/./&./')
check_has "PHP $php, as built" "PHP $php." "$(docker exec "$(c web)" php$PHP_VERSION -v | head -1)"
check_lacks "Alpine is a stable release, not edge" "_alpha" "$(docker exec "$(c web)" cat /etc/alpine-release)"
check_fails "git is not installed (merges use diffutils' diff3)" docker exec "$(c web)" sh -c 'command -v git'

start capdrop "$IMAGE" --cap-drop ALL -e PHPBB_PASSWORD="$T_PASSWORD"
check "runs with every capability dropped" running capdrop
check_eq "and serves the board" 200 "$(http_code capdrop /)"

docker exec "$(c web)" sh -c 'kill $(pidof php-fpm$PHP_VERSION | tr " " "\n" | sort -n | head -1)'
sleep 2
check_fails "health check fails once PHP-FPM is down" healthy web

finish
