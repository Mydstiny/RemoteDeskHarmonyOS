# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- U1-01～U1-05 are complete through `094a8b3b`.
- Moonlight uses the same `HostProtocolPicker.protocolOption()` card contract as RustDesk and the same
  existing FAB → picker → single-Sheet ownership path. Default state remains disabled, 0.58 opacity,
  exactly one “即将支持”, and a tap produces no route.
- The protocol icon is a deterministic tintable transform of the pinned official Moonlight Qt SVG with
  exact provenance/SHA/compliance records and a HarmonyOS system-symbol fallback.
- U1-04 adds a dormant RustDesk-style four-step Moonlight add component and pure state policy. Discovery,
  operations, PIN, certificate trust, explicit rejection and local-commit truth are owner/generation fenced.
- U1-05 adds the dormant stable-ID save-and-open handoff on the same RustDesk add Sheet native
  `onDisappear` boundary. There is no fixed delay or second Sheet; duplicate repository writes are fenced,
  and committed-without-ID remains terminal while catalog navigation is rejected.
- Both Hvigor gates, signed HAP, Light/vendor/SBOM/hash/diff checks and sandbox-external HDC
  install/start/render/disabled-tap verification pass; aggregate is 162 Moonlight tests in 21 describe groups
  plus 8 shared host-add handoff cases.
- RustDesk flow, all other protocol business sources, native sources and cloud sources are unchanged.
  `HostListPage` has only a thin dormant branch; picker remains explicitly false, so the component never
  mounts and starts no network, timer, repository or background work. Cloud registration remains 8 tables.
- Existing reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` returned final PASS for
  `708172c08..094a8b3b` with P0/P1/P2/P3 all zero; do not create another reviewer.

## Next

- U1-06 is the only next actionable UI contract: create the local-only Moonlight host detail and app catalog
  Navigation pages using RustDesk as the sole visual/interaction baseline. HostList stays a thin aggregator;
  empty/stale/partial/offline/large/broken-cover states need owner/generation-fenced tests.
- Keep the picker disabled until Host Control, secure identity, local persistence and runtime prerequisites
  are genuinely ready; U1-04's default callbacks intentionally fail closed.
- S1-05A later connects the real HarmonyOS GameController native listener and narrow virtual typed NAPI
  to N3-08. ArkTS never encodes or directly transmits controller wire data.
- N2-09 remains external pending for real Sunshine and ARM64 physical media testing.

## Later

- Launch preflight, settings, connection overlays and lifecycle tasks continue in plan order after U1-06.
- Real Sunshine/device/network/power matrix, full existing-protocol regression and user ARM64 acceptance.
- Moonlight cloud sync (`moonlightrecordv1`, selection and secret recovery) stays parked.
