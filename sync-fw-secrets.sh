#!/bin/bash
# Flight Wall Secret Synchronization Script
# Modeled on tank-os sync-podman-secrets pattern
# Probes podman secret store and generates quadlet drop-ins
#
# TLS cert/key secrets are mounted as FILES at the app's expected paths
# (/run/secrets/tls.crt, /run/secrets/tls.key) because the app loads them via
# tls.LoadX509KeyPair. All other secrets are injected as environment variables.

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"
DROPINS_DIR="/var/home/core/.config/containers/systemd/fw-app.container.d"
DROPIN_FILE="${DROPINS_DIR}/10-secrets.conf"

# Environment secrets: secret name -> env var target
declare -A ENV_SECRETS=(
    ["github-oauth-client-id"]="GITHUB_OAUTH_CLIENT_ID"
    ["github-oauth-client-secret"]="GITHUB_OAUTH_CLIENT_SECRET"
    ["opensky-client-id"]="OPENSKY_CLIENT_ID"
    ["opensky-client-secret"]="OPENSKY_CLIENT_SECRET"
    ["aeroapi-key"]="AEROAPI_KEY"
    ["jwt-secret"]="FW_AUTH_JWT_SECRET"
)

# File-mount secrets: secret name -> target path inside the container
declare -A FILE_SECRETS=(
    ["tailscale-cert"]="/run/secrets/tls.crt"
    ["tailscale-key"]="/run/secrets/tls.key"
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

for secret_name in "${!ENV_SECRETS[@]}"; do
    env_var="${ENV_SECRETS[$secret_name]}"
    if echo "${AVAILABLE_SECRETS}" | grep -q "^${secret_name}$"; then
        DROPIN_CONTENT+="Secret=${secret_name},type=env,target=${env_var}"$'\n'
        echo "  ✓ ${secret_name} → env ${env_var}"
        SECRET_COUNT=$((SECRET_COUNT + 1))
    fi
done

for secret_name in "${!FILE_SECRETS[@]}"; do
    target="${FILE_SECRETS[$secret_name]}"
    if echo "${AVAILABLE_SECRETS}" | grep -q "^${secret_name}$"; then
        DROPIN_CONTENT+="Secret=${secret_name},type=mount,target=${target},mode=0444"$'\n'
        echo "  ✓ ${secret_name} → file ${target}"
        SECRET_COUNT=$((SECRET_COUNT + 1))
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