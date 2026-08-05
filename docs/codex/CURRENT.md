# Shared Current State

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `ffa0f9e` (`fix(ssh): recover host surface refresh`).
- Phase: Alacritty default; lifecycle, VT/Unicode/resize/TUI/large-output parity, per-host output isolation and code-only host-switch/surface refresh recovery.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, verify IME/input/Canvas behavior. Homepage work is not current focus.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters, ordered sampling, queue/callback coverage and no per-key INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO/control quota, generation checks, queue-full status, teardown gate and paste retry queues.
- WP-T2 uses one SSH session-owner reactor for terminal input, reader, SFTP, command channels, signal/EOF, PTY resize and keepalive.
- Physical-keyboard/IME policy covers device-aware Unicode/CJK/emoji, CapsLock, AltGr, focus and duplicate-change suppression.
- WP-S0 SFTP integrity floor is implemented: zero-byte transfers, `.partial` staging, identity-bound resume, fsync/size verification and atomic commit.
- Current SFTP checkpoint adds durable task metadata, lifecycle transitions, capability-aware provider selection, authorization and file views.
- Local provider separates persisted Picker URI from FileIO path; API 23 child operations use the authorized path.
- Pad/PC SFTP uses a full-screen in-page workspace; `sm` keeps the original bottom Sheet and original virtual-key-bar behavior. Input-device mode is scoped to Pad/PC.
- Wide Pad/PC SFTP keeps remote navigation/path jump/rename/actions left and local authorization/listing/upload actions right.
- The SFTP checkpoint is closed for integrity, task metadata, local-provider and Pad/PC workspace; background payload execution remains page-owned and real provider/endpoint acceptance is pending.
- WP-T4 first migration slice is implemented: `alacritty_terminal` `0.26.0` is default behind terminalCore; the old Rust core remains a no-default fallback. All form factors use native XComponent with bounded xterm fallback.
- `sshTerminalForegroundColor` is ARGB through NAPI; ANSI colors remain independent, and font size stays in Canvas for cell geometry.
- The SSH owner reactor now sends bounded non-blocking libssh2 keepalives and retries transient failures without taking a second session owner.
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
- ProxyJump route slice is now wired through the SSH-only add/edit flows and
  native libssh2: a bastion SSH session authenticates with the configured
  proxy user (or target user) and opens a direct-tcpip channel to the target;
  a bounded socketpair relay feeds the existing target terminal session.
  Teardown/recovery joins the relay before freeing the jump session.
- Same-page SSH host switching now has an independent binding generation. An
  old async connect, session attach, data callback or PiP continuation is
  rejected after the visible host changes; a pending native handshake is
  cancelled before the target host starts, and the xterm surface generation
  remains tied to the target host.
- Same-page host switching now has an explicit `terminalSurfaceMounted` gate:
  the old WebView is removed before a new host is rebound, target output is
  queued until its fresh xterm document is ready, and persistence failures
  cannot strand a live session behind the loading view. The surface binding
  key is observable and the next WebView is mounted on a later UI turn, so a
  fast second-host switch cannot reuse the first host's DOM. Detach-race
  output is retained per host; native keys use stable host IDs and fallback
  rebuilds from one bounded host transcript.
- Switched-session rendering no longer waits for last-connected persistence;
  fresh tab arrays, an observable host/binding identity and an identity-keyed
  pane keep stale surfaces from freezing the second host's page. GPU XComponent
  rebinds the selected host core to its retained surface, retries a destroy /
  recreate race from the last known surface, and xterm gives each document an
  isolated JavaScript bridge so late callbacks cannot freeze the new page.
- Mount requests retain a pending binding key; repeated connected-state probes cannot starve the second-host renderer. The native registry now rejects stale owners, and a bounded ready timeout falls back from a blank native surface to transcript-backed xterm.
- A separate ArkUI render revision now keys the visible terminal subtree, so a remount with the same host/session identity still destroys and recreates the stale XComponent/WebView.
- Native surface rendering now restores the EGL current context before drawing or flushing, exposes an explicit retained-snapshot refresh after host rebind, and acknowledges `OH_DRAWING_SurfaceFlush`; a host with no new SSH bytes can still repaint its existing terminal state or enter the bounded retry path. API 23 surface-ID polling covers skipped `onSurfaceCreated` callbacks, the first measured area size triggers a correctly sized rebind, and final SSH-page teardown destroys all retained GPU renderer handles.

## SSH Connectivity Boundary

- Native SSH currently supports `direct`, `http_connect`, `socks5`, raw
  `frp_tcp` and the new `ssh_jump` route slice.
- Legacy generic gateway fields fail closed; they are never silently converted
  into a direct SSH connection.
- SSH ProxyJump/bastion has a native route and matching key preflight relay,
  but real bastion interoperability and host-key binding remain pending.
  Local/remote/dynamic forwarding and FRP Visitor/STCP/SUDP/XTCP remain open.

## Verification

- `git diff --check`: passed after the final refresh fix on 2026-08-06.
- Host native tests: `254 passed, 16 failed, 270 total`; all failures are the
  existing VNC TLS fixture startup failures; the keepalive/SSH diagnostics
  tests pass.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib
  --no-default-features`: `156 passed, 1 failed, 157 total`; the remaining
  failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed for the host-switch surface refresh
  checkpoint on 2026-08-06; warnings only.
- `assembleHap`: host-switch surface refresh passed with `BUILD SUCCESSFUL`
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

- Existing independent review passed the bounded-output and IME/socket
  increments; checkpoint `ffa0f9e` remains `REVIEW_REQUIRED` until review.
- SFTP scope is closed for this pass; real-device/endpoint evidence is not a Level A completion claim.
- Device evidence covers injected input and lifecycle; external keyboard/IME, GPU re-enable, bastion/forwarding/FRP evidence remain open.

## Next

1. Independently review the committed same-page SSH binding/initial-UI surface-owner, fallback, remount and EGL refresh checkpoint.
2. Verify ProxyJump against a real OpenSSH bastion and bind its host key.
3. Add SSH-scoped local/remote/dynamic forwarding and FRP visitor modes.

## Blockers

- Full external-keyboard/third-party-IME and SFTP lifecycle/provider acceptance
  remains pending; cold/large-output/background/PiP/re-entry and 90-second idle
  checks passed.
- Real-device validation for the current initial-UI/host-switch/native-renderer
  pass is intentionally deferred by the user; only code-level gates were requested.
- No real OpenSSH bastion, forwarding service or FRP endpoint is available; HDC is offline; ProxyJump host-key binding and `ohosTest@OhosTestCompileArkTS` (`00306054`) remain pending.
