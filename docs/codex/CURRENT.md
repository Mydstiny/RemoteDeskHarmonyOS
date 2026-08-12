# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `db750cdb` (`feat(moonlight): wire local host add persistence`); S1-04 remains closed on top of `fae7c36dd` and `f7f39c0f`.
- Phase: U1-13 local-only Moonlight host-add persistence is closed; S1-05A native controller ingress, runtime/media and N2-09 external evidence remain pending.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`
- User-owned `entry/src/main/ets/services/CloudStore.ets` is the only unstaged code file; it remains untouched and outside this task.

## Product decisions

- Moonlight remains local-host-only. No `moonlightrecordv1` registration, cloud selection/transfer, secret recovery or cloud upload was added.
- RustDesk is the sole Moonlight UI reference. Homepage host management is canonical; Moonlight has nine protocol sections and no duplicate host/common display/PIP management.
- The Moonlight FAB and PC sidebar slot remain disabled: grey/tintable icon, 0.58 parent opacity, one “即将支持”, no route and no background work.
- Real controller input remains S1-05A: HarmonyOS native listener → narrow typed NAPI → N3-08 → N3-05 → N3-01 → official common-c. ArkTS never encodes or directly sends controller wire data.

## U1-13 local data closeout

- `MoonlightLocalHostService` now adapts the existing injected `MoonlightRepositoryPort` only: validated host + trust rows, `localOnly=1`, owner/account lease and operation-generation fences, stable IDs and duplicate detection.
- Host/trust writes are constructed before the first write and are guarded by readback-aware compensation. Forward tombstones, explicit revival, existing-host restoration and `not_committed`/`partial`/`uncertain` outcomes prevent blind retry or false catalog handoff.
- `HostListPage` passes the local-save callback into the RustDesk-style add Sheet. Catalog/detail navigation still waits for the native Sheet `onDisappear` boundary and carries only stable ID + owner/generation.
- No cache, cloud, transport, decoder, audio, input, registry, FAB or release-truth state is opened by this path.

## Verification

- Exact `default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL` after `db750cdb`.
- Exact `assembleHap --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL`; HAP: `entry/build/default/outputs/default/entry-default-signed.hap`; SHA-256 `8b54784ac3112b30a5630ef074d35150fd7271099920e54ab97809ef1546263e`.
- HDC installed/started this latest HAP on PC `127.0.0.1:5555` and phone `127.0.0.1:5557`. Only fresh evidence from `/private/tmp/moonlight-final-gate.bIGtZD/` is used: `pc-root.png`, `phone-root.png`, `pc-picker-open.png`, `phone-picker-open.png`, `pc-max.png`, `phone-settings.png`, `phone-moon-expanded.png`, and `phone-quick.png`.
- Fresh UI evidence confirms homepage ownership, disabled FAB picker on PC/phone, the PC large-screen Moonlight sidebar slot, the consolidated public host-list entry, the expanded Moonlight settings sections, and a real Moonlight quick-settings bindSheet. No old screenshot is used.
- New focused coverage: 8 local persistence cases, 1 recovery-policy case and 1 post-save handoff case; all are compile-registered. `ohosTest` remains unavailable because task `00306054` is not registered; no device Hypium PASS is claimed.
- Reused reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`: final increment PASS, P0/P1/P2=0; P3=1 is the accepted pure-test exception-path limitation. Static scope isolation confirms no adjacent protocol/native/cloud-table/runtime business change.
- `git diff --check` and `node scripts/codex_state.mjs validate` remain required after documentation sync.

## Next / blockers

- Next implementation boundary: S1-05A native HarmonyOS GameController listener plus narrow typed NAPI and the single session-owned common-c input port. Keep controller capability false until the chain and real-device receipts exist.
- Remaining acceptance is not a release claim: AppSpawn secure identity, real Sunshine pairing/transport/media/first-frame, OHAudio/Surface lifecycle, physical controller, on-device Hypium, network/thermal/long-run evidence remain unproven.
- Moonlight cloud sync is intentionally parked. The user-owned CloudStore cloud-sync diff remains unstaged and is not part of this checkpoint.
