# Anti-patterns & gotchas — read before blaming nginx

Real bugs from real configs. Most "nginx is broken" tickets are one of these.

## 1. `add_header` does NOT inherit when a child redeclares it

If a `location` (or `if`) contains **any** `add_header`, nginx **drops all
`add_header` from the enclosing `server`/`http` context** for that location. Your
HSTS, CSP, `X-Content-Type-Options` silently disappear on exactly the routes that
added a CORS header.

```nginx
server {
    add_header X-Frame-Options SAMEORIGIN always;   # set at server level
    location /api/ {
        add_header Access-Control-Allow-Origin * always;  # <-- this DROPS X-Frame-Options here!
    }
}
```

Fix: don't mix — keep all headers at one level, or repeat the full set in the
child, or use `ngx_headers_more`'s `more_set_headers` (additive).

## 2. `Last-Modified $date_gmt;` — the cache killer

```nginx
add_header Last-Modified $date_gmt; if_modified_since exact;   # ANTI-PATTERN
```

`$date_gmt` is the *current time*, so every response is stamped "modified just
now" → browsers never use cache → re-download every asset on every visit. On
mobile/lossy links this *causes* infinite loading. Remove it. To force-refresh
on deploy, version asset filenames (bundlers do this already); never globally
defeat caching.

## 3. "if is evil" — only `return`/`rewrite ... last` are safe inside `if`

The `if` directive in `location` context has surprising, buggy behavior with
most other directives (`proxy_pass`, `add_header`, `try_files`, `set` can all
misbehave or silently no-op). Officially safe uses: `return ...;` and
`rewrite ... last;`. Everything else → use `map`, `try_files`, or separate
`location`/`server` blocks instead.

```nginx
# BAD — proxy_pass inside if
if ($something) { proxy_pass http://a; }

# GOOD — map + variable, or distinct locations
map $something $backend { default http://a; "x" http://b; }
location / { proxy_pass $backend; }
```

## 4. Duplicate `server` blocks / conflicting `server_name`

Pasting a config twice (or two files matching the same name+port) yields:
`conflicting server name "x" on 0.0.0.0:443, ignored`. nginx keeps the **first**
and ignores the rest — so your "edit" to the second copy does nothing. Grep for
duplicates:

```bash
grep -rn 'server_name' /etc/nginx/ | sort -k2
```

## 5. HTTP/2 syntax mismatch across versions

`http2 on;` requires nginx ≥ 1.25.1; older nginx needs `listen 443 ssl http2;`.
Using the wrong one → `unknown directive "http2"` and a failed reload. See
`tls-ssl.md`. When in doubt, use the `listen ... http2` form (works everywhere,
warns only on newest).

## 6. Duplicate `ssl_protocols` (and friends) when including certbot's file

`include /etc/letsencrypt/options-ssl-nginx.conf;` already sets `ssl_protocols`,
`ssl_ciphers`, `ssl_session_cache`, `ssl_session_tickets`. Setting them again
yourself → `duplicate value "TLSv1.2"` warnings (and confusion about which wins).
Check the included file before adding TLS directives.

## 7. Hardcoded `X-Forwarded-Proto http` while serving HTTPS

```nginx
proxy_set_header X-Forwarded-Proto http;     # WRONG on a 443 server
```

The app (or MinIO/S3) thinks the request was plaintext → generates `http://`
links / presigned URL signature mismatches / redirect loops. Use `$scheme` (or
`https` on a pure-443 vhost).

## 8. Redirect loop from missing scheme

App behind proxy doesn't know it's on HTTPS → 301s to HTTPS → proxied back →
loop. Always forward `X-Forwarded-Proto $scheme;` and make the app trust it.

## 9. Default `client_max_body_size` is 1 MB → surprise 413

File-upload endpoints fail with `413 Request Entity Too Large` until you raise
it (per-location is fine; `0` = unlimited, use only for trusted storage proxies).

## 10. `proxy_pass` with vs without a trailing URI changes path rewriting

```nginx
location /api/ { proxy_pass http://up;      }   # keeps /api/ prefix -> http://up/api/...
location /api/ { proxy_pass http://up/;     }   # STRIPS /api/      -> http://up/...
```

A trailing slash (or any path) on `proxy_pass` makes nginx replace the matched
`location` prefix. Mismatched expectations here cause 404s that look like routing
bugs. Also note: when `proxy_pass` uses a variable or an `upstream` name, URI
rewriting rules differ — test explicitly.

## 11. `keepalive_timeout 0` / `Connection: close` / `sendfile off`

A cluster of cargo-cult "fixes" that make things worse: forcing a new TLS
handshake per request (`keepalive 0` / `Connection: close`) and disabling
zero-copy (`sendfile off`). These are the *opposite* of what mobile/lossy paths
need. If you inherit a config with these, removing them is usually a net win.

## 12. Missing WebSocket upgrade headers

`proxy_pass` without `proxy_http_version 1.1` + `Upgrade`/`Connection` headers →
WebSocket/HMR/SSE connections drop instantly. See `proxy-patterns.md`.

## 13. `worker_connections` too low / `worker_rlimit_nofile` not raised

Default `worker_connections 512` (or 768) caps concurrency; raise both it and
`worker_rlimit_nofile` for busy proxies, or you'll see "worker_connections are
not enough" in the error log.

## 14. Editing `# managed by Certbot` lines

certbot rewrites those lines on renewal — your manual edits to cert paths or the
redirect `if` blocks get clobbered. Make cert changes through certbot; structure
the rest of the file around its managed blocks.

## 15. Trusting `X-Forwarded-For` from the whole internet

Without `set_real_ip_from` restricting trust to your CDN/LB, clients can spoof
`X-Forwarded-For` to forge their IP (bypassing allowlists/rate-limits and
poisoning logs). Only trust XFF from known proxy ranges.

## Quick smell-test grep

```bash
# run against a config to surface the common ones
grep -REn 'date_gmt|X-Forwarded-Proto[[:space:]]+http;|keepalive_timeout[[:space:]]+0|sendfile[[:space:]]+off|Connection[[:space:]]+close' /etc/nginx/
```
