# Shared Current State
## Active Task
- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `22fd302` (`fix(ssh): close xterm frame recovery lifecycle`), following `24d701f` (`fix(ssh): avoid api23 gpu surface abort`); keyed surface recovery, forwarding lifecycle, adapter reactor binding, and the generation-guarded NAPI/ArkTS bridge are committed.
- Phase: Alacritty core and xterm-safe visible fallback; lifecycle, VT/Unicode/resize/TUI/large-output parity, per-host output isolation, strict ACK-gated canvas presentation, code-only host-switch/surface refresh recovery, guarded surface fallback, and native forwarding contract.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, verify IME/input/Canvas behavior. Homepage work is not current focus.
## Progress
- WP-T0/T1/T2 are implemented: diagnostics, bounded native input, one SSH session-owner reactor, PTY resize, SFTP and keepalive share generation/teardown rules; physical-keyboard/IME policy covers Unicode/CJK/emoji, CapsLock, AltGr, focus and duplicate-change suppression.
- SFTP integrity, durable task metadata, capability-aware provider selection, API 23 authorized local-provider operations and the Pad/PC full-screen workspace are implemented; background payload execution and endpoint acceptance remain pending.
- SSH forwarding validates local/remote/dynamic profiles, binding policy, bounded connections, generations and start/listen/fail/stop transitions. `SshAdapter` owns the manager and reactor reset; NAPI/ArkTS exposes the guarded lifecycle API, while real libssh2 socket/channel forwarding remains open.
- Dynamic SOCKS5 rejects unsupported methods/commands/address types, flushes failure replies, and protects handshake buffers. Listener errors clean runtime state; stale stop completion is generation-rejected. FRP Visitor/STCP/SUDP/XTCP fail closed until their control plane exists.
- WP-T4 uses `alacritty_terminal` `0.26.0` behind terminalCore with a fallback core and bounded xterm path. Appearance/geometry remain independent; output is capped at 256 KiB per turn and ordered remainders are retained. SBOM/NOTICE include Alacritty.
- SSH background/PiP ownership is isolated and serialized; PiP auto-start requires prepared callback/resume gates. ProxyJump has a native `ssh_jump` route and bounded bastion relay, pending host-key binding and endpoint acceptance.
- Same-page switching rejects stale async callbacks, cancels pending handshakes, retains detach-race output per host, and serializes tab handoff without dropping either SSH socket.
- The terminal surface has an explicit detach/rebind gate, deterministic host/binding/revision keys, owner leases, isolated xterm bridges, host-scoped FIFOs and strict frame ACK; xterm writes are serialized by callback, failed/timeout batches are fully replayed into a fresh document, lifecycle retries use new bridges, inactive surfaces cancel reload timers, and the visible layer stays masked until xterm-ready.
- RDP settings use protocol-local capability gates and session generations; clipboard/file paths and cliprdr fail closed across setting changes/reconnects. Clipboard send/upload waits for the current cliprdr channel; enabling it after a handshake without cliprdr prompts reconnect. Diagnostics is isolated from RustDesk; the PC physical-touchpad path is source/tool gated.
- RDP post-connect startup is fail-closed: input worker, frame pump, redraw registration and event-loop creation must succeed before `CONNECTED`; cliprdr carrier attach/detach/cleanup is lifetime-guarded and failed startup leaves GDI retirement to the teardown fence.
- GPU rebind, owner leases, refresh fences, surface-ID polling and retained snapshots are implemented, but API 23 `OH_Drawing_SurfaceFlush` reproduced `41207000`/process `SIGABRT`; visible SSH stays on mature xterm.js until a safe backend is available.
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
- `git diff --check`: passed for the xterm ACK/reload recovery checkpoint on 2026-08-06.
- Inline xterm JavaScript parse and stubbed ordered-batch/error protocol checks: passed on 2026-08-06.
- Host native tests: `280 passed, 16 failed, 296 total`; failures are existing
  VNC TLS fixture startups. RDP/SSH/forwarding/diagnostics tests pass; the OHOS
  callback binary needs a target device, while production Ninja compilation passed.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib --no-default-features`:
  `156 passed, 1 failed, 157 total`; the remaining failure is the existing rendezvous fixture's public-address assertion.
- `default@OhosTestCompileArkTS`: passed on the current checkout on 2026-08-06; warnings only after strict xterm ACK/reload recovery and active lifecycle gates; the physical-touchpad ArkTS policy tests are included and pass.
- `assembleHap`: blocked by existing `ssh_adapter.cpp:2251` prompt-text type
  error in the mixed worktree; no non-canvas native file was changed.
- Direct real-FreeRDP OHOS objects (`freerdp_adapter.cpp` and
  `rdp_file_clipboard_bridge.cpp`) compile successfully; a fresh HAP remains
  blocked only by the preserved SSH error above.
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
- Existing independent review passed the bounded-output and IME/socket increments. The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment also passed with no P0/P1/P2 findings; receipt `ssh-terminal-surface-forwarding-frp-pass-2026-08-06` is recorded. The strict xterm ACK/reload/watchdog increment passed Dalton review with no P0/P1/P2/P3 findings; receipt `ssh-terminal-xterm-ack-reload-pass-2026-08-06` is recorded. The status command remains `REVIEW_REQUIRED` because unrelated mixed-worktree changes remain; no destructive cleanup was performed.
- SFTP scope is closed for this pass; real-device/endpoint evidence is not a Level A completion claim.
- Device evidence covers injected input and lifecycle; external keyboard/IME, GPU re-enable, bastion/forwarding/FRP evidence remain open.

## Next
1. Perform SSH canvas device acceptance and benchmark when the current code-only boundary is lifted; keep the xterm path as the visible renderer until safe GPU evidence exists.

## Blockers

- Full external-keyboard/third-party-IME and SFTP lifecycle acceptance remains pending; cold/large-output/background/PiP/re-entry and 90-second idle checks passed.
- Native GPU re-enable is blocked until a backend that cannot abort on a stale
  API 23 BufferQueue is available; no real OpenSSH bastion, forwarding or FRP
  endpoint is available, and `ohosTest@OhosTestCompileArkTS` (`00306054`) remains
  pending; `assembleHap` is blocked by the existing `ssh_adapter.cpp:2251` error.
