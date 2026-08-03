# Shared Queue

Updated: 2026-08-03 Asia/Shanghai

## Now

- Stage F checkpoint `f4f4760` passed the existing VNC-only reviewer:
  TCP reachability is separated from deep mode12/TLS/RFB protocol readiness,
  both policy runners are registered, and native mode12 handoff fixtures cover
  fragmented banner/250-byte pairing/RFB handoff and invalid-banner zero-write
  rejection.
- Preserve stage A/B and C-first review receipts; keep probe/pin failures
  fail-closed.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Continue only the planned native/endpoint deep-check integration before Stage G device matrices.

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
