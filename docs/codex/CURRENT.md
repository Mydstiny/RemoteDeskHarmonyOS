# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `6b0c1aa8` (`fix(moonlight): close ui review findings`)
- Phase: U1-06～U1-12 local-only UI shell closeout complete; S1 runtime wiring and N2-09 external evidence remain pending.
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

## Verification

- Exact `default@OhosTestCompileArkTS ... --no-daemon`: BUILD SUCCESSFUL after `6b0c1aa8`.
- Exact `assembleHap ... --no-daemon`: BUILD SUCCESSFUL after `6b0c1aa8`; final signed HAP SHA-256 is `7a723ce9b300d6b8e131006472ed2efa8d7985a8cd672385857e468a84181b87`.
- Fresh sandbox-external HDC install/start succeeded on PC `127.0.0.1:5555` and phone `127.0.0.1:5557` after the latest build.
- Latest fresh r2 PC evidence: `/private/tmp/moonlight-final-20260811-r2-pc-full.jpeg` and `.json` — RDP remains the active page; Moonlight is a separate grey sidebar slot with the official tintable geometry and “即将支持”.
- Latest fresh r2 phone evidence: `/private/tmp/moonlight-final-20260811-r2-phone-settings.jpeg`, `/private/tmp/moonlight-final-20260811-r2-phone-settings-scroll.jpeg` and corresponding `.json` UI trees — Moonlight subtitle is `串流画面、音频、控制与本地安全设置`, the nine sections are present, and no “主机管理” row exists.
- Latest fresh r2 sheet evidence: `/private/tmp/moonlight-final-20260811-r2-moonlight-accordion.jpeg`, `/private/tmp/moonlight-final-20260811-r2-quick-sheet.jpeg`, `/private/tmp/moonlight-final-20260811-r2-moonlight-lower.jpeg`, `/private/tmp/moonlight-final-20260811-r2-network-sheet.jpeg` and corresponding `.json` UI trees — unified bindSheet layout, RustDesk visual language, and disabled certificate-change control are visible.
- Moonlight focused tests remain compile-registered (162 tests in 21 describe groups plus 8 shared host-add handoff cases); `ohosTest` remains unregistered (`00306054`), so no device Hypium PASS is claimed.
- Incremental reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` re-reviewed `2c37b0edf..6b0c1aa8` and returned PASS: P0/P1/P2/P3 all zero. Static isolation also passed: RDP, RustDesk, SSH/SFTP, VNC, public input, native/CMake/NAPI, `CloudSyncPolicy` and existing cloud-table registration were not changed by this Moonlight range.
- `git diff --check` and state validation pass. The user-owned `CloudStore.ets` diff is excluded from the review and remains unstaged.

## Next / blockers

- Next implementation boundary: S1-01/S1-02 session registry/coordinator, then S1-05A native GameController ingress and N2-09 real Sunshine/ARM64 external evidence. Keep every product capability false until its runtime receipt exists.
- Remaining acceptance is not a release claim: real AppSpawn secure identity, Sunshine transport/media/first frame, OHAudio/Surface lifecycle, physical controller, on-device Hypium, and long-run performance are unproven.
- `ohosTest@OhosTestCompileArkTS` is still blocked by unregistered task `00306054`.
