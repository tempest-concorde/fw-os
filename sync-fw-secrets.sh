#!/bin/bash
# Flight Wall Secret Synchronization Script
# Probes the podman secret store and generates quadlet drop-ins.
#
# Design:
#   - Any secret named FW_* is injected as an environment variable with the
#     SAME name (target = secret name). The podman secret name IS the env var
#     name fw-app reads, so there is no rename mapping. Provision secrets
#     directly with the names fw-app expects (e.g. FW_AUTH_GITHUB_CLIENT_ID).
#   - TLS cert/key are mounted as FILES at the app's expected paths
#     (/run/secrets/tls.crt, /run/secrets/tls.key) because the app loads them
#     via tls.LoadX509KeyPair(path). File mounts are the correct model for PEM
#     material (not env vars).

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"
DROPINS_DIR="/var/home/core/.config/containers/systemd/fw-app.container.d"
DROPIN_FILE="${DROPINS_DIR}/10-secrets.conf"

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

# Inject every FW_* secret as an env var with the same name.
while IFS= read -r secret_name; do
    [ -z "${secret_name}" ] && continue
    case "${secret_name}" in
        FW_*)
            DROPIN_CONTENT+="Secret=${secret_name},type=env,target=${secret_name}"$'\n'
            echo "  ✓ ${secret_name} → env ${secret_name}"
            SECRET_COUNT=$((SECRET_COUNT + 1))
            ;;
    esac
done <<< "${AVAILABLE_SECRETS}"

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