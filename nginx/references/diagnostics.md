# Diagnostics — "the site won't load"

The single most valuable habit: **diagnose from the access log keyed by the
complaining user's IP, before changing anything.** nginx writes deceptive `200`s
(it counts bytes written to *its* socket, not bytes that reached the client), so
"the log says 200" does not mean the user got the page.

## Step 0 — Classify the symptom (ask the user)

| Symptom | Likely layer | First reference |
|---|---|---|
| Infinite spinner, page half-loads, big JS chunks never arrive | Server / MTU / HTTP-overhead | this file → "Size-dependent stall" |
| Instant error, `ERR_CONNECTION_RESET`, TLS handshake fails | Path / DPI / firewall / blacklist | this file → "Silence in the log" |
| Works via foreign VPN, NOT directly (server in same country) | DPI/ТСПУ or routing or IP blacklist | this file → "VPN asymmetry" |
| Works directly, NOT via foreign VPN | Geo-block in app/firewall, or VPN exit IP banned | this file → "VPN asymmetry" |
| Slow everywhere, all users | Performance/caching | `performance-mobile.md` |
| 502 / 504 / 413 / redirect loop | Config/upstream | `proxy-patterns.md`, `anti-patterns.md` |

## The core technique — read the log by IP

```bash
# nginx runs on the host (proxy_pass to 127.0.0.1): logs on the host
grep '<client_ip>' /var/log/nginx/access.log

# multiple vhosts / custom log path:
grep '<client_ip>' /var/log/nginx/<site>.log
```

Interpretation:

- **Small files arrive (200), large chunks repeatedly truncate / restart** →
  *size-dependent stall* = our layer (MTU black hole, or per-request TLS/connect
  overhead on a lossy path). Fixable on the server.
- **Total silence from that IP** → the request never reached nginx. Problem is
  on the path between client and server (operator, DPI/ТСПУ, firewall, IP
  blacklist, bad DNS). **nginx tuning cannot fix this** — needs CDN, IP change,
  or network-side resolution.
- **Entries appear but stop at TLS** (use `curl -v`, see below) → handshake-level
  interference (SNI-based DPI) or cert problem.

## Client-side one-liners (have the affected user run these)

```bash
curl -v https://example.com            # where does it die: DNS / TLS / after?
curl -v --http1.1 https://example.com  # does forcing HTTP/1.1 change behavior?
nslookup example.com                   # is the resolver returning the right IP?
tracert example.com   # (Windows)  /  mtr example.com  (Linux) — where path dies
ping -s 1472 -M do example.com         # Linux: probe MTU (1472+28=1500). Shrink
                                       # until it passes -> that's the path MTU.
```

`curl -v` reading guide:
- dies at `Could not resolve host` → DNS.
- stalls after `Client Hello` / `TLS handshake` with no `Server Hello` → SNI DPI
  or firewall reset mid-handshake.
- handshake OK, then hangs mid-transfer on big responses → MTU / size stall.
- gets an HTTP `403`/`451`/app error → the request *reached* the app; it's an
  app-level geo/permission block, not nginx.

## Size-dependent stall (Path-MTU black hole)

**Mechanism:** the server sends full-size 1500-byte packets; a constrained path
(LTE, some VPNs, tunnels, certain DPI boxes) can't pass them, and the ICMP
"fragmentation needed" is dropped by an operator → large transfers wedge
mid-stream. HTML, CSS, and tiny chunks arrive; large JS bundles don't. Classic
"infinite loading."

**Fixes (server-side, survive deploys):**

```bash
# 1. Lower the interface MTU. Try 1400 first, then 1280 (the floor) if needed.
ip link set dev eth0 mtu 1400

# 2. Enable MTU probing so the kernel finds a working packet size itself.
sysctl -w net.ipv4.tcp_mtu_probing=1
```

Persist both: MTU in netplan/`ifcfg`/NetworkManager; the sysctl in
`/etc/sysctl.d/99-mtu.conf` (`net.ipv4.tcp_mtu_probing = 1`). 1280 is the IPv6
minimum and a sane floor — below that, only a CDN in front helps.

**Also reduce per-request overhead** (often the real win — see this convo's
case): enable HTTP/2 + keep-alive + TLS session reuse so the client isn't doing
a fresh expensive handshake per asset on a lossy link. See `tls-ssl.md` and
`performance-mobile.md`.

## VPN asymmetry (the tricky one)

The server's country is irrelevant on its own; what matters is the *route*.

- **Works via foreign VPN, fails directly** (server in same country as user):
  the domestic path is being filtered/degraded. Candidates: DPI/ТСПУ (SNI-based
  resets or packet mangling), bad domestic routing, or the server IP/domain on a
  national blocklist. Quick decisive check: **look up the server IP in the
  relevant national block registry** — if listed, only an IP change or in-country
  CDN helps. Otherwise it's DPI: confirm with "silence in log" + `curl -v` dying
  at handshake.
- **Works directly, fails via foreign VPN**: nginx itself has no geo-block in a
  plain reverse-proxy config — so look at (1) **geo-blocking in the app** behind
  `proxy_pass` (returns 403 to foreign IPs — you'll see the request *in* the
  log), (2) **server firewall** (`iptables`/`ufw`/fail2ban) or host geo-filter
  dropping foreign subnets (silence in log), or (3) the **specific VPN exit IP**
  being banned (try another exit — if it works, it's the IP, not the site).

**Decision rule:** request present in log → our side (app/firewall/geo); silence
→ path/network. This split tells you in one minute whether to touch the server
at all.

## What nginx can and cannot fix

| Can fix on server | Cannot fix on server (needs CDN / IP change / network) |
|---|---|
| MTU black hole (lower MTU + probing) | DPI/ТСПУ blocking at SNI/packet level |
| Per-request TLS overhead (HTTP/2, keep-alive, session reuse) | IP/domain on a national blocklist |
| 502/504/413, redirect loops, header bugs | Operator routing problems |
| Slow TLS (OCSP stapling, session cache) | Client-side broken DNS / captive portal |

When the root cause is DPI/blocklist, the legitimate mitigations are: put a CDN
with in-country PoPs in front, change the server IP/subnet, or wait for
network-side resolution. Do **not** deploy censorship-circumvention tooling on
hosting infrastructure — it typically violates the provider's ToS.

## Reporting the outcome

State plainly what you changed and whether logs confirmed the fix. "After
lowering MTU, full large chunks appeared in the access log for the same mobile
IPs" is proof; "seems better" is not. If part of the cause is external (DPI),
say so — your fix shrinks the blast radius, it doesn't remove an upstream cause.
