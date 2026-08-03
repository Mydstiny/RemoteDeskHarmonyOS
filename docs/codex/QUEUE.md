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
- Checkpoint `ef4c33a` fences deep-check Promise results by requestId and
  attempt generation, binds Repeater target changes, revalidates pending trust
  against the live endpoint, and preserves all stable VNC certificate errors.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Request the one existing reviewer task once to audit checkpoint `ef4c33a`; do
  not advance to Stage G or start FreeRDP before its result.

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
