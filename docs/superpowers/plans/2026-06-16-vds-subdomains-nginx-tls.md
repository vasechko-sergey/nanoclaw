# VDS Domain + Subdomain Split + nginx + Wildcard TLS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Front the VDS services (Jarvis iOS endpoint, two freqtrade bots, x-ui panel) behind nginx on per-subdomain HTTPS with a Let's Encrypt DNS-01 wildcard cert, then lock the raw ports to localhost so the domain is the only external door.

**Architecture:** nginx terminates TLS on :443 using one `*.DOMAIN` wildcard cert (issued via Cloudflare DNS-01, auto-renewing). Four `server` blocks reverse-proxy to `127.0.0.1:{3001,8089,8088,2096}`; a default catch-all drops bare-IP/unknown-Host traffic. The nginx config is authored in-repo (`deploy/vds/`) and rendered+deployed — never hand-edited on the box. After verification, the upstream services are rebound to localhost. The Jarvis credential proxy (3002) and OneCLI vault (10254) are never exposed.

**Tech Stack:** nginx, certbot + `python3-certbot-dns-cloudflare`, Cloudflare DNS, `envsubst`, Debian 13. Target host `148.253.211.164` (system services as `root`; nanoclaw app as service user `nanoclaw`).

**Placeholder:** `DOMAIN` = the real domain, substituted at deploy time. It is never committed to the repo.

**Live-system caution:** Jarvis (daily use), the xray VPN, and two trading bots run on this box. Every task is reversible and verifies before any rebind. The xray VPN (8443 + rotating ports) is never touched.

---

## File Structure (repo changes)

- Create: `deploy/vds/nanoclaw-vds.conf.template` — the full nginx config (map + catch-all + 4 server blocks), `${DOMAIN}`-parameterized.
- Create: `deploy/vds/render.sh` — renders the template via `envsubst` (whitelisting only `${DOMAIN}` so nginx `$variables` survive).
- Create: `deploy/vds/README.md` — deploy/runbook notes.
- Modify: `.gitignore` — ignore `deploy/vds/rendered/` (rendered file contains the real domain).

On-VDS (not in repo): `/etc/nginx/conf.d/nanoclaw-vds.conf`, `/etc/letsencrypt/cloudflare.ini`, `/etc/letsencrypt/live/DOMAIN/`.

---

## Phase 0 — Operator prerequisites (GATE — plan pauses here)

These require the operator's Cloudflare account + payment; they cannot be automated.

### Task 0: Domain, DNS, API token

- [ ] **Step 1: Buy the domain at Cloudflare Registrar**

Buy `DOMAIN` at Cloudflare (DNS lands on Cloudflare automatically). If bought elsewhere, add the site to Cloudflare and switch the registrar's nameservers to the Cloudflare pair. DNS-01 **requires** CF-hosted DNS.

- [ ] **Step 2: Create A-records (Cloudflare dashboard → DNS)**

All **DNS-only (grey cloud)**, each → `148.253.211.164`:

```
A   jarvis   148.253.211.164   DNS only
A   freq1    148.253.211.164   DNS only
A   freq2    148.253.211.164   DNS only
A   panel    148.253.211.164   DNS only
```

- [ ] **Step 3: Create a scoped API token (Cloudflare → My Profile → API Tokens → Create Token → "Edit zone DNS")**

Permissions: **Zone → DNS → Edit**. Zone Resources: **Include → Specific zone → DOMAIN**. Copy the token; hand it over out-of-band (not in the repo, not in chat history if avoidable).

- [ ] **Step 4: Verify DNS resolves**

Run (from any machine):
```bash
dig +short jarvis.DOMAIN A
```
Expected: `148.253.211.164` (may take a few minutes after creation).

**GATE:** Do not proceed past Phase 0 until `dig` returns the VDS IP and the API token is in hand.

---

## Phase 1 — Author nginx config in-repo

### Task 1: Create the rendered nginx config template + render script

**Files:**
- Create: `deploy/vds/nanoclaw-vds.conf.template`
- Create: `deploy/vds/render.sh`
- Create: `deploy/vds/README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Write the nginx config template**

Create `deploy/vds/nanoclaw-vds.conf.template`:

```nginx
# Managed in repo: deploy/vds/nanoclaw-vds.conf.template
# Render:  DOMAIN=<domain> ./deploy/vds/render.sh
# Deploy:  scp -> /etc/nginx/conf.d/nanoclaw-vds.conf  (then: nginx -t && systemctl reload nginx)
# Upstreams: jarvis=3001 (iOS WS+/ios/*), freq1=8089, freq2=8088, panel=2096 (x-ui).
# Never expose: 3002 (credential proxy), 10254 (OneCLI vault).

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP -> HTTPS for everything.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

