# Performance, caching, and mobile/lossy-network tuning

Two distinct goals: (a) raw throughput/latency for everyone, (b) *reliable
delivery* on degraded mobile/DPI paths. They overlap but aren't identical.

## Connection efficiency (biggest mobile win)

On a lossy link, the cost is per *connection setup* and per *handshake*, not raw
bandwidth. Minimize both:

```nginx
# http {} level
keepalive_timeout  65;
keepalive_requests 1000;        # many requests over one connection
```

Plus, per vhost: **HTTP/2** (one multiplexed connection for all assets) and
**TLS session reuse** (see `tls-ssl.md`). The combination — HTTP/2 + keep-alive +
session cache — is what turns "big JS chunks never arrive on mobile" into a
working site, because the client stops paying a fresh handshake per asset over a
flaky connection.

## MTU / Path-MTU black hole (OS level, not nginx)

If large responses stall while small ones succeed (see `diagnostics.md`):

```bash
ip link set dev eth0 mtu 1400          # try 1400, then 1280 if still stalling
sysctl -w net.ipv4.tcp_mtu_probing=1   # kernel auto-discovers a working size
```

Persist MTU in netplan/NetworkManager/`ifcfg`; persist the sysctl in
`/etc/sysctl.d/99-net.conf`:

```
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr   # BBR rides loss better than cubic
```

BBR congestion control noticeably improves throughput on lossy/long-RTT paths;
`fq` qdisc is its companion. Confirm BBR is available:
`sysctl net.ipv4.tcp_available_congestion_control`.

## Compression — shrink bytes on the wire

Smaller responses = fewer packets = less to lose on a bad path. **gzip:**

```nginx
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;                # 5 is the sweet spot; 9 costs CPU for ~nothing
gzip_min_length 256;
gzip_types
    text/plain text/css text/xml application/json application/javascript
    application/xml+rss application/atom+xml image/svg+xml
    application/wasm font/ttf font/otf;
```

`gzip` does **not** compress `text/html` by type list — that one is always
compressed when gzip is on. Don't gzip already-compressed types (jpg/png/woff2/
mp4) — wasted CPU.

**Brotli** (better ratio, needs `ngx_brotli` module):

```nginx
brotli on;
brotli_comp_level 5;
brotli_types text/plain text/css application/json application/javascript image/svg+xml;
```

Caveat: if the upstream already gzips, don't double-compress — either let the app
compress or let nginx, not both.

## Static asset caching

```nginx
location ~* \.(?:css|js|woff2?|svg|png|jpg|jpeg|gif|ico|webp|avif)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    access_log off;
    tcp_nodelay off;            # allow coalescing for many small files
}
```

`immutable` tells the browser never to revalidate for the cache lifetime — safe
because modern bundlers fingerprint filenames (`app.4f3a.js`). This is the
*correct* alternative to the `Last-Modified $date_gmt` anti-pattern: cache assets
hard, bust via filename, not by disabling caching.

## Proxy response caching (cache upstream responses in nginx)

```nginx
# http {}
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=app_cache:10m
                 max_size=1g inactive=60m use_temp_path=off;

# location
proxy_cache app_cache;
proxy_cache_valid 200 301 302 10m;
proxy_cache_valid 404 1m;
proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
proxy_cache_background_update on;
proxy_cache_lock on;
add_header X-Cache-Status $upstream_cache_status;   # HIT/MISS/STALE for debugging
```

`use_stale ... updating` + `background_update` keeps serving cached content while
revalidating — great for resilience when the upstream hiccups.

## Buffering — when to turn it off

`proxy_buffering on` (default) lets nginx read the upstream response fast and
drip it to a slow client, freeing the upstream. Turn it **off** only for:
- streaming / SSE / long-poll,
- very large downloads (S3/MinIO) where buffering to disk is wasteful.

For normal HTML/JSON, leave buffering on and tune sizes if you see warnings about
buffering to temp files:

```nginx
proxy_buffers 16 16k;
proxy_buffer_size 32k;
proxy_busy_buffers_size 64k;
```

## Core file-serving primitives

```nginx
# http {}
sendfile on;          # zero-copy file -> socket
tcp_nopush on;         # coalesce headers + file start into fewer packets (with sendfile)
tcp_nodelay on;        # but disable Nagle on keep-alive responses
```

Don't set `sendfile off` as a "fix" — it's a cargo-cult that hurts throughput.

## Worker tuning (nginx.conf top level)

```nginx
worker_processes auto;             # = number of CPU cores
worker_rlimit_nofile 65535;
events {
    worker_connections 8192;       # max conns per worker
    multi_accept on;
}
```

Max clients ≈ `worker_processes × worker_connections` (halved for proxying,
since each client uses one upstream + one client connection).

## A measurement-first mindset

Before tuning, measure. After tuning, re-measure the same way.

```bash
# response timing breakdown for one URL
curl -w 'dns:%{time_namelookup} conn:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' -o /dev/null -s https://example.com

# is HTTP/2 negotiated, what's the TTFB
curl -sI --http2 https://example.com
```

If TTFB is high → upstream/app is slow (nginx tuning won't help much). If
transfer time dominates on mobile only → compression + HTTP/2 + MTU are your
levers.
