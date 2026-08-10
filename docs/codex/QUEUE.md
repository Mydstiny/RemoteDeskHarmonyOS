# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-06 checkpoint `8d2fd15b3`: hidden pure-native Opus→S16LE bridge, common-c
  null+0 PLC seam, exact stereo admission, bounded ownership, generation fence,
  drain/cleanup/zeroization complete; 10 new audio tests pass.
- N2-06 only reuses the single libopus 1.5.2 artifact; it does not connect
  `audio_player`/OHAudio/NAPI/ArkTS/UI/cloud/input or any product caller.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N2-07 (next): connect N2-06 PCM to the existing exact-owner `audio_player` registry and
  bounded queue; do not create a Moonlight-specific OHAudio owner.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle against the
  existing local `MoonlightRepository`, local app cache, Host Control and media
  prerequisites; no cloud status or sync settings.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 physical
  acceptance. Moonlight cloud sync (`moonlightrecordv1`, cloud selection and secret
  recovery) is parked for a separately approved task. Both allowed `sol low` reviewer
  slots are consumed; do not redispatch.
