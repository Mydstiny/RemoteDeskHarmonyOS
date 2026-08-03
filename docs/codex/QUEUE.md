# Shared Queue

Updated: 2026-08-03 Asia/Shanghai

## Now

- Stage E checkpoint `68f5253` passed the existing VNC-only reviewer: both
  settings surfaces validate current-account mode12 defaults and cleanup gates
  Gateway deletion/disable.
- Preserve stage A/B and C-first review receipts; keep probe/pin failures
  fail-closed.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Stage F: distinguish Gateway TCP reachability from deep mode12/TLS/RFB
  health, reusing the endpoint resolver and certificate Sheet.

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