# HTTPS catch-all: drop bare-IP scans / unknown Host (no valid SNI).
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    return 444;
}

# jarvis -> nanoclaw iOS endpoint (WebSocket + /ios/* HTTP)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name jarvis.${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

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

# freq1 -> freqtrade NFIX6
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name freq1.${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8089;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }
}

# freq2 -> freqtrade NFIX7
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name freq2.${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }
}

# panel -> x-ui web panel (plain-HTTP upstream)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name panel.${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:2096;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- [ ] **Step 2: Write the render script**

Create `deploy/vds/render.sh`:

```bash
#!/usr/bin/env bash
# Render the nanoclaw VDS nginx config from the template.
# Usage: DOMAIN=example.com ./deploy/vds/render.sh
set -euo pipefail
: "${DOMAIN:?set DOMAIN, e.g. DOMAIN=example.com ./deploy/vds/render.sh}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/rendered"
# Whitelist ONLY ${DOMAIN} so nginx runtime vars ($host, $http_upgrade, ...) are untouched.
envsubst '${DOMAIN}' < "$here/nanoclaw-vds.conf.template" > "$here/rendered/nanoclaw-vds.conf"
echo "rendered -> $here/rendered/nanoclaw-vds.conf (DOMAIN=$DOMAIN)"
```

- [ ] **Step 3: Write the README**

Create `deploy/vds/README.md`:

```markdown
# VDS nginx + TLS

Reverse-proxy config fronting the VDS services on per-subdomain HTTPS.
Spec: ../../docs/superpowers/specs/2026-06-16-vds-subdomains-nginx-tls-design.md

## Map
| Subdomain     | Upstream         | Service                         |
|---------------|------------------|---------------------------------|
| jarvis.DOMAIN | 127.0.0.1:3001   | nanoclaw iOS endpoint (WS+HTTP) |
| freq1.DOMAIN  | 127.0.0.1:8089   | freqtrade NFIX6                 |
| freq2.DOMAIN  | 127.0.0.1:8088   | freqtrade NFIX7                 |
| panel.DOMAIN  | 127.0.0.1:2096   | x-ui web panel                  |

Never exposed: 3002 (credential proxy), 10254 (OneCLI vault), xray VPN ports.

## Deploy
    DOMAIN=example.com ./render.sh
    scp rendered/nanoclaw-vds.conf root@148.253.211.164:/etc/nginx/conf.d/nanoclaw-vds.conf
    ssh root@148.253.211.164 'rm -f /etc/nginx/sites-enabled/default && nginx -t && systemctl reload nginx'

TLS: Let's Encrypt wildcard `*.DOMAIN` via Cloudflare DNS-01 (certbot, auto-renew).
```

- [ ] **Step 4: Ignore the rendered output**

Append to `.gitignore`:
```
deploy/vds/rendered/
```

- [ ] **Step 5: Make the render script executable + render against a throwaway domain to prove substitution**

Run:
```bash
chmod +x deploy/vds/render.sh
DOMAIN=example.test ./deploy/vds/render.sh
grep -c 'example.test' deploy/vds/rendered/nanoclaw-vds.conf
grep -c '\$host' deploy/vds/rendered/nanoclaw-vds.conf
grep -c '\${DOMAIN}' deploy/vds/rendered/nanoclaw-vds.conf
```
Expected: first grep ≥ 6 (one per cert path + server_name), second grep ≥ 4 (nginx vars survived), third grep = `0` (no unsubstituted placeholders).

- [ ] **Step 6: Commit**

```bash
git add deploy/vds/nanoclaw-vds.conf.template deploy/vds/render.sh deploy/vds/README.md .gitignore
git commit -m "feat(deploy): in-repo nginx reverse-proxy config for VDS subdomains"
```

---

## Phase 2 — Install nginx + certbot, issue wildcard cert (VDS)

### Task 2: Install packages

- [ ] **Step 1: Install nginx, certbot, and the Cloudflare DNS plugin**

Run:
```bash
ssh root@148.253.211.164 'apt-get update && apt-get install -y nginx certbot python3-certbot-dns-cloudflare gettext-base'
```
Expected: installs without error; `gettext-base` provides `envsubst` (harmless if already present).

