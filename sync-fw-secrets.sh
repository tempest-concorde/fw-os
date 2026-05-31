#!/bin/bash
# Flight Wall Secret Synchronization Script
# Modeled on tank-os sync-podman-secrets pattern
# Probes podman secret store and generates quadlet drop-ins

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"
DROPINS_DIR="/var/home/core/.config/containers/systemd/fw-app.container.d"
DROPIN_FILE="${DROPINS_DIR}/10-secrets.conf"

# Known secret names and their environment variable targets
declare -A SECRETS=(
    ["github-oauth-client-id"]="GITHUB_OAUTH_CLIENT_ID"
    ["github-oauth-client-secret"]="GITHUB_OAUTH_CLIENT_SECRET"
    ["opensky-client-id"]="OPENSKY_CLIENT_ID"
    ["opensky-client-secret"]="OPENSKY_CLIENT_SECRET"
    ["aeroapi-key"]="AEROAPI_KEY"
    ["tailscale-cert"]="TAILSCALE_CERT_FILE"
    ["tailscale-key"]="TAILSCALE_KEY_FILE"
)

echo "🔍 Probing podman secret store..."

# Get list of available secrets
AVAILABLE_SECRETS=$(podman secret ls --format '{{.Name}}' 2>/dev/null || echo "")

if [ -z "${AVAILABLE_SECRETS}" ]; then
    echo "ℹ️  No secrets found in podman secret store"
    exit 0
fi

# Build drop-in content
DROPIN_CONTENT="[Container]"$'\n'
SECRET_COUNT=0

for secret_name in "${!SECRETS[@]}"; do
    env_var="${SECRETS[$secret_name]}"

    if echo "${AVAILABLE_SECRETS}" | grep -q "^${secret_name}$"; then
        DROPIN_CONTENT+="Secret=${secret_name},type=env,target=${env_var}"$'\n'
        echo "  ✓ ${secret_name} → ${env_var}"
        ((SECRET_COUNT++))
    fi
done

if [ ${SECRET_COUNT} -eq 0 ]; then
    echo "ℹ️  No known secrets found"
    exit 0
fi

# Create drop-in directory
mkdir -p "${DROPINS_DIR}"

# Write drop-in file
echo "${DROPIN_CONTENT}" > "${DROPIN_FILE}"
chmod 644 "${DROPIN_FILE}"

echo "✅ Generated ${DROPIN_FILE} with ${SECRET_COUNT} secrets"

# Reload systemd user daemon
if command -v systemctl &> /dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
    echo "✅ Systemd user daemon reloaded"
fi

exit 0
