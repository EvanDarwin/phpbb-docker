#!/bin/sh
# Fetch Cloudflare's published IP ranges into FILE, one range per line, for
# TRUSTED_PROXIES=cloudflare. FILE is only replaced when both lists download and
# every line is an address range.
set -eu
out="$1"
tmp="$out.new"
trap 'rm -f "$tmp"' EXIT

v4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4)
v6=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6)
printf '%s\n%s\n' "$v4" "$v6" | sed '/^$/d' > "$tmp"

if grep -qvE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$' "$tmp" \
    || ! grep -q '\.' "$tmp" || ! grep -q ':' "$tmp"; then
  echo "Cloudflare's IP lists did not contain only IPv4 and IPv6 ranges" >&2
  exit 1
fi
mv "$tmp" "$out"
