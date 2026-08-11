# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- N3-08 `fef723770` + review fix `6787cc3fb`: fixed-capacity native physical/virtual controller aggregator and deterministic
  layout validator are complete. Physical full-state and virtual semantic events share slot 0 but are
  fenced by source/device/generation and use only N3-05→N3-01→official common-c.
- Both directions use remove-first handoff with separate boundary-retry/resume generations; retired mapper
  lanes reject old events while supporting 20+ alternating handoffs. Twenty-eight focused tests,
  normal/strict/sanitizers/TSan/analyzer, both Hvigor gates and signed HAP pass.
- The private dual-ABI archive has no product caller and contributes no object or dynamic symbol to
  `rdpnapi`; ABI counts remain arm64 16114/705 and x86_64 15645/703. No production common-c, shared
  `InputHandler`, telemetry/audio/render, cloud source or existing protocol business source was modified.
- Keep FAB disabled, all six release truths false and online cloud registration
  at exactly 8 tables. Moonlight itself is local-only for the current rollout;
  do not create or register `moonlightrecordv1`.

## Next

- U1-01 (next actionable): snapshot VNC sm/md/lg/xl, short-screen and large-font layout/interaction
  baselines, extract protocol-neutral `RemoteConfigSheetScaffold.ets`, and reduce `VncSheetScaffold`
  to a thin wrapper with zero VNC DOM/screenshot/interaction differences.
- S1-05A later connects the real HarmonyOS GameController native listener and narrow virtual typed
  NAPI ingress to N3-08. Until then physical controller transport is a tested dormant native seam, not
  a product runtime capability; ArkTS must never encode or directly transmit controller wire data.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.
- S1-08: consume the dormant N2-05 native contract from the existing
  `NativeSessionHandles`/PIP/background lifecycle only after media prerequisites.
- U1/S1 UI, settings, catalog, connection overlays and lifecycle against the
  existing local `MoonlightRepository`, local app cache, Host Control and media
  prerequisites; no cloud status or sync settings.

## Later

- Real Sunshine/device/network/power matrix, full regression and user ARM64 acceptance.
  Moonlight cloud sync (`moonlightrecordv1`, selection and secret recovery) stays parked.
  N3-08 reuses the existing `sol low` reviewer; reuse it again, never create a third instance.
