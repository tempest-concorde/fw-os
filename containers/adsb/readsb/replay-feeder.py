#!/usr/bin/env python3
"""Offline BEAST replay feeder (fw-gsd specs/003-usb-adsb-feeder).

readsb's --ifile input path demodulates raw IQ samples, so a Beast-format
fixture cannot be replayed through it. Replay instead streams the beast
frames into readsb's TCP beast INPUT (--net-bi-port) via --device-type none,
paced 1 frame/second so readsb's --write-json-every 1 tick fires repeatedly
before the fixture is exhausted.

Used only when READSB_IFILE is set (CI recorded-replay tier); never in the
live-receiver path.
"""

import socket
import sys
import time


def frames(data: bytes):
    """Yield raw Beast frames (0x1A escape-aware) from a capture blob."""
    assert data[0:1] == b"\x1a", "fixture must start with a frame marker"
    i = 0
    while i < len(data):
        assert data[i] == 0x1A
        j = data.find(b"\x1a", i + 1)
        if j == -1:
            yield data[i:]
            return
        yield data[i:j]
        i = j


def main() -> int:
    fixture, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    frames_list = list(frames(open(fixture, "rb").read()))
    if not frames_list:
        return 1

    # readsb needs a moment to bind its input port after startup.
    for attempt in range(60):
        try:
            sock = socket.create_connection((host, port), timeout=2)
            break
        except OSError:
            time.sleep(1)
    else:
        print("replay-feeder: never connected to readsb beast input", file=sys.stderr)
        return 1

    with sock:
        for _ in range(4):  # cycle the fixture a few times, then keep serving
            for frame in frames_list:
                sock.sendall(frame)
                time.sleep(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
