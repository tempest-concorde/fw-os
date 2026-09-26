#!/bin/sh
# fw-adsb-readsb entrypoint — feature fw-gsd specs/003-usb-adsb-feeder (T010)
# Runs readsb (JSON out + BEAST/SBS streams) and a python3 http.server that
# exposes the JSON as /data/*.json via a docroot symlink. Device-absent and
# offline-replay (READSB_IFILE) modes keep systemd status clean (FR-017).
set -eu

DEVICE=/dev/radio-adsb/rtl-sdr0

# VERIFY-on-first-build: flag spellings were authored offline; confirm
# --onlyaddr / --write-json-every against `readsb --help` at READSB_COMMIT
# (versions.env) during the first container build. Do not add flags without
# re-checking that commit's usage().
READSB_ARGS="--write-json /readsb --write-json-every 1 --net --net-bo-port 30005 --net-sbs-port 30003 --onlyaddr"

# Offline replay path used by CI/tests: READSB_IFILE set => no realtime source.
if [ "${READSB_IFILE:-}" != "" ]; then
    python3 -m http.server 8080 --directory /docroot &
    HTTP_PID=$!
    # shellcheck disable=SC2086
    readsb --ifile "$READSB_IFILE" $READSB_ARGS &
    READSB_PID=$!
    trap 'kill "$READSB_PID" "$HTTP_PID" 2>/dev/null || true' EXIT TERM INT
    wait "$READSB_PID"
    exit "$?"
fi

# No receiver attached: idle cleanly (exit 0 on stop) instead of crash-looping,
# so systemd keeps Restart=always quiet and status distinguishes no_receiver
# (FR-017). Hot-plug recovery is handled by fw-adsb-readsb-restart.path.
if [ ! -c "$DEVICE" ]; then
    echo "no-receiver: $DEVICE absent; idling"
    exec tail -f /dev/null
fi

python3 -m http.server 8080 --directory /docroot &
HTTP_PID=$!
# shellcheck disable=SC2086
readsb $READSB_ARGS &
READSB_PID=$!

trap 'kill "$READSB_PID" "$HTTP_PID" 2>/dev/null || true' EXIT TERM INT
wait "$READSB_PID"
exit "$?"
