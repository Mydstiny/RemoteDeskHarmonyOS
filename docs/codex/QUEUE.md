# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N2-07 checkpoint `9272f1c9c`: hidden exact-owner PCM sink delegates only to the
  existing `audio_player` registry/bounded queue and freezes focus/background pause,
  resume/rebuffer, mute, stop/flush and stale-callback behavior; 10 new tests pass.
- No private OHAudio owner, queue, registry, worker, NAPI or product session caller was
  added; audio acceptance still cannot set video first-frame or a release truth.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N2-08 (next): add bounded owner-scoped media clock/stats with absent-vs-zero values,
  p50/p95 windows and sampled native aggregation; no NAPI/ArkTS handoff yet.
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
