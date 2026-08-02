# Shared Queue

Updated: 2026-08-03 Asia/Shanghai

## Now

- Request review for VNC V3 stage C first segment `36a8cbe57` (Sheet policy,
  lifecycle generation, action gate, and registered tests).
- Implement the next VNC V3 stage C segment: connect `RemoteDesktop` to the
  probe, Sheet lifecycle, password ordering, and one-shot pin handoff.
- Preserve stage A/B review receipts and keep probe/pin failures fail-closed.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Stage D: VNC trust v2, endpoint-owner migration, and the Data Security trust
  manager after the Sheet contract is stable.
- Stage E/F: VNC settings consistency and Repeater mode12 deep checks.

## Later

- Stage G real-device/direct/Repeater/cloud matrices; stage H independent
  closure and release records.
- Register or repair the `ohosTest` task before claiming ArkTS test execution.

## Queue Rules

- Keep one active branch and limit product edits to the VNC V3 plan scope.
- Do not mix RDP, RustDesk, SSH, renderer, or video-performance work into this
  VNC task.
- A missing device or endpoint blocks only the corresponding evidence, not
  static VNC policy work.
