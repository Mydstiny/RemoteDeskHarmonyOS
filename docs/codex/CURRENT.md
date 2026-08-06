# Shared Current State
## Active Task
- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoint: `cc68965` (`fix(ssh): make Pad SFTP root sheet explicit`), following `f72b5fb` (`feat(ssh): expose keyboard-interactive auth prompts`), `caefd47` (`fix(ssh): keep Pad SFTP in wide root sheet`), `5e4b563` (`fix(ssh): bind wide SFTP layout to Pad devices`), `f6ef9559a` (`fix(ssh): size SFTP bind sheets`) and `9eb54c7f2` (`feat(ssh): refine SFTP endpoint workspace`); keyed surface recovery, forwarding lifecycle, adapter reactor binding, and the generation-guarded NAPI/ArkTS bridge are committed.
- Phase: Alacritty core and xterm-safe visible fallback; lifecycle, VT/Unicode/resize/TUI/large-output parity, per-host output isolation, strict ACK-gated canvas presentation, SFTP Pad/phone workspace and background-session handoff, code-only host-switch/surface refresh recovery, guarded surface fallback, and native forwarding contract.
- Scope: migrate VT behind terminalCore, keep appearance settings in-core, verify IME/input/Canvas behavior. Homepage work is not current focus.
## Progress
- WP-T0/T1/T2 are implemented: diagnostics, bounded native input, one SSH session-owner reactor, PTY resize, SFTP and keepalive share generation/teardown rules; physical-keyboard/IME policy covers Unicode/CJK/emoji, CapsLock, AltGr, focus and duplicate-change suppression.
- SFTP integrity, durable task metadata, capability-aware provider selection, API 23 authorized local-provider operations and the Pad/PC full-screen workspace are implemented; Pad uses the root wide bindSheet while phone landscape remains on the original bottom-sheet interaction. Background handoff now reattaches retained SSH sessions to the page-independent SFTP engine, keeps active work running only after background continuity is accepted, and pauses/cleans up when the system reports `backgroundLimited`; real endpoint/device acceptance remains pending.
- Mobile SFTP keeps the current SSH host on the left and exposes exactly two right-endpoint choices: local files or an SSH host. The initial right pane is chooser-only; selection is committed only after a button/host choice, and host selection uses a nested bindSheet inside the existing SFTP surface. Each newly opened SFTP surface resets the right endpoint to chooser-only. Phone stays on the bottom bindSheet; Pad uses explicit 96% SFTP width and 88% host-picker width, with the header close affordance lowered below the sheet edge inset. A shared 320 ms exit guard delays the host-list add-host Sheet during cross-route back navigation, and the inactive host-list FAB is hidden during route teardown so it cannot duplicate the SSH-page affordance.
- SSH forwarding validates local/remote/dynamic profiles, binding policy, bounded connections, generations and start/listen/fail/stop transitions. `SshAdapter` owns the manager and reactor reset; NAPI/ArkTS exposes the guarded lifecycle API, while real libssh2 socket/channel forwarding remains open.
- Dynamic SOCKS5 rejects unsupported methods/commands/address types, flushes failure replies, and protects handshake buffers. Listener errors clean runtime state; stale stop completion is generation-rejected. FRP Visitor/STCP/SUDP/XTCP fail closed until their control plane exists.
- WP-T4 uses `alacritty_terminal` `0.26.0` behind terminalCore with a fallback core and bounded xterm path. Appearance/geometry remain independent; output is capped at 256 KiB per turn and ordered remainders are retained. SBOM/NOTICE include Alacritty.
- SSH background/PiP ownership is isolated and serialized; the background service aggregates all open SSH tabs into one OS continuous task, rejects invalid task IDs explicitly, and reports connection count/host summary. PiP auto-start requires prepared callback/resume gates. ProxyJump has a native `ssh_jump` route and bounded bastion relay, pending host-key binding and endpoint acceptance.
- Same-page switching rejects stale async callbacks, cancels pending handshakes, retains detach-race output per host, and serializes tab handoff without dropping either SSH socket.
- The terminal surface has an explicit detach/rebind gate, deterministic host/binding/revision keys, owner leases, isolated xterm bridges, host-scoped FIFOs and strict frame ACK; xterm writes are serialized by callback, failed/timeout batches are fully replayed into a fresh document, lifecycle retries use new bridges, inactive surfaces cancel reload timers, and the visible layer stays masked until xterm-ready.
- The current SSH canvas follow-up keeps the terminal shell at the full post-header height, reserves the virtual-key bar height in xterm, anchors the bar to the complete shell, adds a 6px xterm bottom safety inset, and refreshes keyboard plus keyboard/mouse presence at the SSH connection boundary using the RDP-aligned device snapshot.
- Keyboard-interactive authentication now has a page-owned bindSheet broker UI: target host, hop, round, name/instruction, multiple prompts, echo-aware password masking, cancel/expiry cleanup, and handled request identity fencing across MFA rounds; prompt values are cleared after the one-shot handoff.
- RDP settings use protocol-local capability gates and session generations; clipboard/file paths and cliprdr fail closed across setting changes/reconnects. Clipboard send/upload waits for the current cliprdr channel; enabling it after a handshake without cliprdr prompts reconnect. Diagnostics is isolated from RustDesk; the PC physical-touchpad path is source/tool gated.
- RDP post-connect startup is fail-closed: input worker, frame pump, redraw registration and event-loop creation must succeed before `CONNECTED`; cliprdr carrier attach/detach/cleanup is lifetime-guarded and failed startup leaves GDI retirement to the teardown fence.
- RDP Gateway-aware certificate preflight now keeps Gateway/target certificates and route identity separate; vendor HTTPS, Azure Bastion and unknown Gateway routes fail closed. Restricted Admin + Microsoft RD Gateway is explicitly rejected because the target-only NTLM hash is not a Gateway password; real Gateway interoperability remains unverified.
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
- `git diff --check`: passed for the xterm ACK/reload recovery and PC physical-touchpad checkpoint on 2026-08-06.
- Inline xterm JavaScript parse and stubbed ordered-batch/error protocol checks: passed on 2026-08-06.
- Host native tests: `289 passed, 16 failed, 305 total`; failures are existing
  VNC TLS fixture startups. RDP/SSH/forwarding/diagnostics tests pass; the OHOS
  callback binary needs a target device, while production Ninja compilation passed.
