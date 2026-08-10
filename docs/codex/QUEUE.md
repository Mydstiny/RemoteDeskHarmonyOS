# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-06 only: add one hidden pure-native `MoonlightAudioBridge` and deterministic
  tests. Consume N2-02's validated audio selection/borrowed payload, but do not
  wire common-c product media port, OHAudio, NAPI, ArkTS, UI, cloud or input.
- Reuse the repository's single libopus 1.5.2 artifact. Do not copy RustDesk's
  worker, link another Opus, or create another audio/session owner. MVP accepts
  only exact 48 kHz stereo family-1 multistream; surround/downmix is typed
  unsupported until a later evidenced contract.
- Freeze exact key/config/generation admission, bounded packet/PCM ownership,
  PLC semantics, S16LE conversion, blocked-decode drain, idempotent stop/cleanup
  and zeroization. Audio ready/accepted PCM never becomes video first-frame.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables until HAP/AppSpawn runtime and later S1 wiring exist.

## Next

- N2-07: connect N2-06 PCM to the existing exact-owner `audio_player` registry and
  bounded queue; do not create a Moonlight-specific OHAudio owner.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- D2-07/D3 cloud wiring only after AGC dev/test/prod schema/auth/index receipts.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle only after their
  data/Host Control/media prerequisites are truthful.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 physical
  acceptance. Both allowed `sol low` reviewer slots are consumed; do not redispatch.
