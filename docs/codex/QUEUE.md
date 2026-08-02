# Shared Queue

Updated: 2026-08-02 Asia/Shanghai

## Now

- Stage D manager endpoint/migration segment `fc9daa13f` passed the single
  independent incremental review. Continue with endpoint deletion/rotation
  invalidation and backup/cloud wording within VNC-only scope.
- Preserve stage A/B and C-first review receipts; keep probe/pin failures
  fail-closed.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Stage D follow-up: backup/cloud wording and endpoint deletion/rotation
  invalidation, then request the same reviewer once for the increment.
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
