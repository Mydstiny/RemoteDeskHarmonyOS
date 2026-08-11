# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- U1-01～U1-03 are complete in `c38ff6265` with review fixes `71e9902c9`, `7eaad950b`.
- Moonlight uses the same `HostProtocolPicker.protocolOption()` card contract as RustDesk and the same
  existing FAB → picker → single-Sheet ownership path. Default state remains disabled, 0.58 opacity,
  exactly one “即将支持”, and a tap produces no route.
- The protocol icon is a deterministic tintable transform of the pinned official Moonlight Qt SVG with
  exact provenance/SHA/compliance records and a HarmonyOS system-symbol fallback.
- Both Hvigor gates, signed HAP, Light/vendor/SBOM/hash/diff checks and sandbox-external HDC
  install/start/render/disabled-tap verification pass.
- RustDesk flow, HostList FAB owner, all protocol business sources, native sources and cloud sources are
  unchanged. Cloud registration remains exactly 8 tables; Moonlight remains local-only.
- Existing reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` returned final PASS for
  `99eecdbea..7eaad950b` with P0/P1/P2/P3 all zero; do not create another reviewer.

## Next

- U1-04 is the only next actionable UI task: create `MoonlightHostAddFlow.ets` plus pure four-step state
  policy for local host discovery/manual address, pairing/trust and local save.
- U1-04 must directly reuse RustDesk's visual and interaction grammar: header/step copy, mode cards,
  fields, errors, 44vp primary button, back/close behavior and the existing single Sheet owner. Do not
  copy RustDesk relay/TOTP/credential business state and do not use another protocol page as a scaffold.
- Keep the picker disabled until U1-04 and its Host Control/runtime prerequisites are genuinely ready.
- S1-05A later connects the real HarmonyOS GameController native listener and narrow virtual typed NAPI
  to N3-08. ArkTS never encodes or directly transmits controller wire data.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.

## Later

- Local-only Moonlight host detail, app catalog, launch preflight, settings, connection overlays and
  lifecycle tasks continue in plan order after U1-04.
- Real Sunshine/device/network/power matrix, full existing-protocol regression and user ARM64 acceptance.
- Moonlight cloud sync (`moonlightrecordv1`, selection and secret recovery) stays parked.
