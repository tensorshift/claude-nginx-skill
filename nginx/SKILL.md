---
name: nginx
description: >-
  Expert assistant for nginx — for everyday config work AND tricky debugging.
  Use it to set up a new site from scratch, write or refactor server/location
  blocks, configure a reverse proxy (proxy_pass, upstreams, load balancing),
  set up TLS/SSL and certificates, enable HTTP/2 or HTTP/3, wire up WebSockets,
  serve a SPA/Next.js/React frontend, proxy S3/MinIO, add caching/gzip/brotli,
  rate limiting, security headers, or real-IP behind a CDN. Also use it to
  review/harden an existing config, or to debug problems: a site that "won't
  load", is "slow on mobile", "works through VPN but not directly" (or
  vice-versa), returns 502/504/413, has redirect loops, or cert/SNI errors.
  Keywords: nginx, reverse proxy, proxy_pass, location, server block, virtual
  host, certbot, letsencrypt, websocket, upstream, load balancer, 502 bad
  gateway.
---

# nginx

Deep, practical guidance for **writing, configuring, reviewing, and debugging**
nginx — a full-spectrum nginx assistant, not just an incident-response tool. Use
it for routine setup (new vhost, reverse proxy, TLS, caching, security) just as
much as for hard problems. On top of standard best practices it encodes
hard-won operational lessons (mobile/MTU black holes, DPI filtering, `add_header`
inheritance traps, HTTP/2 syntax drift across versions) so answers are correct
and version-aware instead of generic snippets.

## What this skill helps with

**Authoring & setup (the everyday case):**

- Stand up a new site / virtual host from scratch (HTTP→HTTPS, certs, HTTP/2).
- Reverse proxy to an app: correct headers, WebSockets, timeouts, keep-alive.
- Frontends (SPA / Next.js / React), object storage (S3/MinIO), APIs.
- Load balancing and `upstream` pools.
- Caching (static + proxy cache), gzip/brotli compression.
- TLS/SSL setup and tuning, HTTP/3, OCSP stapling, redirects.
- Security hardening: headers, rate limiting, real-IP behind a CDN, allow/deny.

**Review & refactor:**

- Audit an existing `.conf` against the checklist below; clean up cruft.

**Debug (when something's wrong):**

- "Won't load", slow on mobile, VPN asymmetry, 502/504/413, redirect loops,
  cert/SNI errors — diagnosed from logs, not guesswork.

## How to use this skill

1. **Identify the task type** and jump to the matching reference. For **setup/
   authoring**, produce a complete, correct config from the patterns in the
   references (adapted to the user's stack), then validate it. For **debugging**,
   diagnose from logs first, then make the minimal correct change — don't paste a
   generic config at a problem you haven't localized.
2. **Always preserve a path to rollback.** Before editing a production `.conf`,
   note the original. Never touch `ssl_certificate*` lines unless explicitly
   asked.
3. **Validate before declaring done.** Every change must pass `nginx -t`. Tell
   the user to run `nginx -t && systemctl reload nginx` (reload, not restart —
   reload is zero-downtime).
4. **Be version-aware.** Several directives changed syntax across nginx
   releases (see Anti-patterns → "HTTP/2 syntax"). When unsure, ask for
   `nginx -v` or use the backward-compatible form.

## Decision tree — pick the right reference

| The user is… | Go to |
|---|---|
| Reporting a site that won't load / loads partially / slow on mobile / works only via VPN | `references/diagnostics.md` (start here — **diagnose, don't guess**) |
| Setting up or fixing a reverse proxy, WebSocket, SPA/Next.js, or S3/MinIO | `references/proxy-patterns.md` |
| Working on certificates, TLS tuning, HTTP/2, HTTP/3, SNI, redirects | `references/tls-ssl.md` |
| Chasing performance: caching, gzip/brotli, buffers, keepalive, MTU | `references/performance-mobile.md` |
| Hardening: security headers, rate limiting, IP allow/deny, real IP behind CDN | `references/security.md` |
| Getting a weird result (headers vanish, redirect loop, 1 server wins) | `references/anti-patterns.md` (read this before blaming nginx) |

## Core review checklist (apply to any `.conf` you touch)

Run through this whenever you review or write a config:

- **`nginx -t` clean?** Syntax + duplicate `server_name` + missing files.
- **HTTP/2 enabled** on `listen 443`? Use the version-correct syntax.
- **Reverse proxy headers** present: `Host`, `X-Real-IP`, `X-Forwarded-For`,
  `X-Forwarded-Proto`? Is `X-Forwarded-Proto` the *real* scheme (`https`, not a
  hardcoded `http`)?
- **WebSocket** endpoints have `proxy_http_version 1.1` + `Upgrade` +
  `Connection` upgrade map?
- **`add_header` inheritance**: does any `location` re-declare `add_header` and
  thereby silently drop security/CORS headers from the parent? (See
  anti-patterns — this is the #1 silent bug.)
- **No `add_header Last-Modified $date_gmt`** or similar cache-busting hacks
  that force clients to re-download everything (kills mobile).
- **No duplicate `server` blocks** / conflicting `server_name`.
- **`if` used only for safe things** (`return`/`rewrite ... last`), never to
  wrap `proxy_pass` or `add_header` (see "if is evil").
- **`client_max_body_size`** set appropriately for upload endpoints (default
  1m causes 413 on file uploads).
- **TLS session reuse** configured (directly or via certbot's
  `options-ssl-nginx.conf`) so mobile clients don't renegotiate per request.
- **Redirects**: single clean `return 301 https://$host$request_uri;` — not a
  pile of certbot `if` blocks.

## Golden rules

- **Diagnose from logs, not vibes.** "Seems better" is not a fix. For
  connectivity/loading complaints, the access log keyed by the user's IP tells
  you whether the request even arrived. See `references/diagnostics.md`.
- **Reload, don't restart.** `systemctl reload nginx` re-reads config with no
  dropped connections. Restart only when changing `worker_*` or modules.
- **One concern per change.** When debugging, change one thing, re-test, keep
  or revert. Don't stack five "fixes" — that's how the bad configs in the wild
  got their cargo-cult cruft.
- **Reproduce the cert layout, never invent it.** If certs are `# managed by
  Certbot`, leave those lines alone; certbot rewrites them on renewal.
- **Prefer `map` over `if`.** Most `if` use cases are better as `map` at
  `http` level.

## Provided scripts

- `scripts/nginx-check.sh` — runs `nginx -t`, prints version, lists every
  `server_name`/`listen` pair to spot duplicates and conflicts, and flags
  common anti-patterns (literal `X-Forwarded-Proto http`, `Last-Modified
  $date_gmt`, missing `http2`, `if` wrapping risky directives). Read-only.
- `scripts/diagnose-ip.sh <IP> [access_log]` — classifies a connectivity
  complaint by grepping the access log for one client IP: requests arriving but
  large responses truncating → server/MTU layer; total silence → path/DPI
  problem upstream of nginx. Implements the workflow in `diagnostics.md`.

Run scripts with the config or log path as argument; they make no changes.
