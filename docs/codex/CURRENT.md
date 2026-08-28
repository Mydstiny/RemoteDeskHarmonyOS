# Shared Current State

## Active task

- Task: `system-clipboard-activation-fix`
- Branch/base: `codex/system-clipboard-activation-fix` from synchronized
  `main@181e79783`.
- Phase: review fixes are committed at `94be1858`; independent re-review is
  pending.
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
  authorization from either the initial prompt, RDP file paste or system
  settings enables local monitoring immediately without rebuilding the bridge.
- VNC view-only sessions now start the remote-to-local bridge before the first
  `ServerCutText` and never request local-read access.
- Invalid permission requests and ordinary exceptions are reported as
  unavailable without tearing down the remote-only bridge.
- Added focused policy coverage for pre-granted, newly granted, denied,
  invalid/unavailable and receive-only activation states.

## Review

- The first independent review found two P1 and two P2 issues: unsafe unknown
  error formatting, a send-only startup gate, invalid-result
  misclassification and no late-grant activation outside RDP file paste.
- All four findings are fixed in `94be1858`; the same reviewer must verify the
  updated checkpoint.

## Next

1. Obtain independent re-review of `94be1858`.
2. Validate a release-provisioned build on device without removing the existing
   application or clearing its data.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 8 s 624 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 15 s 905 ms`).
- Signed HAP manifest inspection: PASS; permission and both abilities present.
- Light open-source compliance: PASS.
- `git diff --check`: PASS.

## Blockers

- Device update is blocked because the installed package uses release
  provisioning while the local signed HAP uses debug provisioning (install
  error `9568286`). The existing app was not uninstalled and its data was not
  cleared.
