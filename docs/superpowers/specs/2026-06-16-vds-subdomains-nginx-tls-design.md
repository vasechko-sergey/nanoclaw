# VDS Domain + Subdomain Split + nginx + Wildcard TLS

**Date:** 2026-06-16
**Status:** Approved design — ready for implementation plan
**Host:** `148.253.211.164` (Debian 13 trixie), service account `nanoclaw`

## Goal

Put a real domain in front of the services running on the VDS, split them across
subdomains, terminate TLS at nginx, and restrict every fronted service so the
**only** external access path is `https://<sub>.DOMAIN`. Today the iOS app reaches
Jarvis over a raw Tailscale IP (`100.94.184.60:3001`, plain `ws://`); the
freqtrade bots and the x-ui panel are exposed on `0.0.0.0` over plain HTTP.

`DOMAIN` is a placeholder throughout — the operator buys it at Cloudflare (see
Prerequisites). All commands substitute the real domain at implementation time.

## Current State (verified 2026-06-16)

| Service | Port | Bind | Public now | Disposition |
|---|---|---|---|---|
| nanoclaw iOS endpoint (WS + `/ios/*`) | 3001 | `0.0.0.0` | yes, no TLS | **front → `jarvis.DOMAIN`**, bind localhost |
| nanoclaw webhook server | 3000 | `0.0.0.0` | idle | leave (out of scope) |
| nanoclaw credential proxy | 3002 | `172.17.0.1` | no (docker only) | **never expose** 🔒 |
| OneCLI vault UI | 10254 | `127.0.0.1` | no | **never expose** 🔒 |
| x-ui web panel | 2096 | `0.0.0.0` | yes, plain HTTP | **front → `panel.DOMAIN`**, bind localhost |
| xray VLESS+TLS inbound | 8443 | `*` | yes | **leave untouched** (VPN) |
| xray inbounds (rotating) | 32889/41891/50811 | `*` | yes | **leave untouched** (VPN) |
| freqtrade NFIX6 (FreqUI+REST+WS) | 8089 | `0.0.0.0` | yes | **front → `freq1.DOMAIN`**, bind localhost |
| freqtrade NFIX7 (FreqUI+REST+WS) | 8088 | `0.0.0.0` | yes | **front → `freq2.DOMAIN`**, bind localhost |
| sshd | 22 | `0.0.0.0` | yes | leave |

**Ports 80 and 443 are free.** xray VPN sits on 8443/2096/random — no conflict
with nginx on 80/443.

## Target Subdomain Map

All A-records → `148.253.211.164`, Cloudflare **DNS-only (grey cloud)** — Cloudflare
is used only as the DNS provider for the ACME DNS-01 challenge; it is **not** a proxy
in the data path (keeps WebSockets clean; origin IP is already visible via the VPN, so
proxying buys nothing).

| Subdomain | Upstream | Protocols | WS upgrade |
|---|---|---|---|
| `jarvis.DOMAIN` | `127.0.0.1:3001` | WSS + HTTPS (`/ios/*`) | yes |
| `freq1.DOMAIN` | `127.0.0.1:8089` | HTTPS + live WS | yes |
| `freq2.DOMAIN` | `127.0.0.1:8088` | HTTPS + live WS | yes |
| `panel.DOMAIN` | `127.0.0.1:2096` | HTTPS (plain-HTTP upstream) | no |

One wildcard cert `*.DOMAIN` (+ apex `DOMAIN`) covers all four and any future
subdomain with zero extra cert work.

## Components

### 1. TLS — Let's Encrypt wildcard via DNS-01 (Cloudflare)

- Packages: `certbot`, `python3-certbot-dns-cloudflare`.
- Cloudflare API token scoped **Zone → DNS → Edit** for the one zone only, stored at
  `/etc/letsencrypt/cloudflare.ini`, `chmod 600`, root-owned. Never committed.
- Issue:
  ```
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d DOMAIN -d '*.DOMAIN' \
    --deploy-hook "systemctl reload nginx" \
    -m vasechkoss@gmail.com --agree-tos --no-eff-email
  ```
- Auto-renew: the certbot Debian package installs a systemd timer; the stored
  `cloudflare.ini` + the saved `--deploy-hook` make renewal fully unattended. Verify
  with `certbot renew --dry-run`.

### 2. nginx

- Package: `nginx` (Debian).
- A shared WebSocket upgrade map in `conf.d`:
  ```nginx
  map $http_upgrade $connection_upgrade {
      default upgrade;
      ''      close;
  }
  ```
- A **default catch-all** server returning `444` so hitting the raw IP / unknown Host
  (no valid SNI) drops the connection — services answer only on their real subdomain.
- One `server` block per subdomain, all sharing the wildcard cert
  (`/etc/letsencrypt/live/DOMAIN/{fullchain,privkey}.pem`).
- `jarvis` + `freq*` WS locations set `proxy_http_version 1.1`,
  `Upgrade`/`Connection $connection_upgrade`, and `proxy_read_timeout 3600s`
  (iOS socket is long-lived).
