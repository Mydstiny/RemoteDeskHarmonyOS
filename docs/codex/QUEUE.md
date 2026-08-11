# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N3-02 checkpoint `a552b30a2`: hidden bounded `MoonlightKeyboardMapper` implements the
  official prefixed-VK body, once/locked modifiers, strict UTF-8 text, exact retry,
  cross-device key-up rejection, full 16-command release and local physical Escape;
  15 new tests pass.
- Its private dual-ABI archive has no product caller and contributes no object or
  dynamic symbol to `rdpnapi`; no production common-c, shared `InputHandler`,
  telemetry/audio/render source or existing protocol business source was modified.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N3-03 (next actionable): define dormant pure-native absolute/relative mouse, button,
  wheel and content-rect mapping contracts. Keep capture/constraint/raw-relative behind
  HAP/device proof; no shared InputHandler, NAPI, ArkTS, UI or product wiring yet.
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
