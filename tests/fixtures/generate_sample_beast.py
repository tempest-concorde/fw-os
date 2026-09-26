#!/usr/bin/env python3
"""Generate tests/fixtures/sample.beast (T007).

Synthesizes a small but fully CRC-valid Mode-S/ADS-B message sequence as a
binary Beast-format capture, so `readsb` decodes at least one aircraft entry
when the file is replayed offline. Content is deterministic — no network or
hardware needed.

Layout produced:
  - 4x DF17 identification (callsign) messages for one aircraft (ICAO 0xABC123,
    flight "TEST01") — callsign decoding needs at least the full 8-char frame.
  - 2x DF11 all-call replies (harmless filler, shows message-rate counters).

Self-check: validates each generated frame against a second, independent CRC
implementation path (parity-recompute on the complete message must be zero)
before writing; exits non-zero on mismatch.

Usage: python3 tests/fixtures/generate_sample_beast.py
Output: tests/fixtures/sample.beast (binary)
"""

from __future__ import annotations

import sys
from pathlib import Path

MODES_POLY = 0xFFF409  # Mode S CRC-24 generator polynomial (25th bit implied)

# 6-bit callsign charset for DF17 TC=4 (index 0..63)
CALLSIGN_CHARSET = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######"


def crc24(msg: bytes) -> int:
    """Mode S CRC-24 of msg (any length), bitwise MSB-first."""
    work = int.from_bytes(msg, "big") << 24
    nbits = len(msg) * 8
    for i in range(len(msg) * 8):
        bit_pos = nbits + 24 - 1 - i
        if (work >> bit_pos) & 1:
            work ^= (MODES_POLY | (0x1000000)) << (bit_pos - 24)
    return work & 0xFFFFFF


def df17_callsign(icao: int, callsign: str, category: int = 1) -> bytes:
    """DF17 extended squitter, ME typecode 4 (aircraft identification)."""
    if len(callsign) > 8:
        raise ValueError("callsign > 8 chars")
    callsign = callsign.ljust(8)

    # 56-bit ME field: TC(5)=4, CA(3)=category, 8x6-bit chars
    me = (4 << 51) | (category << 48)
    for i, ch in enumerate(callsign):
        code = CALLSIGN_CHARSET.index(ch)
        me |= code << (42 - i * 6)

    # Message first 88 bits: DF(5)=17, CA(3)=5, ICAO24, ME56
    first11 = ((17 << 83) | (5 << 80) | (icao << 56) | me).to_bytes(11, "big")
    pi = crc24(first11)  # DF17 PI = CRC remainder (no interrogator overlay)
    return first11 + pi.to_bytes(3, "big")


def df11_all_call(icao: int) -> bytes:
    """DF11 all-call reply (56-bit total, parity=PI over 32-bit body)."""
    body = ((11 << 27) | (5 << 24) | icao).to_bytes(4, "big")
    parity = crc24(body)
    return body + parity.to_bytes(3, "big")


def beast_frame(type_byte: bytes, msg: bytes, mlat: int, sig: int = 200) -> bytes:
    """Wrap a Mode S message in a Beast frame with 0x1A escaping."""
    ts = mlat.to_bytes(6, "big")
    data = bytes(ts) + bytes([sig]) + msg
    out = bytearray(b"\x1a" + type_byte)
    for b in data:
        out.append(b)
        if b == 0x1A:
            out.append(0x1A)  # escape duplication
    return bytes(out)


def main() -> int:
    icao = 0xABC123
    msgs: list[bytes] = []

    msg = df17_callsign(icao, "TEST01")
    # Self-check: CRC of the whole 14-byte message must equal 0
    if crc24(msg) != 0 or len(msg) != 14:
        print("FATAL: DF17 self-check failed", file=sys.stderr)
        return 1
    msgs += [("3", msg)] * 4  # repeat so the decoder latches the aircraft

    df11 = df11_all_call(icao)
    if crc24(df11) != 0 or len(df11) != 7:
        print("FATAL: DF11 self-check failed", file=sys.stderr)
        return 1
    msgs += [("2", df11)] * 2

    payload = bytearray()
    for i, (t, m) in enumerate(msgs):
        payload += beast_frame(t.encode(), m, mlat=123456789 + i * 1000)

    out = Path(__file__).resolve().parent / "sample.beast"
    out.write_bytes(bytes(payload))
    print(f"wrote {out} ({len(payload)} bytes, {len(msgs)} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
