# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: final adaptive FAB/add-sheet and controller-isolation fix is ready for commit; `CloudStore.ets` remains user-owned and unstaged.
- Phase: U1-14 adaptive UI closeout plus S1-05A boundary audit; real session binding remains pending.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Product decisions

- Moonlight data remains local-host-only. No `moonlightrecordv1`, cloud selection/transfer, secret recovery or cloud upload was added.
- RustDesk is the sole Moonlight UI reference. Homepage host management remains canonical; Moonlight has no duplicate public display/PIP/host-management section.
- The FAB Moonlight row follows the RustDesk route contract and opens the four-step local add shell through a separate `moonlightFabEntryAvailable` gate. Because `moonlightProtocolAvailable` remains false, the card explicitly says `仅添加` and has no runtime chevron; pairing, catalog, streaming and save callbacks remain fail-closed until runtime ports exist.
- The PC sidebar Moonlight slot remains a separate disabled preview slot; the FAB route and sidebar preview are intentionally not the same capability gate.
- Native controller work is isolated foundation only: the GameControllerKit listener is test-only/future-session code, is not in production `rdpnapi`, is not registered from shared NAPI, has no public controller NAPI, and has no common-c product input port. A future S1-05A session must bind one typed sink through N3-08 → N3-05 → N3-01 → common-c.

## U1-14 adaptive FAB/add closeout

- `MoonlightHostAddFlow` now consumes `currentBreakpoint`, uses an intrinsic content column like `RustDeskAddFlow`, and applies phone/large-screen content padding consistently.
- Discovery actions are one vertical action group with a 12vp small-screen gap (10vp on larger breakpoints); completion actions use a 12vp gap instead of adjacent/粘连 buttons.
- Dynamic discovery candidates are inside a bounded `Scroll` (260vp on phone, 320vp on larger layouts); only the candidate region scrolls, preserving the actions at the bottom.
- `HostListPage` uses `SheetSize.FIT_CONTENT` for Moonlight on every breakpoint, removing the former PC-only forced `LARGE` height and its trailing blank area.
- The official tintable Moonlight icon remains in the picker; the FAB row opens the reviewable add shell without using that entry as runtime capability evidence. The shell-only state is visible as `仅添加`, and runtime failure messages remain explicit and fail closed.

## Verification

- Exact `default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL` after the final UI/controller-isolation fix.
- Exact `assembleHap --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL`; signed HAP `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `296d60a2e264ec46dd3300099640ac65895d647b76362a829030e1e0a70a5b97`.
- That HAP was installed and started outside the sandbox on PC `127.0.0.1:5555` and phone `127.0.0.1:5557`.
- Fresh current-package evidence is `/private/tmp/moonlight-fab-final2-20260812/`: new PC/phone homepage and picker screenshots/UI trees, all viewed from the current HAP only; the picker tree records `仅添加` on both breakpoints.
- Visual acceptance confirms the separate entry gate, official tintable icon, explicit shell-only label, bounded candidate scroll, separated bottom actions, intrinsic PC sheet and unchanged homepage shell.
- Native focused rerun rebuilt the listener in the host test target and reported `701 passed, 16 failed, 717 total`; the 16 failures are the known existing local TLS fixture starts. The OHOS listener translation unit also passed an API 23 arm64 syntax check. `ohosTest` remains unavailable because task `00306054` is not registered.
- `CloudStore.ets` is the only intentional user-owned unstaged file and was not read for business changes, modified, staged or committed. No RDP/RustDesk/SSH/SFTP business file was changed.

## Next / blockers

- Next implementation boundary: complete S1-05A session-owned listener → N3-08 → N3-05 → N3-01 → common-c binding only after the runtime session port exists; keep controller capability and `moonlightProtocolAvailable` false until real-device receipts.
- Real Sunshine pairing/Host Control, catalog/launch, H.264/Opus first frame, OHAudio/Surface lifecycle, physical controller, network/thermal/long-run and user ARM64 evidence remain unproven; this is not a release-ready Moonlight streaming claim.
- `ohosTest` remains blocked at unregistered task `00306054`; compile registration and simulator UI are not device Hypium PASS.
- Moonlight cloud sync is intentionally parked; the user-owned cloud diff remains outside this task and is not staged or committed.