- Port 80 server block → `301` to HTTPS (UX; DNS-01 does not need port 80, but the
  redirect makes typo'd `http://` URLs work).
- Standard proxy headers: `Host $host`, `X-Real-IP`, `X-Forwarded-For`,
  `X-Forwarded-Proto $scheme`.

Reference config (per subdomain, `DOMAIN`/upstream substituted):

```nginx
# /etc/nginx/sites-available/jarvis.DOMAIN
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name jarvis.DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

`freq1` (→8089) and `freq2` (→8088) are identical with their upstream port.
`panel.DOMAIN` (→2096) drops the `Upgrade`/timeout lines (no WS).

HTTP redirect + catch-all:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
    return 444;
}
```

### 3. DNS (Cloudflare dashboard, operator-performed)

A-records, all **DNS-only (grey)**: `jarvis`, `freq1`, `freq2`, `panel` →
`148.253.211.164`. (Apex `DOMAIN` optional — unused or redirect later.)

## Data-Flow Changes

- **iOS cutover (no rebuild):** in the app Settings, change `serverURL` from
  `100.94.184.60:3001` to `wss://jarvis.DOMAIN`. Verified runtime-safe: `serverURL`
  is `@AppStorage` (`AppSettings.swift:7`); `WebSocketClientV2.swift:204-215`
  normalizes scheme (`wss://` kept, used directly by `URLSession` over TLS:443);
  `StateService.swift:15` / `HealthRequests.swift:18` / `HealthUpload.swift:21` map
  `wss://`→`https://` for the REST calls. Keep the Tailscale value noted as fallback.
- **Telegram, APNs, credential proxy, OneCLI:** unchanged.

## Hardening (approved — lock raw ports to localhost)

After nginx is confirmed serving each subdomain, make TLS the only door:

- **freqtrade ×2:** locate each container's compose/run definition
  (`docker inspect <name>` → compose working-dir label), change the port publish from
  `0.0.0.0:8089:8089` → `127.0.0.1:8089:8089` (and `:8088` for the other), recreate
  the two containers. Auth (FreqUI login) already present; this removes the plaintext
  public surface.
- **x-ui panel:** set the panel **listen IP** to `127.0.0.1` (3x-ui `x-ui setting`
  flag or panel Settings page), restart x-ui. Only moves the web panel (2096) to
  localhost; the xray VLESS inbound on 8443 and rotating ports are separate configs
  and are **not** touched, so the VPN keeps working.
- **No global ufw.** The xray VPN uses rotating high ports; a firewall risks killing
  the VPN. Localhost-binding is surgical and VPN-safe. ufw can be added later once the
  operator pins the VPN's port set.

## Security Boundary (firm)

- Credential proxy (`3002`, docker-bridge) and OneCLI vault UI (`10254`, localhost)
  **must never** be placed behind any public subdomain — they inject secrets.
- nginx fronts **only** 3001 / 8089 / 8088 / 2096.
- The Cloudflare API token is DNS-edit-scoped to the single zone, `chmod 600`,
  server-side only, never committed.

## Prerequisites (operator-performed, before implementation)

1. Buy `DOMAIN` at **Cloudflare Registrar** (DNS lands on Cloudflare automatically),
   or buy elsewhere and move the nameservers to Cloudflare (DNS-01 needs CF-hosted DNS).
2. Create the four grey-cloud A-records (above).
3. Create the scoped Cloudflare API token; hand it over for `/etc/letsencrypt/cloudflare.ini`.

## Verification

- `certbot certonly` succeeds; `/etc/letsencrypt/live/DOMAIN/` populated;
  `certbot renew --dry-run` passes.
- `nginx -t` clean; `systemctl reload nginx` ok.
- `curl -I https://panel.DOMAIN/<basepath>/` → 200/302 (x-ui login).
- `curl https://freq1.DOMAIN/api/v1/ping` and `freq2` → `{"status":"pong"}`.
- `curl -i https://jarvis.DOMAIN/ios/state` → **401** (route reachable, auth enforced).
- iOS app with `serverURL = wss://jarvis.DOMAIN` connects, chat + health round-trip.
- After hardening: from off-box, `curl http://148.253.211.164:8089/`, `:8088`, `:2096`
  all **fail/refused**; the same via `https://<sub>.DOMAIN` **succeed**.
- `curl -k https://148.253.211.164/` (raw IP, no SNI) → connection closed (444).

## Risks / Notes

- freqtrade FreqUI is same-origin through the proxy → no CORS change. If live updates
  error, add `https://freq1.DOMAIN` to that bot's `api_server.CORS_origins` + restart.
- x-ui panel has a secret base-path → `panel.DOMAIN/` 404s; `panel.DOMAIN/<path>/` works.
- **Lockout rollback:** after localhost-binding, reach a service for debugging via SSH
  tunnel, e.g. `ssh -L 2096:127.0.0.1:2096 root@148.253.211.164`. iOS reverts by
  setting `serverURL` back to the Tailscale value.
- DNS-01 wildcard requires DNS hosted at Cloudflare — non-negotiable for this approach.

## Out of Scope

Webhook endpoint (3000) exposure; OneCLI UI exposure; routing the xray VPN through
nginx/443; global ufw.
