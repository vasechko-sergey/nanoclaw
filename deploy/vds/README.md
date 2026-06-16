# VDS nginx + TLS

Reverse-proxy config fronting the VDS services on per-subdomain HTTPS.
Spec: ../../docs/superpowers/specs/2026-06-16-vds-subdomains-nginx-tls-design.md
Plan: ../../docs/superpowers/plans/2026-06-16-vds-subdomains-nginx-tls.md

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
The rendered file (`rendered/`) contains the real domain and is git-ignored.
