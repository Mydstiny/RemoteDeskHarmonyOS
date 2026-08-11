# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N3-07 checkpoint `02cb13aae`: hidden `MoonlightInputFlushPolicy` composes the existing touch,
  pointer, keyboard, controller and bridge release contracts for every planned lifecycle trigger;
  exact retry, idempotence, suspend/resume and local-terminal stop are covered by 19 new tests.
- Its private dual-ABI archive has no product caller and contributes no object or dynamic symbol to
  `rdpnapi`; ABI counts remain identical to N3-04. No production common-c, shared `InputHandler`,
  telemetry/audio/render, cloud source or existing protocol business source was modified.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N3-08 (next actionable): define a dormant virtual-controller model and deterministic layout
  validator; route its button/stick/trigger/dpad full-state through the existing native N3-05 mapper,
  N3-01 bridge and common-c port, with edit-mode zero-send and N3-07 lifecycle neutral.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle against the
  existing local `MoonlightRepository`, local app cache, Host Control and media
  prerequisites; no cloud status or sync settings.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 physical
  acceptance. Moonlight cloud sync (`moonlightrecordv1`, cloud selection and secret
  recovery) is parked for a separately approved task. Reuse an existing `sol low` reviewer task ID
  for later checkpoints; do not create a third reviewer instance.
