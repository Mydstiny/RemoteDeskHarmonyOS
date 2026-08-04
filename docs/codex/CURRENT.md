# Shared Current State

This file is the compact startup resume card for the active SSH terminal task.

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `da4a2489f`
- Phase: SFTP checkpoint closed; SSH terminal diagnosis and core-route decision
- Scope: investigate terminal input stalls, IME/focus churn, command delivery,
  Canvas damage/frame errors and mature terminal-core migration. Homepage work
  is not the current focus.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters,
  ordered timestamp sampling, explicit queue/callback coverage and no per-key
  INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO, reserved control quota,
  generation checks, queue-full status, teardown admission gate, and paste
  chunking/retry queues.
- WP-T2 uses one SSH session-owner reactor for terminal input, reader, SFTP,
  command channels, signal/EOF, PTY resize and keepalive.
- Physical-keyboard/IME policy covers device-aware Unicode/CJK/emoji, CapsLock,
  AltGr, focus and duplicate-change suppression.
- WP-S0 SFTP integrity floor is implemented: zero-byte transfers, remote/local
  `.partial` staging, identity-bound resume, fsync/size verification, atomic
  commit and partial retention on cancel/failure.
- Current SFTP checkpoint adds bounded durable task metadata, ordered/coalesced
  persistence, restore/pause/resume/cancel/detach transitions, capability-aware
  local-provider selection, folder authorization and remote/local file views.
- Local provider now keeps the persisted Picker URI separate from the FileIO
  path; API 23 directory listing and child operations use the authorized path.
- Pad/PC SFTP uses a full-screen in-page workspace; `sm` keeps the original
  bottom Sheet and original virtual-key-bar behavior. Input-device mode is
  scoped to Pad/PC.
- Wide Pad/PC SFTP now keeps remote navigation, path jump, rename and remote
  actions in the left column; local authorization, listing and upload actions
  remain in the right column.
- The SFTP checkpoint is closed for the implemented integrity, task metadata,
  local-provider and Pad/PC workspace scope. It is not a complete background
  transfer engine: payload execution remains page-owned and real provider/
  endpoint acceptance is pending.

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
- Host native tests: `253 passed, 16 failed, 269 total`; all failures are the
  existing VNC TLS fixture startup failures; SSH diagnostics/queue tests pass.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib
  --no-default-features`: `156 passed, 1 failed, 157 total`; the remaining
  failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed on 2026-08-04, warnings only.
- `assembleHap`: passed on 2026-08-04 with `BUILD SUCCESSFUL` and signing.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- HDC: target `5KLBB25928203528` is connected; homepage UI was installed and
  checked on the 2560x1600 device. Terminal latency/IME/rendering and SFTP
  provider acceptance still need the dedicated device matrix.

## Review

- The current SSH/SFTP code delta is checkpointed by build and policy tests but
  has no independent reviewer PASS yet; current code scope therefore remains
  `REVIEW_REQUIRED`.
- The SFTP checkpoint is scope-complete for this pass, but its real-device and
  endpoint evidence is not a completion claim for Level A.
- No device, bastion, forwarding or FRP PASS is claimed.

## Next

1. Capture a terminal pipeline timeline and reproduce input, IME, command and
   Canvas failures with the existing diagnostics hooks.
2. Build the WP-T4 terminal-core spike/ADR comparison using shared VT, Unicode,
   resize, TUI and large-output fixtures.
3. Keep ProxyJump, forwarding and FRP disabled until contracts and endpoints
   exist; implement them as a separate Level B task.
4. Re-run device and remote-endpoint acceptance when the terminal fixtures and
   corresponding test services exist.

## Blockers

- HDC is connected and homepage evidence is available; terminal latency,
  keyboard/IME, Canvas and SFTP lifecycle/provider acceptance remains pending.
- No real OpenSSH bastion/ProxyJump, forwarding or FRP endpoint is available.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Host native suite has 16 pre-existing VNC TLS fixture startup failures.
- Light open-source compliance is blocked by the baseline SBOM `NOASSERTION`.