- [ ] **Step 2: Confirm nginx is up and owns 80/443**

Run:
```bash
ssh root@148.253.211.164 'systemctl is-active nginx; ss -tlnp "( sport = :80 or sport = :443 )"'
```
Expected: `active`; nginx listening on 80 and 443. (If install pulled a default site, that's fine — replaced in Task 4.)

### Task 3: Write Cloudflare credentials

- [ ] **Step 1: Write the credentials file with the operator's token (token NOT logged)**

Run (substitute the real token in place of `<CF_TOKEN>`; do not echo it back):
```bash
ssh root@148.253.211.164 'umask 077; install -d -m 700 /etc/letsencrypt; printf "dns_cloudflare_api_token = %s\n" "<CF_TOKEN>" > /etc/letsencrypt/cloudflare.ini; chmod 600 /etc/letsencrypt/cloudflare.ini; ls -l /etc/letsencrypt/cloudflare.ini'
```
Expected: `-rw------- 1 root root ... /etc/letsencrypt/cloudflare.ini`.

- [ ] **Step 2: Verify perms (no group/other access)**

Run:
```bash
ssh root@148.253.211.164 'stat -c "%a %U" /etc/letsencrypt/cloudflare.ini'
```
Expected: `600 root`.

### Task 4: Issue the wildcard certificate

- [ ] **Step 1: Request `*.DOMAIN` + apex via DNS-01**

Run (substitute `DOMAIN`):
```bash
ssh root@148.253.211.164 'certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini --dns-cloudflare-propagation-seconds 30 -d DOMAIN -d "*.DOMAIN" --deploy-hook "systemctl reload nginx" -m vasechkoss@gmail.com --agree-tos --no-eff-email --non-interactive'
```
Expected: `Successfully received certificate.` and cert saved to `/etc/letsencrypt/live/DOMAIN/fullchain.pem`.

- [ ] **Step 2: Confirm the cert exists and covers the wildcard**

Run:
```bash
ssh root@148.253.211.164 'ls -l /etc/letsencrypt/live/DOMAIN/; openssl x509 -in /etc/letsencrypt/live/DOMAIN/fullchain.pem -noout -text | grep -A1 "Subject Alternative Name"'
```
Expected: `fullchain.pem`/`privkey.pem` present; SAN lists `DNS:DOMAIN, DNS:*.DOMAIN`.

- [ ] **Step 3: Prove auto-renew is wired**

Run:
```bash
ssh root@148.253.211.164 'systemctl list-timers certbot.timer --no-pager; certbot renew --dry-run'
```
Expected: `certbot.timer` listed/active; dry-run ends `Congratulations, all simulations of renewals succeeded`.

---

## Phase 3 — Deploy nginx config + verify subdomains (VDS)

### Task 5: Render, deploy, reload

- [ ] **Step 1: Render with the real domain and deploy**

Run (substitute `DOMAIN`):
```bash
DOMAIN=DOMAIN ./deploy/vds/render.sh
scp deploy/vds/rendered/nanoclaw-vds.conf root@148.253.211.164:/etc/nginx/conf.d/nanoclaw-vds.conf
```
Expected: render prints the output path; scp copies one file.

- [ ] **Step 2: Remove the stock default site so our catch-all `default_server` is unique**

Run:
```bash
ssh root@148.253.211.164 'rm -f /etc/nginx/sites-enabled/default; nginx -t'
```
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful` (no "duplicate default server" error). If a duplicate-default error appears, also check `/etc/nginx/conf.d/` for a stock `default.conf` and remove it.

- [ ] **Step 3: Reload nginx**

Run:
```bash
ssh root@148.253.211.164 'systemctl reload nginx && systemctl is-active nginx'
```
Expected: `active`.

### Task 6: Verify each subdomain end-to-end over HTTPS

- [ ] **Step 1: Jarvis route reachable + auth enforced**

Run:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://jarvis.DOMAIN/ios/state
```
Expected: `401` (route proxied to 3001; bearer required = correct).

- [ ] **Step 2: freqtrade bots answer through TLS**

Run:
```bash
curl -sS https://freq1.DOMAIN/api/v1/ping; echo
curl -sS https://freq2.DOMAIN/api/v1/ping; echo
```
Expected: `{"status":"pong"}` from each.

- [ ] **Step 3: x-ui panel reachable through TLS**

Run (substitute the panel's secret base-path):
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://panel.DOMAIN/<basepath>/
```
Expected: `200` or `302` (panel login). `https://panel.DOMAIN/` returning `404` is normal (base-path gating).

- [ ] **Step 4: Catch-all drops bare-IP / unknown Host**

Run:
```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://148.253.211.164/ --resolve 148.253.211.164:443:148.253.211.164
curl -sS -o /dev/null -w "%{http_code}\n" http://jarvis.DOMAIN/ios/state -L --max-redirs 0 2>/dev/null || true
```
Expected: first → `000`/closed (444, no response body); second (plain HTTP) → `301` to https.

- [ ] **Step 5: Valid cert chain (no `-k` needed)**

Run:
```bash
curl -sSI https://jarvis.DOMAIN/ios/state | head -1
```
Expected: an HTTP status line with **no** TLS error (cert trusted by the system CA store).

---

## Phase 4 — iOS cutover (operator, no rebuild)

### Task 7: Point the app at the domain

- [ ] **Step 1: Change the server URL in the app**

In the Jarvis iOS app → Settings → server field: replace `100.94.184.60:3001` with:
```
wss://jarvis.DOMAIN
```
(Leave the bearer token unchanged.) Verified runtime-safe: `serverURL` is `@AppStorage` (`ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift:7`); `WebSocketClientV2.swift:204-215` keeps the `wss://` scheme for the TLS WebSocket; `StateService.swift:15`, `HealthRequests.swift:18`, `HealthUpload.swift:21` map `wss://`→`https://` for REST. No rebuild.

- [ ] **Step 2: Verify the app connects over the domain**

In the app: the connection banner goes green; send a chat message and confirm a reply; open the state/health view and confirm it loads. (Optionally watch `journalctl --machine=nanoclaw@.host --user -u nanoclaw -f` during connect for the inbound WS.)
Expected: chat round-trips; health/state populates.

- [ ] **Step 3: Record the fallback**

Note the old Tailscale value (`100.94.184.60:3001`) — reverting the setting to it restores the pre-domain path if needed. No code change to roll back.

---

## Phase 5 — Hardening: rebind raw ports to localhost (GATE — touches trading bots + panel)

> Each rebind makes the service reachable **only** via its HTTPS subdomain. Auth already exists on all three. Confirm timing with the operator before recreating trading containers. The xray VPN is not touched.

### Task 8: Bind freqtrade ports to localhost

- [ ] **Step 1: Locate each bot's compose definition + current port publish**

Run:
```bash
ssh root@148.253.211.164 'for n in Freq_Test_Bot_bybit_futures-NostalgiaForInfinityX6 Freq_Test_Bot_bybit_futures-NostalgiaForInfinityX7; do echo "== $n =="; docker inspect "$n" --format "wd={{ index .Config.Labels \"com.docker.compose.project.working_dir\"}} files={{ index .Config.Labels \"com.docker.compose.project.config_files\"}}"; docker port "$n"; done'
```
Expected: prints each compose working-dir + compose file path, and the `8089/8088 -> 0.0.0.0` publishes. Note the two compose file paths.

- [ ] **Step 2: Back up the compose file(s)**

Run (substitute the discovered compose dir(s); if both bots share one file, do it once):
```bash
ssh root@148.253.211.164 'cd <compose_dir> && cp docker-compose.yml docker-compose.yml.bak.20260616'
```
Expected: backup created.

- [ ] **Step 3: Restrict the published ports to localhost**

Edit the compose file(s): change the port mappings
```
"8089:8089"  ->  "127.0.0.1:8089:8089"
"8088:8088"  ->  "127.0.0.1:8088:8088"
```
(Exact key may be `ports:` list entries. Only the host side gains the `127.0.0.1:` prefix.) Apply on the VDS with `sed` or an editor; show the diff:
```bash
ssh root@148.253.211.164 'cd <compose_dir> && grep -nE "808[89]" docker-compose.yml'
```
Expected: both entries now prefixed `127.0.0.1:`.

- [ ] **Step 4: Recreate the two bots (brief UI/API blip; exchange-side trades unaffected)**

Run:
```bash
ssh root@148.253.211.164 'cd <compose_dir> && docker compose up -d'
```
Expected: the two containers recreate; `docker ps` shows them healthy again.

- [ ] **Step 5: Verify localhost-only + still served via TLS**

Run:
```bash
ssh root@148.253.211.164 'docker port Freq_Test_Bot_bybit_futures-NostalgiaForInfinityX6; docker port Freq_Test_Bot_bybit_futures-NostalgiaForInfinityX7'
curl -sS https://freq1.DOMAIN/api/v1/ping; echo
curl -sS --max-time 6 http://148.253.211.164:8089/ -o /dev/null -w "direct8089=%{http_code}\n" || echo "direct8089=refused"
```
Expected: `docker port` now shows `127.0.0.1:8089`/`:8088`; `freq1` TLS → `pong`; direct `:8089` → `refused`/timeout.

### Task 9: Bind the x-ui panel to localhost

- [ ] **Step 1: Find the exact setting flag (3x-ui CLI, as root)**

Run:
```bash
ssh root@148.253.211.164 'x-ui setting -show 2>/dev/null | grep -iE "listen|port|basepath" || x-ui help 2>&1 | head -40'
```
Expected: shows current panel listen IP/port/base-path, and/or the `setting` flags (look for a listen-IP flag such as `-listenIP`).

- [ ] **Step 2: Set the panel listen IP to 127.0.0.1**

Preferred (CLI, substitute the flag confirmed in Step 1):
```bash
ssh root@148.253.211.164 'x-ui setting -listenIP 127.0.0.1 && x-ui restart'
```
If the CLI lacks the flag: in the panel UI (still reachable via `https://panel.DOMAIN`) → Panel Settings → **Listen IP = 127.0.0.1** → Save → Restart Panel.
Expected: panel restarts.

- [ ] **Step 3: Verify panel is localhost-only, VPN still up, panel still served via TLS**

Run:
```bash
ssh root@148.253.211.164 'ss -tlnp "sport = :2096"; ss -tlnp "sport = :8443"'
curl -sS --max-time 6 http://148.253.211.164:2096/ -o /dev/null -w "direct2096=%{http_code}\n" || echo "direct2096=refused"
curl -sS -o /dev/null -w "panelTLS=%{http_code}\n" https://panel.DOMAIN/<basepath>/
```
Expected: `2096` now bound to `127.0.0.1`; `8443` (VPN inbound) **still listening on `*`** (untouched); direct `:2096` → refused; `panelTLS` → 200/302. Confirm the VPN still connects from a client.

### Task 10: Final external posture check

- [ ] **Step 1: From off-box, confirm only the domain works**

Run (from your laptop, not the VDS):
```bash
for p in 3000 8088 8089 2096; do curl -sS --max-time 6 http://148.253.211.164:$p/ -o /dev/null -w "port $p=%{http_code}\n" || echo "port $p=refused"; done
for s in jarvis freq1 freq2; do curl -sS -o /dev/null -w "$s=%{http_code}\n" https://$s.DOMAIN/ 2>/dev/null; done
```
Expected: 8088/8089/2096 → refused; 3000 → refused or its idle 404 (out of scope, untouched); subdomains respond over TLS (jarvis `/`→401/404 depending on route, freq→200/302).

---

## Phase 6 — Wrap-up

### Task 11: Record the deployment

- [ ] **Step 1: Update project memory**

Add/refresh a memory note (`/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/`) capturing: domain in use, subdomain→port map, cert path + renewal mechanism (certbot DNS-01 wildcard, CF token at `/etc/letsencrypt/cloudflare.ini`), and that raw ports are localhost-bound (access only via subdomains). Add the index line to `MEMORY.md`.

- [ ] **Step 2: Commit any doc touch-ups (configs already committed in Task 1)**

```bash
git add -A && git commit -m "docs: note VDS domain/subdomain deployment" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:** subdomain map → Task 1/5/6; DNS-01 wildcard cert + auto-renew → Task 4; nginx (map, catch-all, WS upgrade, long timeouts, http→https) → Task 1; iOS no-rebuild cutover → Task 7; hardening (freqtrade + x-ui localhost-bind, no ufw) → Tasks 8–9; security boundary (3002/10254 never fronted) → enforced by config (only 4 upstreams) + Task 10; verification → Tasks 6/10; rollback → compose backup (8.2), Tailscale fallback (7.3), SSH-tunnel note (spec). All spec sections mapped.

**Placeholder scan:** `DOMAIN`, `<CF_TOKEN>`, `<basepath>`, `<compose_dir>` are runtime substitutions (documented), not plan gaps. No "TBD"/"add error handling"/"similar to" placeholders.

**Type/name consistency:** subdomain→port mapping identical across template, README, and every verify step (jarvis=3001, freq1=8089/NFIX6, freq2=8088/NFIX7, panel=2096). Container names match the `docker ps` output captured during investigation.
