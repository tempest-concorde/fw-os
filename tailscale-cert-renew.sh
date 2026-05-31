#!/bin/bash
# Tailscale TLS Certificate Renewal Script
# Fetches Tailscale TLS certificates and updates podman secrets

set -euo pipefail

CERT_DIR="/var/home/core/.fw-app/certs"
HOSTNAME="${TAILSCALE_HOSTNAME:-flightwall}"

# Ensure cert directory exists
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# Fetch certificate from Tailscale
echo "📜 Fetching Tailscale certificate for ${HOSTNAME}..."
tailscale cert "${HOSTNAME}"

# Verify files exist
if [ ! -f "${HOSTNAME}.crt" ] || [ ! -f "${HOSTNAME}.key" ]; then
    echo "❌ Certificate files not found after fetch"
    exit 1
fi

echo "✅ Certificate fetched successfully"

# Update podman secrets (rootless, running as core user)
export XDG_RUNTIME_DIR="/run/user/1000"

echo "🔐 Updating podman secrets..."

# Remove old secrets if they exist
podman secret rm tailscale-cert 2>/dev/null || true
podman secret rm tailscale-key 2>/dev/null || true

# Create new secrets
cat "${HOSTNAME}.crt" | podman secret create tailscale-cert -
cat "${HOSTNAME}.key" | podman secret create tailscale-key -

echo "✅ Podman secrets updated"

# Trigger fw-app restart to pick up new certificates
if systemctl --user is-active --quiet fw-app.service; then
    echo "🔄 Restarting fw-app service..."
    systemctl --user restart fw-app.service
    echo "✅ Service restarted"
else
    echo "ℹ️  fw-app service not running, skipping restart"
fi

echo "✅ Certificate renewal complete"
