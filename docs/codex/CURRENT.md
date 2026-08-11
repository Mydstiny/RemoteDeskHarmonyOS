# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `75d769c2` (`feat(moonlight): bind connection stage to session snapshots`; includes `647113a5` dormant coordinator fixes)
- Phase: U1-06～U1-12 local-only UI shell closeout and S1-01/S1-02 dormant session wiring are complete; S1-03 connection-stage snapshot binding is complete. S1-04/S1-05A, runtime, media, input and N2-09 external evidence remain pending.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`
- The only uncommitted file is the user-owned `entry/src/main/ets/services/CloudStore.ets` cloud-sync change; it is intentionally excluded from this task and remains untouched.

## Product decisions

- Moonlight remains local-host-only. Do not register, upload, or instantiate `moonlightrecordv1`; do not add Moonlight cloud selection, transfer, or secret recovery.
- RustDesk is the sole Moonlight UI reference. VNC is only an isolation/regression boundary, never a visual or interaction scaffold.
- The homepage is the canonical host-management entry. Moonlight settings has nine protocol sections; it does not duplicate host management, common display, PIP, or other shared host settings.
- The Moonlight FAB and PC sidebar slot remain disabled: last position, 0.58 parent opacity, one “即将支持”, no route and no background work.
- The icon is the pinned official Moonlight Qt geometry converted to a deterministic monochrome tintable asset, with system-symbol fallback; it is not an official endorsement.
- Real controller input remains S1-05A: HarmonyOS native listener → narrow typed NAPI → N3-08 → N3-05 → N3-01 → official common-c. ArkTS never encodes or directly sends controller wire data.

## UI shell checkpoint (`6b0c1aa8`)

- Added local-only `MoonlightHostDetailPage`, `MoonlightAppCatalogPage`, `MoonlightSettingsPage` and `MoonlightStreamPage`; routes are registered in `main_pages.json`.
- Added RustDesk-aligned `MoonlightLaunchSheet`, connect-stage overlay, session toolbar, control center, controller overlay, diagnostics HUD and brand icon components. They are UI contracts only; real transport/media/Host Control remains fail closed.
- The existing add Sheet’s native `onDisappear` handoff opens the catalog by stable local host ID. Catalog/detail/settings reload local records/cache with generation-fenced view refresh.
- Moonlight settings is a single-entry, nine-section surface. Common display/PIP settings and the redundant “主机管理” row were removed; host management belongs on the homepage.
- Desktop has a separate grey Moonlight sidebar slot even when other host cards are grouped. The FAB flow still passes `moonlightProtocolAvailable: false`.
- The review fixes keep legacy readable settings metadata compatible while rejecting legacy paths for new writes, lock certificate-change switches to the model-required safe state, treat `localCommitted` as the terminal local-save truth, and cancel/fence stream-sheet reopen timers on page exit.

## Dormant session checkpoint (`8b1ccd22` + `4548499c` + `647113a5`)

- `RemoteProtocol.moonlight`, the shared capability policy and the existing `ActiveRemoteSessionRegistry` now carry Moonlight without creating a second session owner. The registry rejects Moonlight records containing a transient endpoint and clears only an exact owner/account/session/protocol marker.
- `MoonlightSessionCoordinator` is a pure ArkTS, runtime-injected seam. It serializes launch, discovery, first-frame, stream-stable, transport-loss, stop/cancel and stale-callback transitions; it binds owner/account generation and requires a runtime port plus all three runtime capability truths before start. The singleton has no injected runtime, so production remains fail closed.
- `MoonlightAppCatalogPage` is a thin adapter that passes a transient host address only to the future runtime port; it never writes that address to the shared registry or local/cloud storage. `MoonlightStreamPage` binds the current account scope and invalidates/cleans up on account changes and route exit.
- Added nine coordinator cases, a Moonlight capability case and test-list registration. No common-c/native/NAPI/GameController/OHAudio/Surface/cloud/product caller was added; the UI picker and launch flow remain unavailable.
- `4548499c` closes the first review findings: registry reservation is atomic against a competing protocol, launch promotion requires the exact reservation, prelaunch cancellation reaches the runtime port, stop failure immediately becomes local-terminal, and post-launch callbacks must carry the matching native session ID. `647113a5` adds the actual 5-second watchdog and verifies prelaunch reservation cleanup only after a stopped event or terminal timeout.

## Verification

- Exact `default@OhosTestCompileArkTS ... --no-daemon`: BUILD SUCCESSFUL after `75d769c2`.
- Exact `assembleHap ... --no-daemon`: BUILD SUCCESSFUL after `75d769c2`; final deployed signed HAP SHA-256 is `a89fc076f3edc9ca502d94fd53b0fdbb4b61c14c14bf242a250225f76917e077`.
- Fresh sandbox-external HDC install/start succeeded on PC `127.0.0.1:5555` and phone `127.0.0.1:5557` after the `75d769c2` build.
- Latest fresh 2026-08-12 evidence from the final `75d769c2` HAP: PC root `/private/tmp/moonlight-s103-final-20260812-pc-root.jpeg`, PC large-screen sidebar `/private/tmp/moonlight-s103-final-20260812-pc-max.jpeg`, PC picker/disabled-click `/private/tmp/moonlight-s103-final-20260812-pc-picker.jpeg` and `/private/tmp/moonlight-s103-final-20260812-pc-picker-click.jpeg`, phone root/picker `/private/tmp/moonlight-s103-final-20260812-phone-root.jpeg` and `/private/tmp/moonlight-s103-final-20260812-phone-picker.jpeg`. Each was captured after reinstalling the final HAP and viewed in this checkpoint; no older screenshot is used. RDP remains unchanged; PC shows a separate grey Moonlight sidebar slot with the official tintable geometry and “即将支持”; clicking the disabled row leaves the picker open on `pages/HostListPage`.
- Latest fresh 2026-08-12 phone settings evidence: `/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-top.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-lower2.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-moonlight-accordion2.jpeg`, and `/private/tmp/moonlight-final-20260812-s1-final4-phone-quick-sheet3.jpeg`. The layout remains readable, Moonlight is one consolidated settings section, its child entries open as a separate bindSheet, and no redundant “主机管理” row exists; only these newly captured and viewed images are used for the current acceptance record.
- Moonlight focused tests remain compile-registered (163 documented focused tests in 21 describe groups plus 8 shared host-add handoff cases; this checkpoint adds one coordinator subscription case); `ohosTest` remains unregistered (`00306054`), so no device Hypium PASS is claimed.
- Incremental reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` rechecked the `75d769c2` S1-03 delta and returned PASS with P0/P1/P2/P3 all zero. Static isolation for the code range is unchanged: RDP, RustDesk, SSH/SFTP, VNC, public input, native/CMake/NAPI, `CloudSyncPolicy` and existing cloud-table registration were not changed.
- `git diff --check` and state validation pass. The user-owned `CloudStore.ets` diff is excluded from the review and remains unstaged.

## Next / blockers

- Next implementation boundary: S1-04 session toolbar/control center, then S1-05A native GameController/typed NAPI wiring and N2-09 real Sunshine/ARM64 external evidence. S1-03 now binds only coordinator snapshots and remains fail closed; keep every product capability false until its runtime receipt exists.
- Remaining acceptance is not a release claim: real AppSpawn secure identity, Sunshine transport/media/first frame, OHAudio/Surface lifecycle, physical controller, on-device Hypium, and long-run performance are unproven.
- `ohosTest@OhosTestCompileArkTS` is still blocked by unregistered task `00306054`.
