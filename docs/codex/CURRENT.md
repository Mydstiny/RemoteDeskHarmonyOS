# Shared Current State

This file is the compact startup resume card for the active SSH terminal task.

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `8e6326aab` (Alacritty and SSH lifecycle checkpoint committed)
- Phase: Alacritty is default; reactor keepalive/background lifecycle are
  checkpointed, with review and the full device matrix pending.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, and
  verify IME/input/Canvas behavior. Homepage work is not current focus.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters,
  ordered sampling, queue/callback coverage and no per-key INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO/control quota,
  generation checks, queue-full status, teardown gate and paste retry queues.
- WP-T2 uses one SSH session-owner reactor for terminal input, reader, SFTP,
  command channels, signal/EOF, PTY resize and keepalive.
- Physical-keyboard/IME policy covers device-aware Unicode/CJK/emoji, CapsLock,
  AltGr, focus and duplicate-change suppression.
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
- The SFTP checkpoint is closed for the implemented integrity, task metadata,
  local-provider and Pad/PC workspace scope. It is not a complete background
  transfer engine: payload execution remains page-owned and real provider/
  endpoint acceptance is pending.
- WP-T4 first migration slice is implemented: `alacritty_terminal` `0.26.0` is
  default behind terminalCore; the old Rust core remains a no-default fallback.
- `sshTerminalForegroundColor` is converted to ARGB in ArkTS and applied
  through NAPI into the core; explicit ANSI colors remain independent. Font
  size stays in the Canvas renderer because it controls cell geometry.
- The SSH owner reactor now sends bounded non-blocking libssh2 keepalives and
  retries transient failures without taking a second session owner.
- SSH background continuity and custom PiP ownership are isolated from the
  RDP/RustDesk/VNC services; teardown is serialized on foreground/Ability exit.
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

- `git diff --check`: passed on 2026-08-04.
- Host native tests: `254 passed, 16 failed, 270 total`; all failures are the
  existing VNC TLS fixture startup failures; the keepalive/SSH diagnostics
  tests pass.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib
  --no-default-features`: `156 passed, 1 failed, 157 total`; the remaining
  failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed after the lifecycle checkpoint on
  2026-08-04, warnings only.
- `assembleHap`: passed after the lifecycle checkpoint on 2026-08-04 with
  `BUILD SUCCESSFUL` and signing.
- Terminal-core Rust tests: Alacritty path `63 passed, 0 failed`; fallback
  path `57 passed, 0 failed`.
- OHOS Rust checks: `aarch64-unknown-linux-ohos` and
  `x86_64-unknown-linux-ohos` passed with the Alacritty feature.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- HDC target `5KLBB25928203528` is connected; direct SSH input, keepalive,
  large output, background/foreground return and Canvas rendering were checked
  on device. Full IME/physical-keyboard, PiP/background-task and SFTP provider
  matrices still need dedicated acceptance.

## Review

- The current SSH/SFTP code delta is checkpointed by build and policy tests but
  has no independent reviewer PASS yet; current code scope therefore remains
  `REVIEW_REQUIRED`.
- The SFTP checkpoint is scope-complete for this pass, but its real-device and
  endpoint evidence is not a completion claim for Level A.
- No device, bastion, forwarding or FRP PASS is claimed.

## Next

1. Run shared VT/Unicode/resize/TUI/large-output fixtures through the default
   Alacritty C ABI and compare snapshots/damage with the old core.
2. Capture a terminal pipeline timeline and reproduce input, IME, command and
   Canvas failures with the existing diagnostics hooks.
3. Keep ProxyJump, forwarding and FRP disabled until contracts and endpoints
   exist; implement them as a separate Level B task.
4. Re-run device and remote-endpoint acceptance when the terminal fixtures and
   corresponding test services exist.

## Blockers

- Full IME/physical-keyboard, PiP/background-task and SFTP lifecycle/provider
  acceptance remains pending; basic terminal device checks have passed.
- No real OpenSSH bastion/ProxyJump, forwarding or FRP endpoint is available.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
