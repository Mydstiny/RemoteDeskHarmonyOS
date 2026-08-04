# Shared Current State

This file is the compact startup resume card for the active SSH-only task.

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- HEAD: `1976c4aeb` plus uncommitted WP-T0-T3/WP-S0 changes
- Phase: SSH-only self-review checkpoint after WP-S0 integrity floor
- Scope: SSH terminal input/diagnostics/N-API/ArkTS only; RDP, RustDesk, VNC,
  CloudStore and TOTP owners are out of scope.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters,
  ordered timestamp sampling, explicit queue/callback coverage and no per-key
  INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO (256 items/256 KiB),
  reserved control quota (64 items/16 KiB), generation checks, queue-full
  status, teardown admission gate, and paste chunking/ArkTS retry queues.
- WP-T2 working tree now has one session owner reactor: terminal input, reader,
  SFTP, command channels, signal/EOF, PTY resize and keepalive all route through
  one command queue; resize is coalesced and input is drained between 50 ms
  network slices. The legacy read path is non-blocking and no input writer
  thread remains.
- Physical-keyboard/IME policy is in the declared SSH scope: device-aware
  Unicode/CJK/emoji, CapsLock/AltGr, focus and duplicate-change suppression.
- WP-S0 SFTP integrity floor is implemented: 0B upload/download, remote/local
  `.partial` staging, identity-bound resume, fsync/size verification, atomic
  commit and explicit partial retention on cancel/failure. Zero-byte uploads
  explicitly create the remote partial before rename.
- WP-S1 metadata foundation is implemented: bounded SSH-only Task Store,
  mutation-versioned/coalesced durable writes, and fail-closed unknown-size
  records. It is not the complete background task engine or provider layer.

## Verification

- `git diff --check`: passed after the latest fixes.
- Host native tests: `253 passed, 16 failed, 269 total`; all failures are the
  existing VNC TLS fixture startup failures; SSH diagnostics and queue policy
  tests pass.
- `default@OhosTestCompileArkTS`: passed after WP-S0 fixes on 2026-08-04
  (warnings only).
- `assembleHap`: passed after WP-S0 fixes on 2026-08-04 (`BUILD SUCCESSFUL`,
  native Ninja rebuilt).
- HDC: no device currently listed; no physical keyboard, Pad SFTP or PC drag
  evidence is available yet.

## Review

- Review mode: user-authorized self-review in the primary session; the
  independent review session and child agent are stopped and will not be used.
- Self-review covered input ordering/IME/focus, generation guards, TSFN/reader
  teardown, output backpressure, SFTP path/URI/partial identity, cancel/commit
  races, Task Store unknown-size handling and serialized flushes.
- No device PASS is claimed: HDC is unavailable and `ohosTest` is unregistered.

## Next

1. Commit the SSH-only checkpoint after the current self-review and mandatory
   build gates.
2. Hand WP-S1/S2 durable transfer tasks and capability-aware local providers to
   the next session.
3. Hand WP-S3/S4 Pad/PC dual-pane workspace and UDMF drag/drop to the next
   session.
4. Restore HDC and run the Phone/Pad/PC SSH/SFTP acceptance matrix in a later
   session.

## Blockers

- No HDC target is connected, so real-device latency, focus, orientation,
  lifecycle, Pad layout and PC/2in1 drag/drop remain unverified.
- `ohosTest@OhosTestCompileArkTS` is not registered in this project; native and
  default ArkTS compile/build evidence is available instead.
- A real OpenSSH bastion/ProxyJump and forwarding endpoint is not available;
  those Level B capabilities remain planned/gated and are not enabled here.