- Rust `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib --no-default-features`:
  `156 passed, 1 failed, 157 total`; the remaining failure is the existing rendezvous fixture's public-address assertion.
- RustDesk physical-touchpad focused Rust tests: `3 passed, 0 failed` on 2026-08-06.
- RDP-only checkpoint `default@OhosTestCompileArkTS` passed on 2026-08-06. A prior mixed-worktree rerun reported preserved SSH syntax at `entry/src/main/ets/pages/SshTerminal.ets:780` (`10905209`), but the latest rerun on 2026-08-07 returned exit 0 with existing warnings only; do not attribute the historical diagnostic to RDP.
- `assembleHap`: `BUILD SUCCESSFUL` on the final physical-touchpad checkout on 2026-08-06; existing warnings only.
- Current canvas follow-up: `default@OhosTestCompileArkTS` passed and `assembleHap` returned `BUILD SUCCESSFUL` after the shell/bar/keyboard changes on 2026-08-06; `git diff --check` passed.
- Mobile SFTP endpoint/sheet handoff follow-up: `default@OhosTestCompileArkTS` passed; Pad wide bindSheet and SSH host-picker widths are compiled; explicit `isPadDevice` layout gating keeps phone landscape on the bottom-sheet path; `assembleHap` returned `BUILD SUCCESSFUL`; `git diff --check` passed on 2026-08-06. Phone remains bottom-sheet and the initial right endpoint remains chooser-only; no device screenshot or real endpoint transfer evidence is claimed.
- Mobile SFTP UI polish follow-up: right endpoint state resets on each new surface, the SFTP close affordance is moved down for the Pad/phone sheet inset, the empty host-list hint no longer renders a second `+`, and the inactive host-list FAB is hidden during route teardown. Final `default@OhosTestCompileArkTS` passed and `assembleHap` returned `BUILD SUCCESSFUL` after the minimal RDP gateway-transport type normalization; `git diff --check` passed on 2026-08-06.
- SFTP background handoff follow-up: `default@OhosTestCompileArkTS` passed and `assembleHap` returned `BUILD SUCCESSFUL` after the invalid continuous-task ID, context fallback, retained-tab reattach and page-teardown changes on 2026-08-06; `git diff --check` passed. This is code-level evidence only; no background transfer or process-restart endpoint evidence is claimed.
- Keyboard-interactive prompt UI follow-up: `default@OhosTestCompileArkTS` passed and `assembleHap` returned `BUILD SUCCESSFUL` after adding multi-prompt input, system-dismiss cancellation and stale-snapshot suppression on 2026-08-07; the host native suite still reports `289 passed, 16 pre-existing VNC TLS fixture startup failures, 305 total`. No real MFA endpoint or device screenshot is claimed.
- Fresh full-worktree gate rerun on 2026-08-07 passed both required Hvigor commands and `git diff --check`; the first `assembleHap` attempt exposed an existing RDP `-Werror` unused certificate helper in the preserved mixed-worktree changes, then passed after a `[[maybe_unused]]` annotation with no runtime behavior change.
- Direct real-FreeRDP OHOS objects (`freerdp_adapter.cpp` and
  `rdp_file_clipboard_bridge.cpp`) compile successfully; the fresh HAP also
  passes the production assemble gate above.
