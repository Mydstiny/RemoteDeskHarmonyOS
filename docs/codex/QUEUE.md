# Shared Queue

Updated: 2026-08-03 Asia/Shanghai

## Now

- Checkpoint `28f8608f6` fixes RustDesk transient network reconnect,
  first-frame admission, stale-callback fencing, and cleanup continuity.
- Checkpoint `fa886f37d`/`763dc35d1` fixes RustDesk first-frame startup,
  authenticated-session restoration, and audio continuity.
- Checkpoint `f03c9b4ca` fixes VNC background retention and PIP renderer
  transfer/rebind, including raw framebuffer refresh and presented-frame gating.
- Preserve fail-closed VNC probe, trust, and Surface policies; no duplicate
  reviewer task is being created for the committed repair.
- Restore `hdc` connectivity and capture current VNC `hilog` when the device is
  available; do not convert static source evidence into device evidence.

## Next

- Stage G: restore hdc and collect real RustDesk/VNC direct/Repeater/device
  evidence; until then keep the evidence gap explicit.

## Later

- Stage G real-device/direct/Repeater/cloud matrices; stage H independent
  closure and release records.
- Register or repair the `ohosTest` task before claiming ArkTS test execution.

## Queue Rules

- Keep one active branch and limit product edits to the RustDesk/VNC repair
  scope.
- Do not mix RDP or SSH work into this task.
- A missing device or endpoint blocks only the corresponding evidence, not
  static VNC policy work.
