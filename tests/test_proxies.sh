#!/bin/sh
# Which client address phpBB sees: X-Forwarded-For is trusted only from the
# addresses in TRUSTED_PROXIES (by default none), which can name Cloudflare's
# published ranges.
. "$(dirname "$0")/lib.sh"

# client_addr NAME [FROM]: the address nginx logs for a request that claims to be
# forwarded for 203.0.113.9, made from inside the container (127.0.0.1) or, with
# FROM, from that container on the same Docker network
client_addr() {
  path="/forwarded-probe-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  if [ -n "${2:-}" ]; then
    docker exec "$(c "$2")" curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.9' "http://$(c "$1"):8080$path"
  else
    docker exec "$(c "$1")" curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.9' "http://127.0.0.1:8080$path"
  fi
  docker exec "$(c "$1")" sh -c "grep ' $path ' /var/log/nginx/access.log | cut -d ' ' -f 1"
}
trusted() { docker exec "$(c "$1")" cat /run/nginx/trusted-proxies.conf; }
# backdate NAME FILE DAYS
backdate() { docker exec "$(c "$1")" sh -c "touch -t \$(date -d @\$((\$(date +%s) - $3 * 86400)) +%Y%m%d%H%M) $2"; }
STALE_LIST='198.51.100.0/24
2001:db8::/32'
net=$(c net)
docker network create "$net" >/dev/null
docker run -d --name "$(c proxy)" --network "$net" --entrypoint sleep "$IMAGE" 600 >/dev/null

echo "No TRUSTED_PROXIES"
start none "$IMAGE" --network "$net" -e PHPBB_PASSWORD="$T_PASSWORD"
check_eq "nothing is trusted" "" "$(trusted none)"
check_eq "X-Forwarded-For is ignored" 127.0.0.1 "$(client_addr none)"
check_lacks "even from another container on the same Docker network" 203.0.113.9 "$(client_addr none proxy)"

echo "TRUSTED_PROXIES with addresses and ranges"
proxy_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(c proxy)")
start one "$IMAGE" --network "$net" -e PHPBB_PASSWORD="$T_PASSWORD" -e TRUSTED_PROXIES="$proxy_ip"
check_eq "a trusted proxy's X-Forwarded-For is used" 203.0.113.9 "$(client_addr one proxy)"
check_eq "but not anyone else's" 127.0.0.1 "$(client_addr one)"
start list "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e TRUSTED_PROXIES="10.0.0.0/8, 127.0.0.0/8 fd00::/8"
check_eq "so is a trusted range's, in a list split by commas and spaces" 203.0.113.9 "$(client_addr list)"
check_eq "every entry is trusted" 3 "$(trusted list | grep -c set_real_ip_from)"
launch bad "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e TRUSTED_PROXIES="10.0.0.0/8 localhost"
wait_up bad
check_eq "anything else stops the container" 1 "$(exit_code bad)"
check_has "and says why" "TRUSTED_PROXIES: 'localhost' is not an address, an address range or 'cloudflare'" "$(logs bad)"

echo "TRUSTED_PROXIES=cloudflare"
start cf "$IMAGE" -e PHPBB_PASSWORD="$T_PASSWORD" -e TRUSTED_PROXIES=cloudflare
check "container is running" running cf
check "Cloudflare's IPv4 and IPv6 ranges are trusted" sh -c "test \"\$(docker exec $(c cf) grep -c 'set_real_ip_from [0-9.]*/' /run/nginx/trusted-proxies.conf)\" -gt 5 \
  && docker exec $(c cf) grep -q 'set_real_ip_from [0-9a-f:]*:[0-9a-f:]*/' /run/nginx/trusted-proxies.conf"
check_eq "a request from outside them is not" 127.0.0.1 "$(client_addr cf)"
check_lacks "the copy built into the image is used while it's fresh" "Fetching Cloudflare's IP ranges" "$(logs cf)"
docker exec -e LIST="$STALE_LIST" "$(c cf)" sh -c 'echo "$LIST" > /run/nginx/cloudflare-ips'
backdate cf /run/nginx/cloudflare-ips 20
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
docker restart "$(c cf)" >/dev/null
wait_up cf "$since"
check_lacks "a copy under a month old is kept" "Fetching Cloudflare's IP ranges" "$(docker logs --since "$since" "$(c cf)" 2>&1)"
backdate cf /run/nginx/cloudflare-ips 31
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
docker restart "$(c cf)" >/dev/null
wait_up cf "$since"
check_has "a copy over a month old is fetched again at boot" "Fetching Cloudflare's IP ranges" "$(docker logs --since "$since" "$(c cf)" 2>&1)"
check_lacks "replacing it" "198.51.100.0/24" "$(trusted cf)"
check "with ranges in both families" sh -c "docker exec $(c cf) grep -q '\.' /run/nginx/cloudflare-ips && docker exec $(c cf) grep -q ':' /run/nginx/cloudflare-ips"

echo "TRUSTED_PROXIES=cloudflare without network access"
start offline "$IMAGE" --network none -e PHPBB_PASSWORD="$T_PASSWORD" -e TRUSTED_PROXIES=cloudflare
docker exec -e LIST="$STALE_LIST" "$(c offline)" sh -c 'echo "$LIST" > /run/nginx/cloudflare-ips'
backdate offline /run/nginx/cloudflare-ips 31
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
docker restart "$(c offline)" >/dev/null
wait_up offline "$since"
check "container still starts" running offline
check_has "warns that the fetch failed" "Could not fetch Cloudflare's IP ranges" "$(docker logs --since "$since" "$(c offline)" 2>&1)"
check_has "and keeps the old copy" "set_real_ip_from 198.51.100.0/24;" "$(trusted offline)"

finish
