# Recorded BEAST fixture (T007)

`sample.beast` — 124 bytes, 6 Beast frames wrapping fully CRC-valid Mode-S
messages, generated deterministically by `generate_sample_beast.py` in this
directory. Frame MLAT timestamps are spaced 1 s apart (12 MHz ticks) so that
an offline `readsb --ifile ... --throttle` replay spans ~5 s of wall time —
long enough for the 1 s JSON write tick to fire. Replaying it into
`readsb --onlyaddr` (offline) yields an `aircraft.json` containing one
aircraft:

- `hex`: `abc123`
- `flight`: `TEST01`

## Provenance

Not a live capture: synthesized by `generate_sample_beast.py` (DF17 callsign +
DF11 all-call frames, parity computed with the Mode S CRC-24 polynomial
`0xFFF409`, generator self-checks parity symmetry before writing). Synthetic
beats live recording for CI: it is license-free, stable, small, and its decode
expectations are deterministic (no aircraft-in-range variability).

## Regenerating

```bash
python3 tests/fixtures/generate_sample_beast.py
```

## Used by

- `tests/integration/test_recorded_beast.py` (T008) — replay → `aircraft.json`
  contract assertions
- `tests/integration/test_streams.py` (US2) — BEAST/SBS stream assertions
