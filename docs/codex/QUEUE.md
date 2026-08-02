# Shared Queue

Updated: 2026-08-02 Asia/Shanghai

## Now

- Stage D implementation checkpoint `cc87e9aae` is ready for the single
  independent incremental review: trust-v2 metadata, v1 candidate migration,
  physical-store-bound markers, and the unified certificate manager.
- Preserve stage A/B and C-first review receipts; keep probe/pin failures
  fail-closed.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Stage D follow-up: backup/cloud wording and endpoint deletion/rotation
  invalidation after the manager review passes.
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
