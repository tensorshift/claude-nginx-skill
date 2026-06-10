#!/usr/bin/env bash
#
# nginx-check.sh — read-only sanity + anti-pattern scan for nginx configs.
# Makes NO changes. Safe to run on production.
#
# Usage:
#   ./nginx-check.sh                 # check the live config (nginx -t) + scan /etc/nginx
#   ./nginx-check.sh path/to.conf    # scan a single file (and nginx -t if root)
#   ./nginx-check.sh /etc/nginx      # scan a directory tree
#
set -uo pipefail

TARGET="${1:-/etc/nginx}"
RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'
issues=0

note() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; issues=$((issues+1)); }
bad()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*"; issues=$((issues+1)); }
ok()   { printf '%s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$DIM" "$*" "$RST"; }

# --- nginx version + syntax test (if binary present) -------------------------
hdr "nginx version & syntax"
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1 | sed 's/^/    /'
  ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$ver" ]; then
    # http2-directive support landed in 1.25.1
    maj=${ver%%.*}; rest=${ver#*.}; min=${rest%%.*}; pat=${rest#*.}
    if [ "$maj" -gt 1 ] || { [ "$maj" -eq 1 ] && [ "$min" -gt 25 ]; } \
       || { [ "$maj" -eq 1 ] && [ "$min" -eq 25 ] && [ "$pat" -ge 1 ]; }; then
      ok "nginx $ver supports the 'http2 on;' directive form"
    else
      note "nginx $ver is < 1.25.1 — use 'listen 443 ssl http2;' (NOT 'http2 on;')"
    fi
  fi
  if [ "$(id -u)" = "0" ]; then
    if nginx -t 2>&1 | sed 's/^/    /'; then :; fi
  else
    printf '    %s(run as root for nginx -t)%s\n' "$DIM" "$RST"
  fi
else
  printf '    %s(nginx binary not found — static scan only)%s\n' "$DIM" "$RST"
fi

# --- gather files ------------------------------------------------------------
if [ -d "$TARGET" ]; then
  mapfile -t FILES < <(grep -rlE '.' "$TARGET" --include='*.conf' 2>/dev/null)
  [ ${#FILES[@]} -eq 0 ] && mapfile -t FILES < <(find "$TARGET" -name '*.conf' 2>/dev/null)
elif [ -f "$TARGET" ]; then
  FILES=("$TARGET")
else
  bad "target not found: $TARGET"; exit 2
fi

scan() { grep -REn "$1" "${FILES[@]}" 2>/dev/null; }

# --- duplicate / conflicting server_name + listen ----------------------------
hdr "server_name / listen map (look for duplicates)"
grep -REn 'server_name|listen ' "${FILES[@]}" 2>/dev/null \
  | sed 's/[[:space:]]\+/ /g' | sed 's/^/    /' || true
dupes=$(grep -rhoE 'server_name[[:space:]]+[^;]+;' "${FILES[@]}" 2>/dev/null \
        | sort | uniq -d)
[ -n "$dupes" ] && note "duplicate server_name lines found:"$'\n'"$dupes"

# --- anti-pattern scan -------------------------------------------------------
hdr "anti-pattern scan"

m=$(scan 'add_header[[:space:]]+Last-Modified[[:space:]]+\$date_gmt') \
  && [ -n "$m" ] && bad "Last-Modified \$date_gmt (cache killer, breaks mobile):"$'\n'"$m"

m=$(scan 'X-Forwarded-Proto[[:space:]]+http;') \
  && [ -n "$m" ] && note "hardcoded 'X-Forwarded-Proto http;' (should be \$scheme/https):"$'\n'"$m"

m=$(scan 'keepalive_timeout[[:space:]]+0') \
  && [ -n "$m" ] && note "keepalive_timeout 0 (forces handshake per request):"$'\n'"$m"

m=$(scan 'sendfile[[:space:]]+off') \
  && [ -n "$m" ] && note "sendfile off (hurts throughput):"$'\n'"$m"

m=$(scan 'proxy_set_header[[:space:]]+Connection[[:space:]]+["'"'"']?close') \
  && [ -n "$m" ] && note "Connection: close to upstream (no keep-alive):"$'\n'"$m"

# http2 presence on 443
if grep -REn 'listen[[:space:]]+443[[:space:]]+ssl' "${FILES[@]}" 2>/dev/null \
     | grep -vq 'http2'; then
  if ! scan 'http2[[:space:]]+on' >/dev/null; then
    note "found 'listen 443 ssl' without http2 — enable HTTP/2 (better on mobile)"
  fi
fi

# websocket upgrade without http_version 1.1
if scan 'Upgrade[[:space:]]+\$http_upgrade' >/dev/null; then
  scan 'proxy_http_version[[:space:]]+1.1' >/dev/null \
    || note "Upgrade header set but no 'proxy_http_version 1.1;' nearby — WS may drop"
fi

# if wrapping risky directives
m=$(grep -REn -A2 '^\s*if[[:space:]]*\(' "${FILES[@]}" 2>/dev/null \
     | grep -E 'proxy_pass|add_header|try_files') \
  && [ -n "$m" ] && note "'if' appears to wrap proxy_pass/add_header/try_files (if-is-evil):"$'\n'"$m"

# duplicate ssl_protocols alongside certbot include
if scan 'options-ssl-nginx.conf' >/dev/null && scan 'ssl_protocols' >/dev/null; then
  note "both certbot's options-ssl-nginx.conf include AND a manual ssl_protocols — likely duplicate"
fi

# --- summary -----------------------------------------------------------------
hdr "summary"
if [ "$issues" -eq 0 ]; then
  ok "no anti-patterns detected (still run 'nginx -t' as root to confirm syntax)"
else
  printf '%s%d potential issue(s) flagged above.%s Review, then: nginx -t && systemctl reload nginx\n' \
    "$YEL" "$issues" "$RST"
fi
exit 0
