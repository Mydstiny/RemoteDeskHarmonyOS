# Shared Queue

Updated: 2026-08-03 Asia/Shanghai

## Now

- Checkpoint `d48c12471` implements the user-authorized RDP P0 TLS preflight
  repair: complete TPKT reads, negotiation classification, stable TLS errors,
  and native parser coverage. It does not add Gateway or legacy fallback.
- Checkpoint `6a4b35d1f` adds the mobile/Pad RustDesk keyboard-mouse edge rail,
  hide/wake handle, and serialized system-bar transitions.
- Commit `410a6a0` restores the real 1.0.8 PIP order: foreground controller
  preparation, system auto-start, presented-frame-gated renderer transfer, and
  terminal-state foreground rebind.
- Checkpoint `d29e754db` fixes PIP operation races, renderer/PIP session
  continuity, and temporary TOTP selection in RustDesk authentication.
- Checkpoint `28f8608f6` fixes RustDesk transient network reconnect,
  first-frame admission, stale-callback fencing, and cleanup continuity.
- Checkpoint `fa886f37d`/`763dc35d1` fixes RustDesk first-frame startup,
  authenticated-session restoration, and audio continuity.
- Checkpoint `f03c9b4ca` fixes VNC background retention and PIP renderer
  transfer/rebind, including raw framebuffer refresh and presented-frame gating.
- Preserve fail-closed VNC probe, trust, and Surface policies; no duplicate
  reviewer task is being created for the committed repair.
- Restore `hdc` connectivity and capture current RustDesk/VNC `hilog` when the
  device is available; do not convert static source evidence into device
  evidence.

## Next

- Stage G: restore hdc and collect real RustDesk/VNC direct/Repeater/device
  evidence; until then keep the evidence gap explicit.
- Collect one real bastion endpoint with its port, Gateway/vendor mode, and a
  same-network Windows mstsc result before starting RDP P1.

## Later

- Stage G real-device/direct/Repeater/cloud matrices; stage H independent
  closure and release records.
- Register or repair the `ohosTest` task before claiming ArkTS test execution.

## Queue Rules

- Keep one active branch. RDP P0 is the explicit user-authorized exception;
  do not silently expand it into Gateway, vendor proxy, or legacy TLS support.
- Do not mix additional RDP P1/P2/P3 or SSH work into this checkpoint.
- A missing device or endpoint blocks only the corresponding evidence, not
  static VNC policy work.
