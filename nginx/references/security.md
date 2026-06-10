# Security hardening

Layered defaults. Apply what fits; don't blindly paste everything (CSP and HSTS
preload in particular can break things if misconfigured).

## Security response headers

```nginx
# Force HTTPS (see tls-ssl.md for preload caveat)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

# Clickjacking
add_header X-Frame-Options "SAMEORIGIN" always;

# MIME sniffing
add_header X-Content-Type-Options "nosniff" always;

# Referrer leakage
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Feature access
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# Content Security Policy — START IN REPORT-ONLY, then enforce
add_header Content-Security-Policy-Report-Only "default-src 'self'; img-src 'self' data: https:; script-src 'self'" always;
```

**The `add_header` inheritance trap (read this):** `add_header` directives are
**not** additive across contexts. If a `location` block contains *any*
`add_header`, nginx **discards every `add_header` inherited from the server/http
level** for that location. So your HSTS/CSP/nosniff silently vanish on exactly
the routes that added one CORS header. Solutions:
- put all security headers at `server` level **and** don't add headers in
  locations (preferred), or
- if a location must add a header, **repeat the full security set** there, or
- use the `ngx_headers_more` module's `more_set_headers` (which behaves
  additively and can also remove headers).

Always use the `always` flag so headers are sent on error responses (4xx/5xx)
too, not just 2xx/3xx.

## Hide version / banner

```nginx
# http {}
server_tokens off;        # drop nginx version from Server header and error pages
```

For full banner removal you need `ngx_headers_more`: `more_clear_headers Server;`.

## Rate limiting (brute-force / abuse)

```nginx
# http {} — define zones
limit_req_zone  $binary_remote_addr zone=req_general:10m rate=20r/s;
limit_req_zone  $binary_remote_addr zone=req_login:10m   rate=5r/m;
limit_conn_zone $binary_remote_addr zone=conn_perip:10m;

# location — apply with a burst (token bucket)
location / {
    limit_req  zone=req_general burst=40 nodelay;
    limit_conn conn_perip 20;
    ...
}
location /api/login {
    limit_req zone=req_login burst=3 nodelay;   # tight on auth endpoints
    ...
}
```

`burst` allows short spikes; `nodelay` serves the burst immediately instead of
queuing. Return code for throttled requests defaults to 503; set
`limit_req_status 429;` for correct semantics.

**Behind a CDN/proxy**, `$binary_remote_addr` is the CDN's IP — useless for
per-user limits. Fix real-IP first (next section), then rate-limit.

## Real client IP behind a CDN / load balancer

Without this, logs and rate-limits see the proxy, not the user:

```nginx
# trust your CDN/LB ranges (example: Cloudflare — keep this list updated)
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
# ... full provider range list ...
real_ip_header   CF-Connecting-IP;     # or X-Forwarded-For for a generic LB
real_ip_recursive on;
```

Only trust `X-Forwarded-For` from IPs you control — otherwise clients can spoof
their IP. `real_ip_recursive on` walks the XFF chain skipping trusted hops.

## IP allow / deny (geo or explicit)

```nginx
# explicit allowlist for an admin path
location /admin/ {
    allow 203.0.113.0/24;
    allow 10.0.0.0/8;
    deny  all;
    ...
}
```

Geo-blocking by country uses the `ngx_http_geoip2_module` + a MaxMind DB:

```nginx
# http {}
geoip2 /etc/nginx/GeoLite2-Country.mmdb {
    $geoip2_country_code country iso_code;
}
map $geoip2_country_code $allowed_country {
    default yes;
    # CN no;            # example: block specific countries
}
# server/location
if ($allowed_country = no) { return 403; }
```

(`if` for `return` is one of the *safe* uses — see anti-patterns.)

## Method / path filtering

```nginx
# allow only sane methods
if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|OPTIONS|PATCH)$) {
    return 405;
}

# block hidden files except ACME challenge
location ~ /\.(?!well-known) { deny all; }
```

## Request size limits (DoS hygiene)

```nginx
client_max_body_size 10m;          # per the endpoint's real need
client_body_timeout  10s;
client_header_timeout 10s;
large_client_header_buffers 4 16k;
```

## TLS hardening

See `tls-ssl.md`: TLS 1.2+ only, modern ciphers, OCSP stapling, HSTS. Test the
result with SSL Labs or `testssl.sh`.

## What NOT to do

- Don't expose backend admin ports (DB, MinIO console, metrics) on public
  vhosts without auth + IP allowlist.
- Don't `proxy_pass` to `0.0.0.0`-bound apps; bind apps to `127.0.0.1`.
- Don't put secrets (passwords, tokens) in config comments or error pages.
- Don't disable `server_tokens` and then forget the `Server` header still leaks
  via error pages — combine with `ngx_headers_more`.
- Don't add `add_header` in a location and assume server-level headers survive.
