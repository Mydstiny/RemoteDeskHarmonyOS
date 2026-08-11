# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N3-04 checkpoint `ebd2fa0bc5`: hidden bounded `MoonlightTouchMapper` implements official
  direct-touch bodies, stable multi-contact ids, transform/cancel/overlay ownership and touchpad
  one/two/three-finger gestures by reusing the N3-03 pointer transaction layer; 21 new tests pass.
- Its private dual-ABI archive has no product caller and contributes no object or dynamic symbol to
  `rdpnapi`; ABI counts remain identical to N3-03. No production common-c, shared `InputHandler`,
  telemetry/audio/render, cloud source or existing protocol business source was modified.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N3-05 (next actionable): define dormant pure-native physical-controller mapping using API 23
  probe facts, with stable device-to-slot ownership, axes/triggers/dead zones and disconnect neutral;
  keep one slot until multi-player capability has real-device proof and add no product wiring.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.
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
