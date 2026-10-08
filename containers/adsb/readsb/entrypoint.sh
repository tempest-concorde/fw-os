#!/bin/sh
# fw-adsb-readsb entrypoint — feature fw-gsd specs/003-usb-adsb-feeder (T010, T040)
# Runs readsb (JSON out + BEAST/SBS streams) and a python3 http.server that
# exposes the JSON as /data/*.json via a docroot symlink. Device-absent and
# offline-replay (READSB_IFILE) modes keep systemd status clean (FR-017).
#
# Receiver-presence marker contract (T040, contracts/feed-status.md):
# /readsb/receiver-present exists AND has fresh mtime (<60s) exactly while a
# real receiver is decoding. Removed on idle, on test mode, and on shutdown.
set -eu

DEVICE=/dev/radio-adsb/rtl-sdr0
MARKER=/readsb/receiver-present

# readsb args: VERIFIED against help.h at READSB_COMMIT (versions.env) on
# 2026-09-26 — --onlyaddr, --write-json-every, --net-bo-port, --net-sbs-port,
# --ifile all exist at that commit (T045 readsb half).
READSB_ARGS="--write-json /readsb --write-json-every 1 --net --net-bo-port 30005 --net-sbs-port 30003 --onlyaddr"

# Marker is only valid for a live, real-receiver decode session.
rm -f "$MARKER"

# Offline replay path used by CI/tests: READSB_IFILE set => no realtime source.
# Deliberately does NOT write the marker: a replay container is not a receiver.
if [ "${READSB_IFILE:-}" != "" ]; then
    # Offline recorded-replay (CI tier). readsb --ifile demodulates raw IQ
    # samples only — a Beast-format fixture is replayed via readsb's TCP
    # beast INPUT port instead (--device-type none + --net-bi-port; both
    # verified in help.h/sdr.c at READSB_COMMIT). replay-feeder.py paces the
    # frames at 1/s so the --write-json-every 1 tick fires repeatedly.
    python3 -m http.server 8080 --directory /docroot &
    HTTP_PID=$!
    # shellcheck disable=SC2086
    readsb --device-type none $READSB_ARGS --net-bi-port 30004 &
    READSB_PID=$!
    python3 /usr/local/bin/fw-adsb-replay-feeder.py "$READSB_IFILE" 127.0.0.1 30004 &
    FEEDER_PID=$!
    trap 'kill "$READSB_PID" "$HTTP_PID" "$FEEDER_PID" 2>/dev/null || true' EXIT TERM INT
    wait
    exit 0
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
# Fresh-mtime keeper: receiver-present stays within the status probe's 60s
# window while the decoder is alive.
( while :; do touch "$MARKER"; sleep 15; done ) &
MARKER_PID=$!

cleanup() {
    rm -f "$MARKER"
    kill "$READSB_PID" "$HTTP_PID" "$MARKER_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM INT
wait "$READSB_PID"
exit "$?"
