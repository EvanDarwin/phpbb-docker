#!/bin/sh
# Values passed to the installer: YAML quoting, phpBB's input handling for the
# admin login, board name and SMTP password, and COOKIE_SECURE / SERVER_PORT.
. "$(dirname "$0")/lib.sh"

env_file=$(mktemp)
cat > "$env_file" <<'EOF'
PHPBB_USERNAME=a&b'c<d
PHPBB_PASSWORD=P&<>"\'w$`%;12
PHPBB_FORUM_NAME=My "Best" <b>Forum</b> & 'Co'
SMTP_PASSWORD=s&amp;'"\x <y>
EOF

launch hostile "$IMAGE" --env-file "$env_file"
launch secure "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e COOKIE_SECURE=true -e "SERVER_PORT= 08080 "
launch badcookie "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e COOKIE_SECURE=yes
launch badport "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e SERVER_PORT=abc
for name in hostile secure badcookie badport; do wait_up "$name"; done
rm -f "$env_file"

config_value() { docker exec "$(c "$1")" sqlite3 /opt/phpbb/phpbb.sqlite "SELECT config_value FROM phpbb_config WHERE config_name='$2'"; }
secure_cookies() { docker exec "$(c "$1")" curl -s -D - -o /dev/null http://localhost:8080/index.php | grep -i '^set-cookie' | grep -ci '; secure'; }

echo "Quotes, backslashes and HTML characters in every field"
check "container is running" running hostile
check_eq "admin a&b'c<d logs in with P&<>\"\\'w\$\`%;12" 2 "$(login hostile "a&b'c<d" 'P&<>"\'"'"'w$`%;12')"
check_eq "board name is HTML-escaped in the page" "<h1>My &quot;Best&quot; &lt;b&gt;Forum&lt;/b&gt; &amp; 'Co'</h1>" \
  "$(docker exec "$(c hostile)" curl -s http://localhost:8080/index.php | grep -o '<h1>.*</h1>' | head -1)"
stored=$(config_value hostile smtp_password)
check_eq "SMTP password decodes back to the original when phpBB uses it" "s&amp;'\"\\x <y>" \
  "$(docker exec -e S="$stored" "$(c hostile)" php84 -r 'echo html_entity_decode(getenv("S"), ENT_COMPAT);')"

echo "COOKIE_SECURE and SERVER_PORT"
check_eq "default COOKIE_SECURE=false stores an empty (false) setting" "" "$(config_value hostile cookie_secure)"
check_eq "default sends no secure-only cookies" 0 "$(secure_cookies hostile)"
check "COOKIE_SECURE=true with SERVER_PORT=\" 08080 \" installs" running secure
check_eq "COOKIE_SECURE=true is stored as true" 1 "$(config_value secure cookie_secure)"
check_eq "COOKIE_SECURE=true sends secure-only cookies" 3 "$(secure_cookies secure)"
check_eq "SERVER_PORT=\" 08080 \" is stored as 8080" 8080 "$(config_value secure server_port)"
check_eq "COOKIE_SECURE=yes stops the install" 1 "$(exit_code badcookie)"
check_has "with a clear error" "COOKIE_SECURE must be true or false, got: yes" "$(logs badcookie)"
check_eq "SERVER_PORT=abc stops the install" 1 "$(exit_code badport)"
check_has "with a clear error" "SERVER_PORT must be a port number from 1 to 65535, got: abc" "$(logs badport)"

finish
