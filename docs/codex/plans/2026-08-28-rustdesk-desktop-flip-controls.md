# RustDesk desktop flip controls

## Objective

Add a PC-only RustDesk top-bar flip icon. Clicking it opens a compact popup with
three actions: flip image only, flip image and control layer, and reset. Persist
the choice per host for later sessions.

## Scope

- Reuse the existing top-bar icon button and popup visual system.
- Keep visual and control rotations independent so the workaround supports both
  known failure modes without changing the native decode orientation contract.
- Restore the mode on connection, renderer rebind and PIP transfer.
- Store the mode in device-local host personalization and portable local backup;
  do not classify it as a cloud-base host mutation.
- Exclude Phone/Pad viewers and runtime RustDesk phone peers. Authenticated peer
  platform wins over stale host metadata, and transient reconnect `unknown`
  diagnostics retain the last authenticated platform within the same session.
- Add focused tests for mode normalization, mapping, layout isolation,
  persistence, backup and peer-platform transitions.

## Verification

- `default@OhosTestCompileArkTS`
- signed `assembleHap`
- `git diff --check`
- Light open-source compliance
- independent read-only review
- HarmonyOS PC real-device acceptance remains a delivery follow-up
