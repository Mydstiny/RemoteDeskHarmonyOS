# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- U1-01～U1-04 are complete through `dd6ec9c5`.
- Moonlight uses the same `HostProtocolPicker.protocolOption()` card contract as RustDesk and the same
  existing FAB → picker → single-Sheet ownership path. Default state remains disabled, 0.58 opacity,
  exactly one “即将支持”, and a tap produces no route.
- The protocol icon is a deterministic tintable transform of the pinned official Moonlight Qt SVG with
  exact provenance/SHA/compliance records and a HarmonyOS system-symbol fallback.
- U1-04 adds a dormant RustDesk-style four-step Moonlight add component and pure state policy. Discovery,
  operations, PIN, certificate trust, explicit rejection and local-commit truth are owner/generation fenced.
- Both Hvigor gates, signed HAP, Light/vendor/SBOM/hash/diff checks and sandbox-external HDC
  install/start/render/disabled-tap verification pass; aggregate is 161 tests in 21 describe groups.
- RustDesk flow, all other protocol business sources, native sources and cloud sources are unchanged.
  `HostListPage` has only a thin dormant branch; picker remains explicitly false, so the component never
  mounts and starts no network, timer, repository or background work. Cloud registration remains 8 tables.
- Existing reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` returned final PASS for
  `541aaed7a..dd6ec9c5` with P0/P1/P2/P3 all zero; do not create another reviewer.

## Next

- U1-05 is the only next actionable UI contract: build the save-and-open handoff on the existing Sheet
  disappearance lifecycle, without fixed delays. It must remain dormant until real local persistence and
  Host Control callbacks are wired and proven.
- Keep the picker disabled until Host Control, secure identity, local persistence and runtime prerequisites
  are genuinely ready; U1-04's default callbacks intentionally fail closed.
- S1-05A later connects the real HarmonyOS GameController native listener and narrow virtual typed NAPI
  to N3-08. ArkTS never encodes or directly transmits controller wire data.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.

## Later

- Local-only Moonlight host detail, app catalog, launch preflight, settings, connection overlays and
  lifecycle tasks continue in plan order after U1-04.
- Real Sunshine/device/network/power matrix, full existing-protocol regression and user ARM64 acceptance.
- Moonlight cloud sync (`moonlightrecordv1`, selection and secret recovery) stays parked.
