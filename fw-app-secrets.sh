#!/bin/bash
# Flight Wall App Secret Provisioning (first-boot ordering)
#
# System-level oneshot that prepares everything fw-app needs before its
# quadlet unit starts:
#   1. Read the deployment-time Tailscale FQDN.
#   2. Fetch the Tailscale TLS certificate (as root — the tailscale CLI needs
#      root or the tailscale group).
#   3. Import the TLS cert/key into CORE's rootless podman secret store (the
#      fw-app quadlet runs as core and must be able to read them).
#   4. Regenerate the quadlet drop-in from the current secret store (as core).
#
# The TLS cert + FQDN are boot-critical (fw-app cannot serve TLS without
# them), so their absence fails the unit. OAuth/OpenSky/JWT secrets are
# operator-provisioned and their absence is logged but does NOT fail the unit.
#
# Idempotent — safe to run on every boot and after cert renewal.

set -euo pipefail

CERT_DIR="/var/home/core/.fw-app/certs"

# run_podman_as_core runs a podman command as the core user with the correct
# runtime dir, so rootless secrets land in core's store (not root's).
run_podman_as_core() {
    runuser -u core -- env XDG_RUNTIME_DIR=/run/user/1000 "$@"
}

FQDN="${FW_SERVER_FQDN:?FW_SERVER_FQDN must be set in /etc/fw-os/fw-app.env}"
if ! [[ "${FQDN}" == *"."* ]] || [[ "${FQDN}" == *" "* ]]; then
    echo "❌ FW_SERVER_FQDN must be a fully-qualified DNS name: ${FQDN}" >&2
    exit 1
fi
echo "  FQDN=${FQDN}"

# Fetch TLS certificate (root has tailscaled socket access)
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"
echo "📜 Fetching Tailscale certificate for ${FQDN}..."
tailscale cert "${FQDN}"

if [ ! -f "${FQDN}.crt" ] || [ ! -f "${FQDN}.key" ]; then
    echo "❌ Certificate files not found after fetch" >&2
    exit 1
fi
chown core:core "${FQDN}.crt" "${FQDN}.key"
echo "✅ Certificate fetched"

# Import TLS cert/key into core's rootless podman secret store
echo "🔐 Updating podman secrets (as core)..."
run_podman_as_core podman secret rm tailscale-cert 2>/dev/null || true
run_podman_as_core podman secret rm tailscale-key 2>/dev/null || true
run_podman_as_core podman secret create tailscale-cert - < "${FQDN}.crt"
run_podman_as_core podman secret create tailscale-key - < "${FQDN}.key"
echo "✅ TLS secrets imported"

# Regenerate the quadlet drop-in from the current secret store (as core)
run_podman_as_core /usr/libexec/fw-os/sync-fw-secrets.sh
echo "✅ Quadlet drop-in regenerated"

# TLS cert/key are boot-critical — fail if they are missing from core's store.
AVAILABLE="$(run_podman_as_core podman secret ls --format '{{.Name}}' 2>/dev/null || echo '')"
for name in tailscale-cert tailscale-key; do
    if ! echo "${AVAILABLE}" | grep -qx "${name}"; then
        echo "❌ Missing boot-critical podman secret: ${name}" >&2
        exit 1
    fi
done
echo "✅ TLS cert + key secrets present in core's store"

# Operator-provisioned app secrets: warn (not fail) if absent. These are named
# after the env vars fw-app reads (FW_*), so there's no rename mapping.
for name in FW_AUTH_GITHUB_CLIENT_ID FW_AUTH_GITHUB_CLIENT_SECRET FW_AUTH_JWT_SECRET FW_OPENSKY_CLIENT_ID FW_OPENSKY_CLIENT_SECRET FW_AEROAPI_KEY; do
    if ! echo "${AVAILABLE}" | grep -qx "${name}"; then
        echo "ℹ️  App secret not provisioned: ${name} (fw-app will report this)"
    fi
done

exit 0
