# claude-nginx-skill

A deep, production-grade [Claude Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview)
for working with **nginx** — a full-spectrum assistant for **authoring,
configuring, reviewing, hardening, and debugging** configs. It turns Claude (in
Claude Code, the Claude apps, or the Agent SDK) into a version-aware nginx
expert: it writes correct configs from scratch for everyday tasks, and when
something breaks it **diagnoses from logs before changing anything** instead of
pasting generic snippets.

**Everyday tasks it handles** (not just incidents): new site / virtual host,
reverse proxy with WebSockets, TLS/SSL + HTTP/2 + HTTP/3, SPA/Next.js & S3/MinIO
proxying, load balancing & upstreams, caching, gzip/brotli, rate limiting, and
security headers — see the reference files below.

On top of the standard best practices, it encodes real operational lessons that
generic answers miss:

- 📉 **Mobile / lossy-network failures** — Path-MTU black holes, per-request TLS
  overhead, "loads on desktop, infinite spinner on mobile."
- 🛰️ **VPN asymmetry & DPI** — "works through a foreign VPN but not directly"
  (and the reverse): how to tell a server problem from a network/DPI/blocklist
  problem in one minute.
- 🕳️ **Silent config traps** — `add_header` inheritance dropping your security
  headers, `Last-Modified $date_gmt` killing cache, `if`-is-evil, duplicate
  `server` blocks, the HTTP/2 syntax change in nginx 1.25.1, hardcoded
  `X-Forwarded-Proto`.
- 🔒 **Hardening** — security headers done right, rate limiting, real-IP behind a
  CDN, TLS tuning, OCSP, HTTP/3.

## What's inside

```
nginx/
├── SKILL.md                       # entry point: workflow, decision tree, checklist
├── references/
│   ├── diagnostics.md             # "site won't load" — diagnose from logs first
│   ├── proxy-patterns.md          # reverse proxy, WebSocket, SPA/Next.js, S3/MinIO
│   ├── tls-ssl.md                 # certs, HTTP/2 & HTTP/3, TLS tuning, redirects
│   ├── performance-mobile.md      # caching, gzip/brotli, buffers, MTU, BBR
│   ├── security.md                # headers, rate limiting, real-IP, geo
│   └── anti-patterns.md           # the gotchas that cause most "nginx bugs"
└── scripts/
    ├── nginx-check.sh             # read-only: nginx -t + version + anti-pattern scan
    └── diagnose-ip.sh             # classify a connectivity complaint from the access log
```

The skill uses **progressive disclosure**: `SKILL.md` stays short and routes to
the deep reference for the task at hand, so context isn't wasted loading
everything at once.

## Install

### Claude Code (CLI / IDE)

Personal (all your projects):

```bash
git clone https://github.com/tensorshift/claude-nginx-skill.git
cp -r claude-nginx-skill/nginx ~/.claude/skills/nginx
```

Project-scoped (share with your team via the repo):

```bash
mkdir -p .claude/skills
cp -r claude-nginx-skill/nginx .claude/skills/nginx
git add .claude/skills/nginx && git commit -m "Add nginx skill"
```

Then in a session just ask naturally — *"review this nginx config"*, *"the site
won't load on mobile"*, *"set up a reverse proxy with websockets"* — and the
skill activates on its own. (Restart Claude Code if it was running during
install.)

### Claude apps / Agent SDK

Drop the `nginx/` folder into your skills directory (or upload as a Skill in the
app). The `SKILL.md` frontmatter (`name`, `description`) is what Claude matches
against.

## Make the scripts executable

```bash
chmod +x nginx/scripts/*.sh
nginx/scripts/nginx-check.sh /etc/nginx           # scan your configs (read-only)
nginx/scripts/diagnose-ip.sh 203.0.113.7          # classify a complaint by IP
```

Both scripts make **no changes**; they're safe on production.

## Design principles

1. **Diagnose, don't guess.** The access log keyed by the user's IP tells you
   whether a request even arrived. "Seems better" is not a fix.
2. **One concern per change**, always validated with `nginx -t` and a *reload*
   (not restart).
3. **Version-aware.** Several directives changed syntax across releases; the
   skill picks the form that matches the running nginx.
4. **Never touch certs unasked.** `# managed by Certbot` lines are left alone.

## Contributing

Found another real-world gotcha? PRs welcome — add it to the relevant reference
and, if detectable, a grep rule to `nginx-check.sh`.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, share it with your team.

> Built collaboratively with Claude Code, distilled from real incident
> debugging. Not affiliated with nginx or F5.
