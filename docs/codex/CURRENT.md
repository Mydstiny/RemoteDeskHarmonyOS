# Shared Current State

## Active task

- Task: `harmonyos-app-clone`
- Branch: `codex/system-clipboard-activation-fix`; the user explicitly
  authorized continuing this task in the existing worktree.
- Incremental base/code head: `8984f588e..0ca361a7`.
- Phase: implementation and independent review are complete; release-
  provisioned phone/tablet validation is pending.
- Plan: `docs/codex/plans/2026-08-28-harmonyos-app-clone.md`

## Objective

- Enable HarmonyOS system application cloning for one RemoteDesk clone on
  phone, tablet and 2in1 devices.
- Keep the main application behavior unchanged while the first clone release
  remains local-only and fail-closed for account, cloud and automatic
  clipboard integration.

## Implemented

- Declared `multiAppModeType: appClone` with `maxCount: 1`; packaged metadata
  confirms the declaration for phone, tablet and 2in1.
- Centralized `getCurrentAppCloneIndex()` behind `AppCloneContext`; index `0`
  preserves main-app policy, clone indices are local-only, and probe failures
  fail closed.
- The clone skips AGC Auth initialization and rejects Account Kit transitions,
  distributed-table registration, retries and manual/automatic cloud paths.
- Login and settings UI identify the clone as local-only, hide account/cloud
  actions and retain local backup/restore.
- Local backup/restore cancellation closes the clone sheet instead of exposing
  cloud actions.
- The clone disables RemoteDesk's complete bidirectional automatic clipboard
  bridge because SystemPasteboard is device-wide. User-driven system copy and
  paste still follows platform behavior.
- Added focused policy tests for index normalization, runtime-probe failure,
  account/cloud/clipboard guards and local-only sheet navigation.

## Review

- Initial independent review found one P1 and two P2 issues: device-wide
  clipboard relay, a local-sheet return path into cloud UI, and insufficient
  runtime/wiring tests.
- All three were fixed in `0ca361a7`. The same reviewer verified the cumulative
  scope `8984f588e..0ca361a7`: PASS, P0/P1/P2/P3 all zero.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 19 s 215 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 26 s 610 ms`), SHA-256
  `f8e0a1685c5793e295443b240a9d05c9555b7ec6e5d7e814c4d789e6e302fb71`.
- Packaged manifest inspection: PASS; `appClone`, `maxCount: 1`, phone, tablet
  and 2in1 are present.
- Light open-source compliance: PASS.
- `git diff --check`: PASS.
- Independent review: PASS at `0ca361a7`; P0/P1/P2/P3 all zero.

## Next

1. Install a release-provisioned HAP on one supported phone and one tablet.
2. Validate clone creation, upgrade, deletion, main uninstall behavior, local
   data isolation, remote-session concurrency and automatic clipboard denial.
3. Re-run the inherited system-clipboard release-device acceptance without
   removing the existing application or clearing its data.

## Blockers

- The project does not register an `ohosTest` module; focused test compilation
  fails with `00302018 Unknown module 'ohosTest'`. The suite is registered in
  `entry/src/test/List.test.ets` and compiles through the mandatory test gate.
- HDC could not connect to a usable target in this session.
- The installed device package uses release provisioning while the local HAP
  uses debug provisioning (`9568286`); the installed app and data were
  preserved. Release-provisioned phone/tablet acceptance remains required.
