#!/bin/sh
# fw-adsb-fr24feed entrypoint — feature fw-gsd specs/003-usb-adsb-feeder (T011)
# Config arrives via the quadlet EnvironmentFile (/etc/fw-os/fw-adsb.env).
# Degraded states (push disabled, credentials missing, invalid position) idle
# with exit-0 semantics instead of crash-looping (spec FR-014, FR-017).
set -eu

TMPL=/usr/local/share/fw-adsb/fr24feed.ini.tmpl
CONF=/tmp/fr24feed.ini

FW_FR24_ENABLED=${FW_FR24_ENABLED:-false}
FW_FR24_SHARING_KEY_FILE=${FW_FR24_SHARING_KEY_FILE:-/run/secrets/fr24-sharing-key}
FW_FR24_STATION_NAME=${FW_FR24_STATION_NAME:-$(hostname)}
FW_FR24_LAT=${FW_FR24_LAT:-}
FW_FR24_LON=${FW_FR24_LON:-}
FW_FR24_ELEV=${FW_FR24_ELEV:-}
FW_FR24_MLAT=${FW_FR24_MLAT:-false}

# Credential/runtime state marker (T048, FR-017): the fw-adsb-status service
# reads this file (shared fw-adsb-readsb-data volume) to distinguish
# credentials_missing / disabled without inferring from env alone.
STATE_DIR=${FW_ADSB_STATE_DIR:-/readsb}
STATE_FILE=$STATE_DIR/fr24-state

write_state() {
    # Atomic single-line write; guard absence of the dir (e.g. volume unset in
    # unit tests) so logging never breaks execution.
    [ -d "$STATE_DIR" ] || return 0
    echo "$1" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

idle() {
    exec tail -f /dev/null
}

if [ "$FW_FR24_ENABLED" != "true" ]; then
    echo "push disabled (FW_FR24_ENABLED!=true); idling"
    write_state disabled
    idle
fi

if [ ! -s "$FW_FR24_SHARING_KEY_FILE" ]; then
    echo "credentials_missing: $FW_FR24_SHARING_KEY_FILE absent or empty; idling"
    write_state credentials_missing
    idle
fi

SHARING_KEY=$(cat "$FW_FR24_SHARING_KEY_FILE")

# Position validation (spec FR-012): only when set; invalid => log + idle.
if { [ -n "$FW_FR24_LAT" ] || [ -n "$FW_FR24_LON" ]; } \
  && ! { [ -n "$FW_FR24_LAT" ] && [ -n "$FW_FR24_LON" ]; }; then
    echo "invalid position: FW_FR24_LAT and FW_FR24_LON must be set together; idling"
    write_state invalid_position
    idle
fi
if [ -n "$FW_FR24_LAT" ] \
  && ! echo "$FW_FR24_LAT" | awk '{ v=$1+0; if (v<0) v=-v; exit !(v<=90) }'; then
    echo "invalid position: |FW_FR24_LAT| must be <= 90; idling"
    write_state invalid_position
    idle
fi
if [ -n "$FW_FR24_LON" ] \
  && ! echo "$FW_FR24_LON" | awk '{ v=$1+0; if (v<0) v=-v; exit !(v<=180) }'; then
    echo "invalid position: |FW_FR24_LON| must be <= 180; idling"
    write_state invalid_position
    idle
fi

# MLAT opt-in, forced OFF unless enabled AND full position present (FR-012).
if [ "$FW_FR24_MLAT" = "true" ] \
  && [ -n "$FW_FR24_LAT" ] && [ -n "$FW_FR24_LON" ] && [ -n "$FW_FR24_ELEV" ]; then
    MLAT_BLOCK='mlat="yes"
mlat-without-gps="no"'
else
    MLAT_BLOCK='mlat="no"
mlat-without-gps="yes"'
fi

# Render the INI into tmpfs only (secret never touches image layers or a
# bind-mounted path). sed used instead of envsubst (not guaranteed present).
# Escape sed replacement metacharacters; fields are operator-controlled so
# this is belt-and-braces.
esc() { printf '%s' "$1" | sed 's|[\&|]|\\&|g'; }

umask 077
sed \
    -e "s|\${SHARING_KEY}|$(esc "$SHARING_KEY")|g" \
    -e "s|\${STATION_NAME}|$(esc "$FW_FR24_STATION_NAME")|g" \
    -e "s|\${LAT}|$(esc "$FW_FR24_LAT")|g" \
    -e "s|\${LON}|$(esc "$FW_FR24_LON")|g" \
    -e "s|\${ELEV}|$(esc "$FW_FR24_ELEV")|g" \
    -e "s|\${MLAT_BLOCK}|$(printf '%s' "$MLAT_BLOCK" | sed 's|[\&|]|\\&|g' | sed ':a;N;$!ba;s/\n/\\\n/g')|g" \
    "$TMPL" > "$CONF"

write_state active

# --config-file=<path>: VERIFIED 2026-09-26 via GitHub code search across
# multiple independent fr24feed deployments (docker-ads-b, balena-ads-b,
# nixos packaging) — equals form used consistently (T045 fr24 half).
exec fr24feed --config-file="$CONF"
