# System Clipboard Activation Fix Plan

## Goal

Make local text copied through the HarmonyOS system clipboard available to an
RDP, RustDesk or VNC session immediately after connection. A file transfer must
not be required to make text clipboard sync start working.

This plan is a follow-up task. Do not mix its implementation into the active
`secret-visibility-policy` branch.

## Working diagnosis

The new device observation is a state-transition clue:

1. The text bridge starts after the remote clipboard carrier is ready, but it
   reads `SystemPasteboard.getData()` without first establishing read access.
2. The RDP system-file paste path is the only remote-session path that checks
   and requests `READ_PASTEBOARD` before reading the pasteboard.
3. Text clipboard sync starts working after a file transfer.

The primary hypothesis is therefore a late local pasteboard authorization or
activation. The smaller alternative is that publishing an RDP file offer sends
the first effective CLIPRDR format list and wakes a carrier that was reported as
ready too early. One before/after trace must distinguish these; do not build two
fixes speculatively.

## Minimal implementation

1. **Identify the transition once**
   - On a fresh install/session, capture only: pasteboard permission state,
     `getData` outcome code, clipboard-bridge state, protocol carrier readiness,
     and CLIPRDR format-list result.
   - Record the same five facts before and immediately after the first file
     transfer. Do not log clipboard contents, file paths or endpoints.
   - If pasteboard access changes, execute step 2. If only CLIPRDR changes,
     execute step 3. If both change, execute both.

2. **Activate local pasteboard access before monitoring**
   - Use one shared read-access check for text sync and RDP system-file paste.
   - Request access once from the active `EntryAbility` or
     `RemoteSessionAbility`; on success, start/restart the local listener and
     perform one immediate baseline read.
   - Feed the result into session capabilities. A denied or unavailable read
     must show one short actionable reason instead of reporting a started
     bridge that always returns empty text.
   - Restore `READ_PASTEBOARD` only with the required ACL-enabled profile and
     declare both abilities. If that profile cannot be supplied, disable
     automatic local-to-remote sync truthfully and keep explicit file
     picker/drag transfer unchanged.

3. **Remove any RDP file-offer wake-up dependency, if observed**
   - Advertise `CF_UNICODETEXT` once when the live CLIPRDR channel becomes ready
     and again when accepted local text changes.
   - Propagate the format-list return value through NAPI so ArkTS can distinguish
     accepted, not-ready and failed. File publication must remain a separate
     format offer and must not be the text bridge initializer.

4. **Keep the patch narrow**
   - Primary files: `ClipboardBridgeService.ets`, `RemoteDesktop.ets`,
     `RemoteSessionCapabilityPolicy.ets` and `module.json5`.
   - Touch `extension_loader_napi.cpp`, `freerdp_adapter.cpp` and
     `rdp_file_clipboard_bridge.cpp` only if the trace confirms the CLIPRDR
     wake-up hypothesis.
   - Do not introduce a new permission framework, security subsystem, clipboard
     history, rich-text/image support, remote file download or protocol-wide
     refactor.

## Acceptance

1. Fresh install, no prior file transfer: copy plain text locally, connect, copy
   new text locally, and paste it remotely in RDP, RustDesk and VNC.
2. RDP text works before file picker, drag/drop or system-file paste is used.
3. Granting access after connection activates the bridge immediately without a
   reconnect; denial leaves the session usable and reports one concise reason.
4. RDP file picker, desktop drag/drop and system-file clipboard paste retain
   their current behavior; VNC still does not claim file transfer.
5. Remote-to-local text and anti-loop behavior remain intact across reconnect.
6. Focused policy/native tests cover the permission transition and, when
   applicable, text format-list publication. Then run the two exact Hvigor
   gates, `git diff --check`, Light compliance and one independent review. No
   additional broad security or release process is required for this patch.
