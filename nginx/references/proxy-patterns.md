# Reverse-proxy patterns

Copy-adapt these. Every block assumes a TLS-terminating nginx in front of an app
bound to `127.0.0.1` (the app should **not** listen on a public interface).

## Shared upgrade map (define once, at `http` level)

WebSockets need `Connection: upgrade` only when the client requested an upgrade,
otherwise `Connection: close`. Do this with a `map`, never a hardcoded header:

```nginx
# /etc/nginx/conf.d/00-upgrade-map.conf  (or inside http{} in nginx.conf)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

If a config uses `$connection_upgrade`, this map must exist somewhere in the
`http` context. Defining it twice = `duplicate map` error. If you split configs
across files, keep the map in exactly one shared file.

## 1. Generic HTTP app (REST API, admin panel)

```nginx
server {
    listen 443 ssl http2;          # see tls-ssl.md for the version-correct form
    server_name api.example.com;

    ssl_certificate     /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;     # raise for upload endpoints (default 1m)

    location / {
        proxy_pass http://127.0.0.1:5000;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # real scheme, not literal
        proxy_set_header X-Forwarded-Host  $host;

        proxy_http_version 1.1;
        proxy_set_header Connection "";   # enable keep-alive to upstream
    }
}
server { listen 80; server_name api.example.com; return 301 https://$host$request_uri; }
```

`proxy_set_header Connection ""` clears the hop-by-hop header so nginx can pool
keep-alive connections to the upstream (pair with an `upstream { keepalive N; }`
block for high-traffic backends — see below).

## 2. SPA / Next.js / React / Vite frontend (WebSocket + HMR)

The thing that breaks "mobile won't load" frontends is missing HTTP/2 + missing
upgrade headers. Include both:

```nginx
server {
    listen 443 ssl http2;
    server_name app.example.com;

    # ... ssl ... (certbot block)
    keepalive_timeout 65;

    location / {
        proxy_pass http://127.0.0.1:3000;
        client_max_body_size 100M;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket / HMR / Server-Sent Events
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

**Do NOT** add `add_header Last-Modified $date_gmt;` to "always serve fresh" — it
stamps every response as just-modified, so clients never cache and re-download
every JS chunk on each visit. On lossy/mobile links this *causes* the infinite
loading you were trying to avoid. If you must bust cache on deploys, version your
asset URLs (the framework already does this) — don't disable caching globally.

## 3. S3 / MinIO API (object storage)

```nginx
server {
    listen 443 ssl http2;
    server_name s3.example.com;
    # ... ssl ...

    ignore_invalid_headers off;     # S3 sends headers nginx considers invalid
    client_max_body_size 0;         # 0 = unlimited; large object uploads
    proxy_buffering off;            # stream, don't buffer big objects to disk
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:9000;

        proxy_set_header Host              $host;   # S3 signature depends on Host
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme; # MUST match real scheme (https)
        proxy_set_header Connection "";

        proxy_http_version 1.1;
        proxy_connect_timeout 300;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;
    }
}
```

Gotchas:
- **`X-Forwarded-Proto` must be the real scheme.** A hardcoded `http` while
  serving over HTTPS makes MinIO generate `http://` presigned URLs / mismatched
  signatures → `SignatureDoesNotMatch` or mixed-content. Use `$scheme` (or
  `https` on a pure-443 vhost).
- **`Host` must be forwarded** unchanged — S3 v4 signatures include it.
- Console (`:9001`) is a separate vhost and **does** need the WebSocket upgrade
  headers; the S3 API (`:9000`) does not.

## 4. MinIO Console (web UI on :9001)

Same as the SPA pattern (needs WebSocket upgrade) but pointing at `:9001`, with
`proxy_buffering off` and long timeouts for the console's streaming endpoints.

## 5. Upstream block with keep-alive + load balancing

```nginx
upstream app_backend {
    server 127.0.0.1:5000 max_fails=3 fail_timeout=10s;
    server 127.0.0.1:5001 max_fails=3 fail_timeout=10s;
    keepalive 32;              # pooled idle connections; requires the two lines
}                              # below in the location:

location / {
    proxy_pass http://app_backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}
```

Load-balancing methods: default round-robin, `least_conn;`, or `ip_hash;`
(sticky by client IP). Add `zone app_backend 64k;` to share state across workers.

## 6. Serving static files directly (faster than proxying)

```nginx
location /static/ {
    alias /var/www/app/static/;
    expires 1y;
    add_header Cache-Control "public, immutable";
    access_log off;
    try_files $uri =404;
}
```

For an SPA's client-side routing, fall back to `index.html`:

```nginx
location / {
    root /var/www/app/dist;
    try_files $uri $uri/ /index.html;
}
```

## Timeouts — what each one means

| Directive | Controls |
|---|---|
| `proxy_connect_timeout` | establishing the TCP connection to upstream (keep short, e.g. 60s) |
| `proxy_send_timeout` | gap between successive writes **to** upstream |
| `proxy_read_timeout` | gap between successive reads **from** upstream (raise for slow APIs/streams) |
| `send_timeout` | gap between successive writes **to the client** |
| `keepalive_timeout` | how long to hold an idle client connection (65s typical) |

Don't blanket everything to `3600s` — that masks hung upstreams. Use long reads
only where you genuinely stream (downloads, SSE, websockets, S3).

## Common proxy failures

| Error | Usual cause |
|---|---|
| `502 Bad Gateway` | upstream down / wrong port / crashed app; check `proxy_pass` target is listening |
| `504 Gateway Timeout` | upstream too slow; raise `proxy_read_timeout` *and* fix the slow endpoint |
| `413 Request Entity Too Large` | `client_max_body_size` too small for the upload |
| `400` on S3 | missing `ignore_invalid_headers off` or wrong `Host` |
| redirect loop | app sees `http` (missing `X-Forwarded-Proto`) and 301s back to https forever |
| WebSocket closes immediately | missing `proxy_http_version 1.1` / upgrade headers |
