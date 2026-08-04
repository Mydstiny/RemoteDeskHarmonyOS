# Shared Current State

This file is the compact startup resume card for the active SSH terminal task.

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `e51e371` (bounded output/frame consumption on Alacritty/lifecycle/VT parity).
- Phase: Alacritty default; lifecycle, VT/Unicode/resize/TUI/large-output parity, damage checks and available device acceptance pass.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, and
  verify IME/input/Canvas behavior. Homepage work is not current focus.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters,
  ordered sampling, queue/callback coverage and no per-key INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO/control quota,
  generation checks, queue-full status, teardown gate and paste retry queues.
- WP-T2 uses one SSH session-owner reactor for terminal input, reader, SFTP,
  command channels, signal/EOF, PTY resize and keepalive.
- Physical-keyboard/IME policy covers device-aware Unicode/CJK/emoji, CapsLock, AltGr, focus and duplicate-change suppression.
- WP-S0 SFTP integrity floor is implemented: zero-byte transfers, `.partial`
  staging, identity-bound resume, fsync/size verification and atomic commit.
- Current SFTP checkpoint adds durable task metadata, lifecycle transitions,
  capability-aware provider selection, authorization and file views.
- Local provider separates persisted Picker URI from FileIO path; API 23 child
  operations use the authorized path.
- Pad/PC SFTP uses a full-screen in-page workspace; `sm` keeps the original
  bottom Sheet and original virtual-key-bar behavior. Input-device mode is
  scoped to Pad/PC.
- Wide Pad/PC SFTP keeps remote navigation/path jump/rename/actions left and
  local authorization/listing/upload actions right.
- The SFTP checkpoint is closed for integrity, task metadata, local-provider
  and Pad/PC workspace; background payload execution remains page-owned and
  real provider/endpoint acceptance is pending.
- WP-T4 first migration slice is implemented: `alacritty_terminal` `0.26.0` is
  default behind terminalCore; the old Rust core remains a no-default fallback.
- `sshTerminalForegroundColor` is ARGB through NAPI; ANSI colors remain independent, and font size stays in Canvas for cell geometry.
- The SSH owner reactor now sends bounded non-blocking libssh2 keepalives and
  retries transient failures without taking a second session owner.
- SSH background continuity and custom PiP ownership are isolated from the
  RDP/RustDesk/VNC services; teardown is serialized on foreground/Ability exit.
- PiP auto-start now requires an explicitly prepared/preparing PiP session, and
  SSH becomes connected only after the callback and detached-session resume gate
  are installed.
- Terminal output is capped at 256 KiB per page/Canvas turn; oversized chunks
  preserve their ordered remainder, and reused Canvas surfaces are re-probed.
- Terminal input-buffer tests cover bounded draining and byte-contiguous splits
  across an oversized callback.
- SBOM, NOTICE and third-party scope now include Alacritty and its locked
  transitive crates.

## Homepage Follow-on

- With RustDesk online monitoring disabled, classic and grouped home cards omit
  presence status text and empty status separators; ordinary relay hosts also
  omit the default `中继` badge while Pro/direct labels remain.
- The signed HAP was installed to HDC target `5KLBB25928203528`; a 2560x1600
  real-device screenshot confirms the classic homepage result.

## SSH Connectivity Boundary

- Native SSH currently supports `direct`, `http_connect` and `socks5`.
- Legacy generic gateway fields fail closed; they are never silently converted
  into a direct SSH connection.
- SSH ProxyJump/bastion multi-hop, local/remote/dynamic forwarding, FRP
  `frp_tcp`, Visitor/STCP/SUDP/XTCP and real endpoint interoperability are not
  implemented in this checkpoint.

## Verification

- `git diff --check`: passed on 2026-08-05.
- Host native tests: `254 passed, 16 failed, 270 total`; all failures are the
  existing VNC TLS fixture startup failures; the keepalive/SSH diagnostics
  tests pass.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib
  --no-default-features`: `156 passed, 1 failed, 157 total`; the remaining
  failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed for `e51e371` on 2026-08-05, warnings
  only.
- `assembleHap`: passed for `e51e371` on 2026-08-05 with `BUILD SUCCESSFUL`
  and signing.
- Terminal-core Rust tests: Alacritty path `63 passed, 0 failed`; fallback
  path `57 passed, 0 failed`.
- OHOS Rust checks: `aarch64-unknown-linux-ohos` and
  `x86_64-unknown-linux-ohos` passed with the Alacritty feature.
- Terminal parity: Alacritty `67 passed`, fallback `57 passed`; shared
  Unicode/ANSI, TUI/alternate-screen, resize/large-output and damage fixtures
  match on visible cells and required metadata.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- HDC target `5KLBB25928203528`: cold SSH connected, `yes A | head -c
  300000; echo LARGE_OK` completed, Home showed the retained SSH session, the
  app re-entered the same terminal/PiP state, and `echo RESUMED_OK` executed.

## Review

- The existing independent reviewer passed the final bounded-output increment;
  the committed scope now matches the PASS receipt and can skip full review.
- The SFTP checkpoint is scope-complete for this pass, but its real-device and
  endpoint evidence is not a completion claim for Level A.
- Device evidence covers injected input and the available lifecycle path; true
  external-keyboard/third-party-IME coverage and all bastion/forwarding/FRP
  endpoint evidence remain open.

## Next

1. User-accept IME/physical-keyboard behavior on the signed `e51e371` HAP.
2. Keep ProxyJump, forwarding and FRP disabled until contracts and real
   endpoints exist; implement them as a separate Level B task.

## Blockers

- Full external-keyboard/third-party-IME and SFTP lifecycle/provider acceptance
  remains pending; cold/large-output/background/PiP/re-entry checks passed.
- No real OpenSSH bastion/ProxyJump, forwarding or FRP endpoint is available.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
