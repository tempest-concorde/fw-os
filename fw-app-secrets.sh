#!/bin/bash
# Flight Wall App Secret Provisioning (first-boot ordering)
#
# Runs as a system-level oneshot (User=core) BEFORE the fw-app quadlet starts.
# Ensures, in order:
#   1. Tailscale TLS certificate is fetched for the device FQDN
#   2. Podman secrets (tailscale-cert, tailscale-key, github-oauth-*, jwt)
#      exist so the quadlet drop-in can inject them as env vars
#   3. The device FQDN is written to /var/home/core/.fw-app/meta/fqdn so the
#      in-container `fw-app healthcheck` can verify against it
#   4. sync-fw-secrets.sh regenerates the quadlet drop-in
#
# Idempotent — safe to run on every boot and after cert renewal.

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"

META_DIR="/var/home/core/.fw-app/meta"
FQDN_FILE="${META_DIR}/fqdn"

echo "🔍 Resolving Tailscale DNS name..."
FQDN="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"

if [ -z "${FQDN}" ]; then
    echo "ℹ️  Tailscale not ready or no DNS name yet; using 'fw'"
    FQDN="fw"
fi
echo "  FQDN=${FQDN}"

# Persist FQDN for the in-container healthcheck
mkdir -p "${META_DIR}"
printf '%s' "${FQDN}" > "${FQDN_FILE}"
chmod 0644 "${FQDN_FILE}"
echo "✅ Wrote ${FQDN_FILE}"

# Ensure TLS cert + podman secrets for the app
/usr/local/bin/tailscale-cert-renew.sh
echo "✅ TLS cert + podman secrets ensured"

# Regenerate the quadlet drop-in from the current secret store
/usr/libexec/fw-os/sync-fw-secrets.sh
echo "✅ Quadlet drop-in regenerated"

# Gate on required secrets being present (app cannot start without them)
REQUIRED=(
    "tailscale-cert"
    "tailscale-key"
    "github-oauth-client-id"
    "github-oauth-client-secret"
)

AVAILABLE=$(podman secret ls --format '{{.Name}}' 2>/dev/null || echo "")

MISSING=()
for name in "${REQUIRED[@]}"; do
    if ! echo "${AVAILABLE}" | grep -qx "${name}"; then
        MISSING+=("${name}")
    fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "❌ Missing required podman secrets: ${MISSING[*]}"
    echo "   Provision them with e.g.:"
    echo "   echo '<value>' | podman secret create <name> -"
    exit 1
fi

echo "✅ All required podman secrets present"
exit 0