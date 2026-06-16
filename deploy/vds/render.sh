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
