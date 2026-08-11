# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N3-07 `02cb13aae` + fixes `36b4e13df`/`337c4f35e` + test evidence `ee073afcb`: bridge admission closes before mapper release and
  accepts only lifecycle-release events; component permanent failure, owner loss, pending/suspended
  stop escalation, exact terminal replay and stale stop are covered by 26 focused tests.
- Its private dual-ABI archive has no product caller and contributes no object or dynamic symbol to
  `rdpnapi`; ABI counts remain identical to N3-04. No production common-c, shared `InputHandler`,
  telemetry/audio/render, cloud source or existing protocol business source was modified.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- N3-08 (next actionable): define a dormant virtual-controller model and deterministic layout
  validator. Physical listener and virtual typed ingress must aggregate/transmit controller full-state
  natively through N3-05→N3-01→common-c; handoff requires accepted active-mask=0 removal, slot 0 clear,
  then higher-generation connect. Edit mode is zero-send and all lifecycle release reuses N3-07.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle against the
  existing local `MoonlightRepository`, local app cache, Host Control and media
  prerequisites; no cloud status or sync settings.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 acceptance.
  Moonlight cloud sync (`moonlightrecordv1`, selection and secret recovery) stays parked.
  N3-07 reused the existing `sol low` reviewer and passed; reuse it again, never create a third instance.
