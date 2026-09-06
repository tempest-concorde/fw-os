#!/bin/bash
# Tailscale TLS Certificate Renewal Script
# Fetches Tailscale TLS certificates and updates podman secrets
#
# Uses the deployment-time FW_SERVER_FQDN from /etc/fw-os/fw-app.env. The
# tailscale CLI runs as root; podman secrets are imported into CORE's rootless
# store via runuser.

set -euo pipefail

CERT_DIR="/var/home/core/.fw-app/certs"

run_podman_as_core() {
    runuser -u core -- env XDG_RUNTIME_DIR=/run/user/1000 "$@"
}

HOSTNAME="${FW_SERVER_FQDN:?FW_SERVER_FQDN must be set in /etc/fw-os/fw-app.env}"
if ! [[ "${HOSTNAME}" == *"."* ]] || [[ "${HOSTNAME}" == *" "* ]]; then
    echo "ERROR: FW_SERVER_FQDN must be a fully-qualified DNS name: ${HOSTNAME}" >&2
    exit 1
fi
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
