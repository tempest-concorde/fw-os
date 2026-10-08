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
    python3 -m http.server 8080 --directory /docroot &
    HTTP_PID=$!
    # shellcheck disable=SC2086
    # --throttle (VERIFIED "--throttle" exists at READSB_COMMIT: help.h
    # OptIfileThrottle) replays at capture speed so the JSON write tick fires
    # while the fixture streams in.
    readsb --ifile "$READSB_IFILE" --throttle $READSB_ARGS &
    READSB_PID=$!
    trap 'kill "$READSB_PID" "$HTTP_PID" 2>/dev/null || true' EXIT TERM INT
    wait "$READSB_PID" || true
    # The recorded fixture is short: when replay exhausts it, readsb exits —
    # keep serving the last-written JSON until the container is stopped so
    # the recorded-replay test tier can validate it.
    wait "$HTTP_PID"
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
