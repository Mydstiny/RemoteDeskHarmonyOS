# Shared Current State

## Active task

- Task: `system-clipboard-activation-fix`
- Branch/base: `codex/system-clipboard-activation-fix` from synchronized
  `main@181e79783`.
- Phase: implementation and local validation complete; ready for checkpoint
  commit and independent review.
- Plan: `docs/codex/plans/2026-08-28-system-clipboard-activation-fix.md`

## Objective

- Make local HarmonyOS system-clipboard text available to RDP, RustDesk and
  VNC immediately after connection, without requiring a prior file transfer.
- Preserve current RDP file picker, drag/drop and system-file paste behavior.

## Baseline

- Clean synchronized `main@181e79783`, equal to `origin/main` when started.
- Two unrelated untracked plan documents are present and excluded from this
  task: `2026-08-28-harmonyos-app-clone.md` and
  `2026-08-28-rustdesk-mobile-display-input-quick-optimization.md`.

## Confirmed diagnosis

- API 23 requires `READ_PASTEBOARD` for both `getData()` and
  `getUnifiedData()`, while the installed 1.1.3 package did not request it.
- The text bridge converted permission error 201 to empty text, but RDP system
  file paste was the only path that attempted a late permission request.
- RDP already advertises `CF_UNICODETEXT` at `MONITOR_READY` and on accepted
  local text changes, so no native CLIPRDR wake-up change is needed.
- The current debug provisioning profile already contains the required
  `READ_PASTEBOARD` ACL.

## Implemented

- Restored the manifest permission for both `EntryAbility` and
  `RemoteSessionAbility`.
- Added one shared read-access request used by text sync and RDP system-file
  paste.
- The session bridge requests access before local monitoring, establishes a
  baseline immediately after grant, and reports denial/unavailability instead
  of silently reading empty text.
- Permission denial keeps the remote-to-local poll active. A later successful
  RDP file-paste authorization enables local monitoring immediately without
  rebuilding the bridge.
- Added focused policy coverage for pre-granted, newly granted, denied and
  unavailable permission states.

## Next

1. Create the checkpoint commit and obtain independent review.
2. Validate a release-provisioned build on device without removing the existing
   application or clearing its data.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 9 s 662 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 17 s 382 ms`).
- Signed HAP manifest inspection: PASS; permission and both abilities present.
- Light open-source compliance: PASS.
- `git diff --check`: PASS.

## Blockers

- Device update is blocked because the installed package uses release
  provisioning while the local signed HAP uses debug provisioning (install
  error `9568286`). The existing app was not uninstalled and its data was not
  cleared.
