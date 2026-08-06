# Shared Current State

## Active Task
- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `a09e267` (`fix(ssh): publish renderer and FRP types`), following `d374a610f` (`fix(ssh): harden surface and forwarding failures`); keyed surface recovery, forwarding lifecycle, adapter reactor binding, and the generation-guarded NAPI/ArkTS bridge are committed.
- Phase: Alacritty core and xterm-safe visible fallback; lifecycle, VT/Unicode/resize/TUI/large-output parity, per-host output isolation, code-only host-switch/surface refresh recovery, guarded surface fallback, and native forwarding contract.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, verify IME/input/Canvas behavior. Homepage work is not current focus.

## Progress

- WP-T0/T1/T2 are implemented: diagnostics, bounded native input, one SSH
  session-owner reactor, PTY resize, SFTP and keepalive share generation and
  teardown rules. Physical-keyboard/IME policy covers Unicode/CJK/emoji,
  CapsLock, AltGr, focus and duplicate-change suppression.
- SFTP integrity, durable task metadata, capability-aware provider selection,
  API 23 authorized local-provider operations and the Pad/PC full-screen workspace
  are implemented; background payload execution and endpoint acceptance remain pending.
- The SSH native forwarding lifecycle contract validates local/remote/dynamic
  profiles, loopback/public binding policy, bounded connections, generations and
  start/listen/fail/stop transitions. `SshAdapter` now owns the manager and
  dispatches runtime transitions through the session-owner reactor, including
  transport teardown reset. NAPI/ArkTS now exposes configure/remove/start/
  listen/fail/stop/acquire/release/snapshot with explicit SSH, lifecycle and
  generation gates; real libssh2 socket/channel forwarding is still open.
- Dynamic SOCKS5 rejects unsupported methods, commands and address types with
  standard failure replies, flushes the reply before closing, and protects
  handshake buffers from allocation failure. Local/remote listener errors now
  enter `Failed` and clean runtime state; stale stop completion is rejected by
  session generation. FRP Visitor/STCP/SUDP/XTCP are explicit routes that fail
  closed until their control plane exists; they are never downgraded to TCP.
- WP-T4 uses `alacritty_terminal` `0.26.0` by default behind terminalCore,
  with the old core as a no-default fallback and bounded xterm fallback.
  Appearance settings remain in-core; ARGB foreground, ANSI colors and Canvas
  cell geometry are kept independent. Output is capped at 256 KiB per turn and
  oversized chunks retain ordered remainder. SBOM/NOTICE include Alacritty.
- SSH background/PiP ownership is isolated from other protocols, teardown is
  serialized, and PiP auto-start requires prepared callback/resume gates.
  ProxyJump has a native `ssh_jump` route and bounded bastion relay, pending
  host-key binding and real endpoint acceptance.
- Same-page switching rejects stale async connect/attach/data/PiP callbacks,
  cancels pending handshakes and retains detach-race output per host. The
  top-tab switch stays inside one persistent SSH page, serializes the binding
  handoff, detaches only the old session callback and adopts the retained target
  session, so a second host can refresh without dropping either SSH socket.
- The terminal surface has an explicit detach/rebind gate. A deterministic
  host/binding/revision key removes stale XComponent/WebView instances; native
  owner leases and renderer view IDs reject stale owners, while xterm documents
  use isolated bridges and transcript fallback.
- GPU rebind, owner leases, refresh fences, surface-ID polling and retained
  snapshots are implemented, but the 2026-08-06 API 23 reproduction proved
  that `OH_Drawing_SurfaceFlush` can escalate `41207000` into a process-wide
  `SIGABRT` before ArkTS can handle it. The visible SSH page now stays on the
  mature xterm.js surface; the native VT/GPU implementation remains retained
  for a later safe backend.

## SSH Connectivity Boundary

- Native SSH currently supports `direct`, `http_connect`, `socks5`, raw
  `frp_tcp` and the new `ssh_jump` route slice. `frp_visitor`, `frp_stcp`,
  `frp_sudp` and `frp_xtcp` are recognized and fail closed with the explicit
  unsupported-route error until a FRP control-plane implementation is added.
- Legacy generic gateway fields fail closed; they are never silently converted
  into a direct SSH connection.
- SSH ProxyJump/bastion has a native route and matching key preflight relay,
  but real bastion interoperability and host-key binding remain pending.
  Local/remote/dynamic forwarding has a native lifecycle contract, guarded
  adapter reactor entry, listener failure cleanup and NAPI/ArkTS state bridge;
  real libssh2 socket/channel integration is open. ProxyJump host-key binding
  and FRP Visitor/STCP/SUDP/XTCP control-plane integration remain open.

## Verification

- `git diff --check`: passed for the current SSH/forwarding/FRP increment on 2026-08-06.
- Host native tests: `273 passed, 16 failed, 289 total`; all failures are the
  existing VNC TLS fixture startup failures; SSH route, forwarding manager and
  terminal diagnostics tests pass. `cmake` is absent; the existing Makefile
  target rebuilt successfully before execution.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib --no-default-features`:
  `156 passed, 1 failed, 157 total`; the remaining failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed on the current checkout on 2026-08-06;
  warnings only.
- `assembleHap`: passed on the current checkout with `BUILD SUCCESSFUL`, native
  Ninja compilation, packaging and signing on 2026-08-06.
- HDC reproduction: SSH TCP/KEX/public-key auth/PTY/shell all completed; the
  crash was `DrawSnapshot -> OH_Drawing_SurfaceFlush -> Device lost -> SIGABRT`
  on PID 18229 at 2026-08-06 17:36:30. The old `log.rtf` shows the same stack.
- Terminal-core Rust tests: Alacritty path `63 passed, 0 failed`; fallback
  path `57 passed, 0 failed`.
- OHOS Rust checks: `aarch64-unknown-linux-ohos` and
  `x86_64-unknown-linux-ohos` passed with the Alacritty feature.
- Terminal parity: Alacritty `67 passed`, fallback `57 passed`; shared
  Unicode/ANSI, TUI/alternate-screen, resize/large-output and damage fixtures
  match on visible cells and required metadata.
- Native forwarding manager tests are included in the host run and pass; the
  standalone target also rebuilt through Makefiles. Host CMake is unavailable
  because `cmake` is not installed; production Ninja compilation passed.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.

## Review
- Existing independent review passed the bounded-output and IME/socket increments. The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment also passed with no P0/P1/P2 findings; receipt `ssh-terminal-surface-forwarding-frp-pass-2026-08-06` is recorded. The status command remains `REVIEW_REQUIRED` only because preserved user RDP diagnostic hunks keep mixed `protocol_adapter.h` and `HostListPage.ets` dirty.
- SFTP scope is closed for this pass; real-device/endpoint evidence is not a Level A completion claim.
- Device evidence covers injected input and lifecycle; external keyboard/IME, GPU re-enable, bastion/forwarding/FRP evidence remain open.

## Next
1. Add real local/remote/dynamic libssh2 socket/channel transport, then finish
   ProxyJump host-key binding and FRP Visitor/STCP/SUDP/XTCP control-plane contracts.

## Blockers

- Full external-keyboard/third-party-IME and SFTP lifecycle acceptance remains pending; cold/large-output/background/PiP/re-entry and 90-second idle checks passed.
- Native GPU re-enable is blocked until a backend that cannot abort on a stale
  API 23 BufferQueue is available. No real OpenSSH bastion, forwarding or FRP
  endpoint is available; ProxyJump host-key binding and
  `ohosTest@OhosTestCompileArkTS` (`00306054`) remain pending.
