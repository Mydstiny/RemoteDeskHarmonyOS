# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-05 only: add one pure-native exact-generation Surface lifecycle around the
  dormant N2-04 sink/port. Do not wire ArkTS, PIP service, background task, NAPI,
  cloud, audio, input or a product caller.
- Without a Surface, keep transport alive but drop video before copy/queue with
  zero AU retention and one coalesced IDR request. Temporary suspend drains and
  exact-detaches while preserving the decoder registry handle.
- Rebind only the same key/decoder/display to a strictly newer renderer and
  runtime-proof generation; clear first-frame and wait for a new IDR. Cover
  page→PIP→page, background without PIP, resize/rotation/fold and 20 cycles.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables until HAP/AppSpawn runtime and later S1 wiring exist.

## Next

- N2-06/N2-07: Opus bridge then existing audio owner; audio ready never substitutes
  for video first-frame.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- D2-07/D3 cloud wiring only after AGC dev/test/prod schema/auth/index receipts.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle only after their
  data/Host Control/media prerequisites are truthful.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 physical
  acceptance. Both allowed `sol low` reviewer slots are consumed; do not redispatch.
