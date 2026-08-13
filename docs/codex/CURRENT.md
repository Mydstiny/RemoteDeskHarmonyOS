# Shared Current State

## Active task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Committed code checkpoint: `ef13ca19`; API-23 secure identity and Host Control runtime proof are committed and reviewed.
- Phase: S1-06 settings closeout while N2-09B real-Sunshine interoperability remains an external runtime gate.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Current product boundary

- Moonlight remains local-only. No Moonlight cloud table, cloud registration, selection, transfer, secret recovery or cloud upload is active.
- Homepage/FAB, phone host directory and the dedicated PC Moonlight tab now open the RustDesk-style local add and host-management flows. Rendering the homepage does not initialize Moonlight native/security components; capability probing occurs only after an explicit FAB action.
- FAB admission uses the proven `bridgeCompiled && transportReady` layer, so LAN discovery and HTTP host verification remain available. Pairing independently requires `hostControlReady`; an unavailable secure-identity runtime fails before PIN generation and cannot reach trust or local save.
- API-23 Asset Store now uses the credential-encrypted database consistently for add/query/remove/list. Runtime probes have per-attempt owners, exact cleanup, stale-crash reclamation and bounded inventory retry; both current simulators prove `identityReady=pairingReady=hostControlReady=true`.
- LAN discovery/verification, pairing, local host/trust persistence, catalog refresh/cache, app launch and Catalog-to-Stream owner/account/store fencing are connected to the product runtime.
- The stream path uses the pinned official common-c transport, HarmonyOS Surface/H.264 video, Opus/OHAudio stereo, first-frame truth and asynchronous terminal receipts. Current conservative offer is H.264, 8-bit YUV420, stereo and low latency; bitrate is wired.
- Keyboard, pointer, touch, virtual controller and physical GameControllerKit input share one session-owned common-c path. Terminal release runs on the terminal worker; source handoff is remove-first; one exact pending event is retried under backpressure.
- GameControllerKit is loaded with `dlopen`/`dlsym` only when a Moonlight stream activates physical-controller input. Failure degrades the physical controller only; `librdpnapi.so` has no `libohgame_controller.z.so` `DT_NEEDED` or unresolved `OH_Game*` symbol on either ABI.
- Existing protocol business implementations are unchanged. The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains excluded from staging and review.

## Latest verification

- Exact `default@OhosTestCompileArkTS`: PASS on 2026-08-13.
- Exact `assembleHap`: PASS after the final review fixes; signed HAP is `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `7e84303d06b33926fa702a2384584010612a2517b88aa38aad8d7e4c23096318`.
- DevEco native `arm64-v8a` and `x86_64` `rdpnapi`: PASS after the final lifecycle and dynamic-loader fixes.
- ELF dependency/isolation check on both ABIs: PASS; no mandatory GameControllerKit dependency or unresolved GameControllerKit symbol.
- Host native suite: 711 passed of 727; all Moonlight input/media cases passed. The unchanged 16 unrelated local TLS-fixture startup failures remain outside this increment.
- `git diff --check`: PASS.
- Reused ArkTS/UI and native/media reviewers: PASS, P0/P1/P2/P3=0. The final native recheck closed concurrent probe deletion, crash-orphan quota exhaustion and cross-process list snapshot invalidation.
- Sandbox-external HDC installed and started the exact signed HAP on phone `127.0.0.1:5555` and PC `127.0.0.1:5557`. Both report `bridge=identity=transport=pairing=hostControl=1 blocker=none`; newly captured `7e84303d` phone/PC FAB screenshots were opened and inspected.
- Moonlight vendor 3-tree/117-file verification, Light open-source compliance, dual-ABI platform link probes and GameControllerKit ELF isolation all PASS.

## Next and blockers

- Next local task: S1-06 removes hidden legacy settings routes/builders and wires only remaining Moonlight-owned reconnect/background/diagnostics controls without duplicating public display, PIP, volume or host management.
- N2-09A secure-identity runtime is closed on both simulators. N2-09B/C still require a reachable real Sunshine host and physical controller to prove pair, catalog, launch, first video/audio frame, input and clean stop; no real-stream receipt is claimed yet.
- After S1-06: complete lifecycle, network, thermal, two-hour, ARM64 and physical-controller acceptance as runtime prerequisites become available.
- Moonlight cloud sync stays parked.
