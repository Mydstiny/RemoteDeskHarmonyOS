# Shared Current State

## Active Task
- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `d72c84d` (`fix(ssh): refresh retained host surface on route switch`); the current same-page binding-commit and synchronous GPU lease-detach correction is the next checkpoint.
- Phase: Alacritty default; lifecycle, VT/Unicode/resize/TUI/large-output parity, per-host output isolation and code-only host-switch/surface refresh recovery.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, verify IME/input/Canvas behavior. Homepage work is not current focus.

## Progress

- WP-T0/T1/T2 are implemented: diagnostics, bounded native input, one SSH
  session-owner reactor, PTY resize, SFTP and keepalive share generation and
  teardown rules. Physical-keyboard/IME policy covers Unicode/CJK/emoji,
  CapsLock, AltGr, focus and duplicate-change suppression.
- SFTP integrity, durable task metadata, capability-aware provider selection,
  API 23 authorized local-provider operations and the Pad/PC full-screen
  workspace are implemented. Remote actions stay left and local authorization
  and file actions stay right; background payload execution and endpoint
  acceptance remain pending.
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
- GPU rebind restores EGL context, refreshes retained snapshots, acknowledges
  surface-flush failures, polls surface IDs when API 23 skips callbacks, uses
  measured size for the first bind, and invalidates retries on host/revision
  changes. Adopted sessions with transient `CONNECTING` stay visible and wake
  mount retry synchronously. A monotonic surface-commit sequence now drives the
  ArkUI renderer-list identity, and host/surface/revision prop changes detach
  the old GPU lease synchronously before the new bind is scheduled.

## SSH Connectivity Boundary

- Native SSH currently supports `direct`, `http_connect`, `socks5`, raw
  `frp_tcp` and the new `ssh_jump` route slice.
- Legacy generic gateway fields fail closed; they are never silently converted
  into a direct SSH connection.
- SSH ProxyJump/bastion has a native route and matching key preflight relay,
  but real bastion interoperability and host-key binding remain pending.
  Local/remote/dynamic forwarding and FRP Visitor/STCP/SUDP/XTCP remain open.

## Verification

- `git diff --check`: passed after the deterministic keyed-remount correction on 2026-08-06.
- Host native tests: `254 passed, 16 failed, 270 total`; all failures are the
  existing VNC TLS fixture startup failures; the keepalive/SSH diagnostics
  tests pass.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib
  --no-default-features`: `156 passed, 1 failed, 157 total`; the remaining
  failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed for the host-switch surface refresh,
  transient-`CONNECTING` mount wake, deterministic keyed remount,
  revision-aware renderer owner/document correction, explicit surface-commit
  sequence, and synchronous GPU lease detach on 2026-08-06; warnings only.
- `assembleHap`: the same code-only correction passed with `BUILD SUCCESSFUL`
  and signing on 2026-08-06.
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

## Review

- Existing independent review passed the bounded-output and IME/socket increments; checkpoint `ffa0f9e` plus the current keyed-surface, mount-wake, deterministic keyed remount, renderer-owner lease, revision-aware document, and GPU refresh owner-lease correction remains `REVIEW_REQUIRED` until review.
- SFTP scope is closed for this pass; real-device/endpoint evidence is not a Level A completion claim.
- Device evidence covers injected input and lifecycle; external keyboard/IME, GPU re-enable, bastion/forwarding/FRP evidence remain open.

## Next

1. Independently review the same-page SSH binding commit, initial-UI surface-owner, fallback, deterministic keyed remount, renderer-owner lease, revision-aware document, GPU binding lease, and EGL refresh scope.
2. Verify ProxyJump against a real OpenSSH bastion and bind its host key.
3. Add SSH-scoped local/remote/dynamic forwarding and FRP visitor modes.

## Blockers

- Full external-keyboard/third-party-IME and SFTP lifecycle/provider acceptance
  remains pending; cold/large-output/background/PiP/re-entry and 90-second idle
  checks passed.
- Real-device validation for the current initial-UI/host-switch/native-renderer
  pass is intentionally deferred by the user; only code-level gates were requested.
- No real OpenSSH bastion, forwarding service or FRP endpoint is available; HDC is offline; ProxyJump host-key binding and `ohosTest@OhosTestCompileArkTS` (`00306054`) remain pending.
