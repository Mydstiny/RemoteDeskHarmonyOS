# Shared Current State

## Active task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Committed code checkpoint: `75c69ca1b`; the reviewed feasibility increment is committed.
- Phase: local-only LAN discovery, Host Control, catalog/launch, H.264/Opus stream runtime and native input feasibility closeout.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Current product boundary

- Moonlight remains local-only. No Moonlight cloud table, cloud registration, selection, transfer, secret recovery or cloud upload is active.
- Homepage/FAB, phone host directory and the dedicated PC Moonlight tab now open the RustDesk-style local add and host-management flows. Rendering the homepage does not initialize Moonlight native/security components.
- LAN discovery/verification, pairing, local host/trust persistence, catalog refresh/cache, app launch and Catalog-to-Stream owner/account/store fencing are connected to the product runtime.
- The stream path uses the pinned official common-c transport, HarmonyOS Surface/H.264 video, Opus/OHAudio stereo, first-frame truth and asynchronous terminal receipts. Current conservative offer is H.264, 8-bit YUV420, stereo and low latency; bitrate is wired.
- Keyboard, pointer, touch, virtual controller and physical GameControllerKit input share one session-owned common-c path. Terminal release runs on the terminal worker; source handoff is remove-first; one exact pending event is retried under backpressure.
- GameControllerKit is loaded with `dlopen`/`dlsym` only when a Moonlight stream activates physical-controller input. Failure degrades the physical controller only; `librdpnapi.so` has no `libohgame_controller.z.so` `DT_NEEDED` or unresolved `OH_Game*` symbol on either ABI.
- Existing protocol business implementations are unchanged. The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains excluded from staging and review.

## Latest verification

- Exact `default@OhosTestCompileArkTS`: PASS on 2026-08-13.
- Exact `assembleHap`: PASS after the final input/lifecycle fixes; signed HAP is `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `8301133af6083c992e2a93f7bd504ef351491bbca3c1103faf12b80cf2150a2b`.
- DevEco native `arm64-v8a` and `x86_64` `rdpnapi`: PASS after the final lifecycle and dynamic-loader fixes.
- ELF dependency/isolation check on both ABIs: PASS; no mandatory GameControllerKit dependency or unresolved GameControllerKit symbol.
- Host native suite: 710 passed of 726; all Moonlight input/media cases passed. The unchanged 16 local TLS-fixture startup failures remain outside this increment.
- `git diff --check`: PASS.
- Reused ArkTS/UI and native/media reviewers: PASS, P0/P1/P2=0. The native review drove the final virtual-pending/physical-ONLINE/OFFLINE backpressure fix before this commit.
- Sandbox-external HDC currently reports both `127.0.0.1:5555` and `127.0.0.1:5557` Offline; reconnect failed, so this HAP has not yet been installed or visually accepted on the current devices.

## Next and blockers

- Next: N2-09 device feasibility receipt against a real Sunshine host: discover, pair, refresh catalog, launch, receive first video/audio frame, send keyboard/touch/virtual controller and physical controller, stop cleanly, then repeat on phone and PC layouts with fresh screenshots.
- After feasibility: wire the remaining Moonlight-only settings (codec/HDR/YUV444/audio layout and volume, reconnect/background/diagnostics preferences) to the native request model and complete lifecycle/thermal/network/long-run acceptance.
- Device installation, fresh PC/phone screenshots and real Sunshine/physical-controller receipts are blocked only by the current Offline HDC targets or unavailable external host/hardware state; no device PASS is claimed.
- Moonlight cloud sync stays parked.
