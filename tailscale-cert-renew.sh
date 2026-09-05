#!/bin/bash
# Tailscale TLS Certificate Renewal Script
# Fetches Tailscale TLS certificates and updates podman secrets
#
# Robust against first-boot races: waits for tailscaled to be online and for a
# resolvable MagicDNS name before fetching the certificate. Uses the full FQDN
# (e.g. fw.story-beta.ts.net); bare hostnames like "fw" are rejected by
# `tailscale cert`. The tailscale CLI runs as root; podman secrets are imported
# into CORE's rootless store via runuser.

set -euo pipefail

CERT_DIR="/var/home/core/.fw-app/certs"
MAX_WAIT=120          # seconds
INTERVAL=2

run_podman_as_core() {
    runuser -u core -- env XDG_RUNTIME_DIR=/run/user/1000 "$@"
}

# Resolve the MagicDNS FQDN once tailscaled is online. Returns non-zero if no
# valid FQDN could be determined within the timeout.
resolve_fqdn() {
    local fqdn=""
    local waited=0
    while [ "${waited}" -lt "${MAX_WAIT}" ]; do
        if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
            fqdn="${TAILSCALE_HOSTNAME}"
        else
            fqdn="$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    name = d.get('Self', {}).get('DNSName', '')
    print(name.rstrip('.'))
except Exception:
    print('')
" 2>/dev/null || true)"
        fi
        # Must be a fully-qualified MagicDNS name (contains a dot) — bare
        # hostnames ("fw") are not valid for `tailscale cert`.
        if [ -n "${fqdn}" ] && [[ "${fqdn}" == *"."* ]] && ! [[ "${fqdn}" == *" "* ]]; then
            echo "${fqdn}"
            return 0
        fi
        waited=$((waited + INTERVAL))
        sleep "${INTERVAL}"
    done
    echo "ERROR: could not resolve a valid Tailscale MagicDNS FQDN after ${MAX_WAIT}s" >&2
    tailscale status 2>&1 | head -5 >&2 || true
    return 1
}

HOSTNAME="$(resolve_fqdn)"
echo "  FQDN=${HOSTNAME}"

# Ensure cert directory exists
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# Fetch certificate from Tailscale (root has socket access)
echo "📜 Fetching Tailscale certificate for ${HOSTNAME}..."
tailscale cert "${HOSTNAME}"

# Verify files exist
if [ ! -f "${HOSTNAME}.crt" ] || [ ! -f "${HOSTNAME}.key" ]; then
    echo "❌ Certificate files not found after fetch"
    exit 1
fi
chown core:core "${HOSTNAME}.crt" "${HOSTNAME}.key"

echo "✅ Certificate fetched successfully"

# Import into core's rootless podman secret store
echo "🔐 Updating podman secrets (as core)..."

run_podman_as_core podman secret rm tailscale-cert 2>/dev/null || true
run_podman_as_core podman secret rm tailscale-key 2>/dev/null || true

run_podman_as_core podman secret create tailscale-cert - < "${HOSTNAME}.crt"
run_podman_as_core podman secret create tailscale-key - < "${HOSTNAME}.key"

echo "✅ Podman secrets updated"

# Regenerate the quadlet drop-in (as core)
run_podman_as_core /usr/libexec/fw-os/sync-fw-secrets.sh
echo "✅ Quadlet drop-in regenerated"

echo "✅ Certificate renewal complete"