- RDP Gateway policy checkpoint: direct/transparent routes retain their existing
  path; the Gateway route request carries explicit auth context and rejects the
  unsupported Restricted Admin combination before FreeRDP is invoked.
- RustDesk renderer regression fix: raw BGRA/VP8/VP9 keeps the established
  texture-size Fit path, and ArkTS canvas/input geometry uses the renderer
  snapshot again instead of forcing protocol dimensions; OES/H.264/H.265 uses
  separately staged output dimensions, and logical source updates no longer
  overwrite OES state.
  `default@OhosTestCompileArkTS`, `assembleHap`, and `git diff --check` passed
  on 2026-08-06. The signed HAP installed to HDC target `127.0.0.1:5555`;
  no three-codec frame evidence was captured because the prior device target
  is offline.
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
  standalone target rebuilt with the SDK-bundled CMake and production Ninja
  compilation passed.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
## Review
- Existing independent review passed the bounded-output and IME/socket increments. The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment also passed with no P0/P1/P2 findings; receipt `ssh-terminal-surface-forwarding-frp-pass-2026-08-06` is recorded. The strict xterm ACK/reload/watchdog increment passed Dalton review with no P0/P1/P2/P3 findings; receipt `ssh-terminal-xterm-ack-reload-pass-2026-08-06` is recorded. The status command remains `REVIEW_REQUIRED` because unrelated mixed-worktree changes remain; no destructive cleanup was performed.
- The PC physical-touchpad increment received independent PASS review with no P0-P3 findings; Windows/macOS modifier mapping, cumulative Pinch accounting, gesture reset, and virtual-path isolation were checked.
- SFTP UI scope is closed for this pass; background handoff is implemented at code level, while real-device/endpoint/process-restart evidence is not a Level A completion claim.
- Pad SFTP root-sheet follow-up `cc68965` keeps the complete wide workspace in the Pad `bindSheet`, binds the root sheet geometry directly to `isPadDevice`, resets a newly opened right pane to chooser-only, and moves the close affordance below the sheet inset. `default@OhosTestCompileArkTS`, `assembleHap`, and `git diff --check` passed on 2026-08-07; no device screenshot is claimed.
- Auth prompt checkpoint `f72b5fb` and Pad SFTP root-sheet checkpoint `cc68965` are code-only and await the existing SSH reviewer task's incremental review; status remains `REVIEW_REQUIRED` because the worktree still contains preserved mixed-protocol changes.
- Device evidence covers injected input and lifecycle; external keyboard/IME, GPU re-enable, bastion/forwarding/FRP evidence remain open.
- RDP Gateway evidence is code/test-only: no real Microsoft RD Gateway,
  certificate-rotation, or Restricted Admin Gateway endpoint evidence exists.
- HDC target `5KLBB25928203528` is offline; signed HAP installation succeeded
  on the currently visible `127.0.0.1:5555` target, but no three-codec frame
  log or physical-device screenshot is claimed yet.
- The mobile SFTP endpoint and cross-route Sheet guard have code-level coverage only; no new device screenshot or real endpoint transfer evidence is claimed.

## Next
1. Perform SSH canvas and background-SFTP device acceptance when the current code-only boundary is lifted; keep the xterm path as the visible renderer until safe GPU evidence exists.

## Blockers

- Full external-keyboard/third-party-IME, background-SFTP transfer/restart and SFTP endpoint lifecycle acceptance remains pending; cold/large-output/background/PiP/re-entry and 90-second idle checks passed.
- Native GPU re-enable is blocked until a backend that cannot abort on a stale
  API 23 BufferQueue is available; no real OpenSSH bastion, forwarding or FRP
  endpoint is available, and `ohosTest@OhosTestCompileArkTS` (`00306054`) remains
  pending.
- The historical full-worktree ArkTS diagnostic at `SshTerminal.ets:780` was not
  reproduced on the 2026-08-07 rerun; both required Hvigor gates are currently
  green, while the RDP Gateway code-level checkpoint remains separately
  verified.
- RDP Restricted Admin through Microsoft RD Gateway remains intentionally
  unsupported until a separate encrypted Gateway credential is modeled and
  verified; do not bypass the `E-RDP-GATEWAY-AUTH` refusal.
