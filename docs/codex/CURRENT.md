# Shared Current State

## Active task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Committed code checkpoint: `bc630af34`; the reviewed feasibility/UI/settings increment is committed.
- Phase: local-only LAN discovery, Host Control, catalog/launch, H.264/Opus stream runtime and native input feasibility closeout.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Current product boundary

- Moonlight remains local-only. No Moonlight cloud table, cloud registration, selection, transfer, secret recovery or cloud upload is active.
- Homepage/FAB, phone host directory and the dedicated PC Moonlight tab now open the RustDesk-style local add and host-management flows. Rendering the homepage does not initialize Moonlight native/security components; capability probing occurs only after an explicit FAB action.
- FAB admission uses the proven `bridgeCompiled && transportReady` layer, so LAN discovery and HTTP host verification remain available. Pairing independently requires `hostControlReady`; an unavailable secure-identity runtime fails before PIN generation and cannot reach trust or local save.
- LAN discovery/verification, pairing, local host/trust persistence, catalog refresh/cache, app launch and Catalog-to-Stream owner/account/store fencing are connected to the product runtime.
- The stream path uses the pinned official common-c transport, HarmonyOS Surface/H.264 video, Opus/OHAudio stereo, first-frame truth and asynchronous terminal receipts. Current conservative offer is H.264, 8-bit YUV420, stereo and low latency; bitrate is wired.
- Keyboard, pointer, touch, virtual controller and physical GameControllerKit input share one session-owned common-c path. Terminal release runs on the terminal worker; source handoff is remove-first; one exact pending event is retried under backpressure.
- GameControllerKit is loaded with `dlopen`/`dlsym` only when a Moonlight stream activates physical-controller input. Failure degrades the physical controller only; `librdpnapi.so` has no `libohgame_controller.z.so` `DT_NEEDED` or unresolved `OH_Game*` symbol on either ABI.
- Existing protocol business implementations are unchanged. The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains excluded from staging and review.

## Latest verification

- Exact `default@OhosTestCompileArkTS`: PASS on 2026-08-13.
- Exact `assembleHap`: PASS after the final review fixes; signed HAP is `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `3ec6e5abb4c685d83097ce49793c408301679d8aed19f8376f611456b8a26d85`.
- DevEco native `arm64-v8a` and `x86_64` `rdpnapi`: PASS after the final lifecycle and dynamic-loader fixes.
- ELF dependency/isolation check on both ABIs: PASS; no mandatory GameControllerKit dependency or unresolved GameControllerKit symbol.
- Host native suite: 711 passed of 727; all Moonlight input/media cases passed. The unchanged 16 unrelated local TLS-fixture startup failures remain outside this increment.
- `git diff --check`: PASS.
- Reused ArkTS/UI and native/media reviewers: PASS, P0/P1/P2=0. Final fixes include account-lease save fencing, exact FAB capability layers, fail-closed encryption/latency admission and truthful verification errors.
- Sandbox-external HDC installed and started the exact signed HAP on phone `127.0.0.1:5555` and PC `127.0.0.1:5557`. Fresh exact-package screenshots accept the enabled phone FAB, official tintable icon, adaptive add/discovery page and independent PC Moonlight category; the six visible settings bindSheets were also inspected on both form factors during this increment.

## Next and blockers

- Next: N2-09 device feasibility against a real Sunshine host, first resolving/proving the Asset Store secure-identity runtime on the target device; then pair, refresh catalog, launch, receive first video/audio frame, send keyboard/touch/virtual/physical-controller input and stop cleanly.
- After feasibility: wire the remaining Moonlight-only settings (codec/HDR/YUV444/audio layout and volume, reconnect/background/diagnostics preferences) to the native request model and complete lifecycle/thermal/network/long-run acceptance.
- Both simulators prove product startup, FAB admission, LAN discovery start and adaptive UI. They currently report `hostControlReady=false` because secure-identity runtime proof is unavailable, so no simulator pairing/stream receipt is claimed. A reachable Sunshine host, a target with working secure identity and a physical controller remain external/runtime prerequisites.
- Moonlight cloud sync stays parked.
