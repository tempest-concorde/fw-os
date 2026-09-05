#!/bin/bash
# Wait for the system-level fw-app-secrets.service to finish provisioning.
# Used as the quadlet fw-app ExecStartPre so the container only starts after
# TLS certs + podman secrets + FQDN meta are ready.
#
# NOTE: this runs inside the USER systemd manager (quadlet ExecStartPre), so
# we must query the SYSTEM manager explicitly with --system.

set -euo pipefail

TIMEOUT=180   # seconds
INTERVAL=2

for i in $(seq 1 $((TIMEOUT / INTERVAL))); do
    if systemctl --system is-active --quiet fw-app-secrets.service 2>/dev/null; then
        echo "fw-app-secrets.service is active"
        exit 0
    fi
    if systemctl --system is-failed --quiet fw-app-secrets.service 2>/dev/null; then
        echo "ERROR: fw-app-secrets.service failed" >&2
        journalctl -u fw-app-secrets.service -n 30 --no-pager >&2 || true
        exit 1
    fi
    sleep "${INTERVAL}"
done

echo "ERROR: timed out waiting for fw-app-secrets.service" >&2
journalctl -u fw-app-secrets.service -n 30 --no-pager >&2 || true
exit 1