#!/bin/bash
# Flight Wall App Secret Provisioning (first-boot ordering)
#
# Runs as a system-level oneshot (User=core) BEFORE the fw-app quadlet starts.
# Ensures, in order:
#   1. Tailscale TLS certificate is fetched for the device FQDN
#   2. Podman secrets (tailscale-cert, tailscale-key) exist so the quadlet
#      drop-in can inject them
#   3. The device FQDN is written to /var/home/core/.fw-app/meta/fqdn so the
#      in-container `fw-app healthcheck` can verify against it
#   4. sync-fw-secrets.sh regenerates the quadlet drop-in
#
# The TLS cert + FQDN are boot-critical (fw-app cannot serve TLS without
# them), so their absence fails the unit. OAuth/OpenSky/JWT secrets are
# operator-provisioned and their absence is logged but does NOT fail the unit
# (fw-app will report them via its own healthcheck).
#
# Idempotent — safe to run on every boot and after cert renewal.

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"

META_DIR="/var/home/core/.fw-app/meta"
FQDN_FILE="${META_DIR}/fqdn"

# The cert-renew script resolves the FQDN robustly (waits for tailscaled to be
# online + MagicDNS ready). Reuse it to get the FQDN; it also fetches the cert
# and updates the podman TLS secrets.
/usr/local/bin/tailscale-cert-renew.sh
echo "✅ TLS cert + podman secrets ensured"

# Persist the FQDN (resolved by tailscale-cert-renew.sh) for the in-container
# healthcheck. Derive it the same way the renewal script does.
FQDN="$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"
if [ -z "${FQDN}" ] || ! [[ "${FQDN}" == *"."* ]]; then
    echo "⚠️  Could not re-derive FQDN from tailscale status; skipping meta write"
else
    mkdir -p "${META_DIR}"
    printf '%s' "${FQDN}" > "${FQDN_FILE}"
    chmod 0644 "${FQDN_FILE}"
    echo "✅ Wrote ${FQDN_FILE}"
fi

# Regenerate the quadlet drop-in from the current secret store
/usr/libexec/fw-os/sync-fw-secrets.sh
echo "✅ Quadlet drop-in regenerated"

# TLS cert/key are boot-critical — fail if they are missing.
AVAILABLE=$(podman secret ls --format '{{.Name}}' 2>/dev/null || echo "")

for name in tailscale-cert tailscale-key; do
    if ! echo "${AVAILABLE}" | grep -qx "${name}"; then
        echo "❌ Missing boot-critical podman secret: ${name}" >&2
        exit 1
    fi
done
echo "✅ TLS cert + key secrets present"

# Operator-provisioned app secrets: warn (not fail) if absent.
for name in github-oauth-client-id github-oauth-client-secret jwt-secret opensky-client-id opensky-client-secret aeroapi-key; do
    if ! echo "${AVAILABLE}" | grep -qx "${name}"; then
        echo "ℹ️  App secret not provisioned: ${name} (fw-app will report this)"
    fi
done

exit 0