# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-03: implement only one hidden video decode-unit bridge behind N2-02's media
  port. Validate bounded `DECODE_UNIT`/`LENTRY` chains, preserve buffer type,
  frame/decode metadata and codec config, and return stable IDR/backpressure truth.
  No NAPI, ArkTS/UI/cloud/audio/input or renderer wiring; decoded/submitted is not
  first-frame, streaming, protocol available or release-ready.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N2-04 generation-fenced OH_AVCodec integration only after N2-03 proves payload
  ownership, malformed-chain rejection and teardown isolation; it must reuse the
  existing decoder/surface owner and keep old-protocol regression tests.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, full regression, mandatory Hvigor/Light
  gates, PR and release rollout. Both allowed `sol low` reviews are consumed.
