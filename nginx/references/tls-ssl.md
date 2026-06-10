# TLS / SSL, HTTP/2, HTTP/3, certificates, redirects

## HTTP/2 syntax — version matters (top cause of failed `nginx -t`)

nginx changed how HTTP/2 is enabled in **1.25.1**:

```nginx
# nginx >= 1.25.1 — directive form (preferred on new versions)
server {
    listen 443 ssl;
    http2 on;
    ...
}

# nginx < 1.25.1 — the listen-parameter form
server {
    listen 443 ssl http2;
    ...
}
```

- On **old** nginx, `http2 on;` fails with `unknown directive "http2"`.
- On **new** nginx, `listen ... http2` still works but logs a deprecation
  warning.
- **Backward-compatible choice when you don't know the version:** use
  `listen 443 ssl http2;`. It works on everything from 1.9.5 through current
  (warning only on the newest). Check with `nginx -v` if you want to be exact.

`http2 on;` is per-`server`; `listen ... http2` is technically per-listen-socket
(all servers on that socket get it). For typical one-vhost-per-port setups this
distinction doesn't bite.

## HTTP/3 (QUIC) — optional, nginx 1.25+ with `http_v3_module`

```nginx
server {
    listen 443 quic reuseport;     # UDP/443 for QUIC (reuseport once per port)
    listen 443 ssl;                # keep TCP/443 for HTTP/1.1 + HTTP/2 fallback
    http2 on;

    ssl_certificate     ...;
    ssl_certificate_key ...;

    # advertise h3 so browsers upgrade on the next visit
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
}
```

Requires firewall to allow **UDP/443**. HTTP/3 helps exactly the lossy-mobile
case (no head-of-line blocking, connection migration across IP changes), so it's
a strong upgrade for the "mobile won't load" class of problems — but only if the
build includes the QUIC module (`nginx -V 2>&1 | grep http_v3`).

## TLS session reuse — critical for mobile

A full TLS handshake per request is brutal on lossy links. Reuse sessions:

```nginx
ssl_session_cache   shared:SSL:10m;   # ~40k sessions per 10m
ssl_session_timeout 1d;
ssl_session_tickets off;              # off is safer (no ticket-key rotation risk)
```

certbot's `options-ssl-nginx.conf` already sets these (and `ssl_protocols`,
`ssl_ciphers`). **If you `include` that file, do NOT also set `ssl_protocols`
yourself** — you'll get `duplicate value "TLSv1.2"` warnings. Check what the
included file defines before adding your own TLS directives.

## Protocols and ciphers (when NOT using certbot's include)

```nginx
ssl_protocols TLSv1.2 TLSv1.3;        # drop TLSv1/1.1 (insecure, and DPI-prone)
ssl_prefer_server_ciphers off;        # let modern clients pick (TLS1.3 ignores this)
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
```

Dual-certificate (ECDSA primary, RSA fallback) gives fast modern handshakes
while staying compatible with old clients:

```nginx
ssl_certificate     /etc/ssl/ecdsa/fullchain.pem;
ssl_certificate_key /etc/ssl/ecdsa/privkey.pem;
ssl_certificate     /etc/ssl/rsa/fullchain.pem;     # second pair = RSA fallback
ssl_certificate_key /etc/ssl/rsa/privkey.pem;
```

## OCSP stapling (faster handshake, privacy)

```nginx
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
```

## HSTS (force HTTPS in the browser)

```nginx
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
```

Add `preload` only if you intend to submit to the HSTS preload list (it's hard
to undo). **Mind `add_header` inheritance** — see `anti-patterns.md`; if a
`location` has its own `add_header`, repeat HSTS there too or it vanishes.

## Certificates — naming and SNI

- One cert per `server_name`, **or** a multi-SAN cert covering several names.
  Serving `lk.example.com` with a cert issued only for `api.example.com` →
  browser `NET::ERR_CERT_COMMON_NAME_INVALID` for everyone. Verify:
  ```bash
  openssl x509 -in /etc/letsencrypt/live/<name>/fullchain.pem -noout -text \
    | grep -A1 'Subject Alternative Name'
  ```
- **Never hand-edit `# managed by Certbot` cert lines** — certbot rewrites them
  on renewal and your edits are lost. To change cert paths, reissue with certbot.
- Wildcard certs (`*.example.com`) need DNS-01 validation, not HTTP-01.

## HTTP → HTTPS redirect — do it cleanly

certbot tends to leave a pile of `if ($host = ...) { return 301 ... }` blocks.
Collapse to one:

```nginx
server {
    listen 80;
    server_name api.example.com lk.example.com s3.example.com;
    return 301 https://$host$request_uri;
}
```

This is faster and avoids the `if`-evil pitfalls. `$host` preserves whichever
name was requested.

## Redirect loops

Almost always: the app behind the proxy doesn't know it's already on HTTPS
(because `X-Forwarded-Proto` is missing or hardcoded `http`), so it 301s to
HTTPS, which proxies back, forever. Fix by forwarding the real scheme:
`proxy_set_header X-Forwarded-Proto $scheme;` and configuring the app to trust
it (e.g. Django `SECURE_PROXY_SSL_HEADER`, Express `trust proxy`).

## Quick TLS verification

```bash
# what protocol/cipher/cert a client actually negotiates
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -dates -subject -issuer

# is HTTP/2 actually on?
curl -sI --http2 https://example.com | grep -i '^HTTP'   # expect HTTP/2 200

# is HTTP/3 advertised?
curl -sI https://example.com | grep -i alt-svc
```
