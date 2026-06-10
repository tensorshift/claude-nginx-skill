#!/usr/bin/env bash
#
# diagnose-ip.sh — classify a "site won't load" complaint from the access log,
# for ONE client IP. Read-only. Implements references/diagnostics.md.
#
# Usage:
#   ./diagnose-ip.sh <client_ip> [access_log]
#   ./diagnose-ip.sh 203.0.113.7 /var/log/nginx/access.log
#
# It answers the key question: did this client's requests even REACH nginx, and
# if so, are LARGE responses truncating while small ones succeed?
#
set -uo pipefail

IP="${1:-}"
LOG="${2:-/var/log/nginx/access.log}"
RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'

if [ -z "$IP" ]; then
  echo "usage: $0 <client_ip> [access_log]"; exit 2
fi
if [ ! -r "$LOG" ]; then
  echo "${RED}cannot read log:${RST} $LOG"; exit 2
fi

echo "${DIM}== scanning $LOG for $IP ==${RST}"
hits=$(grep -c -- "$IP" "$LOG" 2>/dev/null || echo 0)

if [ "$hits" -eq 0 ]; then
  cat <<EOF
${RED}[SILENCE]${RST} No log entries from $IP.
  The request never reached nginx => the problem is on the PATH between client
  and server (operator routing, DPI/ТСПУ, firewall, IP blacklist, or bad DNS).
  nginx tuning CANNOT fix this.

  Next:
   - Have the client run:  curl -v https://<your-domain>
       * dies at TLS handshake (no Server Hello) -> SNI-based DPI / firewall reset
       * cannot resolve host                     -> DNS
   - Check if the SERVER IP is on a national block registry.
   - Check server firewall (iptables/ufw/fail2ban) for dropped foreign subnets.
   - Mitigation if DPI/blocklist: in-country CDN, or change server IP/subnet.
EOF
  exit 0
fi

echo "${GRN}[REACHED]${RST} $hits request(s) from $IP are in the log."
echo

# Show the slice and try to read status + bytes-sent. Default nginx 'combined'
# format: ... "GET /path HTTP/1.1" STATUS BYTES "referer" "ua"
echo "${DIM}-- recent entries (last 15) --${RST}"
grep -- "$IP" "$LOG" | tail -15 | sed 's/^/   /'
echo

# Heuristic: compare bytes for big asset requests vs small ones.
# Pull (status, bytes, path) triples.
awk -v ip="$IP" '
  index($0, ip) {
    # find the quoted request to get the path, and the two fields after it
    if (match($0, /"[A-Z]+ [^"]*"/)) {
      req = substr($0, RSTART, RLENGTH)
      rest = substr($0, RSTART+RLENGTH)
      n = split(rest, a, " ")
      status = a[2]; bytes = a[3]
      # path = 2nd token of req
      split(req, r, " "); path = r[2]
      print status, bytes, path
    }
  }
' "$LOG" > /tmp/.diag_ip.$$ 2>/dev/null

big_trunc=0; big_total=0
while read -r status bytes path; do
  case "$path" in
    *.js|*.css|*.map|*.woff2|*.png|*.jpg|*.webp|*.mp4|*.wasm|*.chunk.*)
      big_total=$((big_total+1))
      # crude: a "big asset" that returned very few bytes likely truncated
      if [ "${bytes:-0}" -lt 2000 ] 2>/dev/null && [ "$status" = 200 ]; then
        big_trunc=$((big_trunc+1))
      fi
      ;;
  esac
done < /tmp/.diag_ip.$$
rm -f /tmp/.diag_ip.$$

echo "${DIM}-- assessment --${RST}"
if [ "$big_total" -gt 0 ] && [ "$big_trunc" -gt 0 ]; then
  cat <<EOF
${YEL}[SIZE-DEPENDENT STALL]${RST} $big_trunc of $big_total large-asset responses
  returned suspiciously few bytes with status 200. nginx logs 200 for bytes
  written to its OWN socket, not bytes that reached the client — classic symptom
  of an MTU black hole or per-request handshake overhead on a lossy path.

  Server-side fixes (survive deploys):
   - ip link set dev eth0 mtu 1400      # then 1280 if still stalling
   - sysctl -w net.ipv4.tcp_mtu_probing=1
   - enable HTTP/2 + keep-alive + TLS session reuse (see references/tls-ssl.md)
EOF
else
  cat <<EOF
${GRN}[REQUESTS COMPLETING]${RST} No obvious size-dependent truncation detected in
  the sampled entries. If the user still reports failure:
   - check the STATUS codes above (403/451 = app-level geo/permission block;
     499 = client closed early; 5xx = upstream).
   - confirm with client-side 'curl -v' where it actually fails.
   - if only large uploads fail -> client_max_body_size (413).
EOF
fi
exit 0
