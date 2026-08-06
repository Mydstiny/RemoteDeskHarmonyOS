# Shared Queue
Updated: 2026-08-06 Asia/Shanghai
## Now
- RDP setting lifecycle hardening is complete for this increment: clipboard
  toggles, file paste/drop, delayed bridges and cliprdr callbacks are guarded by
  the current setting plus session generation; clipboard send/upload stays
  unavailable until the current cliprdr channel is ready, and enabling it after
  a handshake without cliprdr requires reconnect. RDP diagnostics polling is
  isolated from RustDesk. Keep the existing single-monitor and drive capability
  boundaries explicit in UI and capability reasons. RustDesk PC 实体触控板限定
  为 `SourceTool.TOUCHPAD` 的二维滚轮/Pinch，Windows/macOS 分别使用 Ctrl/Command，虚拟路径不变。
- RDP startup is fail-closed: input worker, frame pump, redraw callback and
  event loop failures cannot publish a false `CONNECTED` state; cliprdr carrier
  lifetime is serialized through reconnect and cleanup. Keep device long-
  connection validation pending until the SSH build blocker is cleared.
- SFTP checkpoint is closed for the implemented integrity, durable metadata,
  local-provider and Pad/PC workspace scope; do not expand it in this pass.
- Alacritty `0.26.0` remains the VT core behind terminalCore, with lifecycle,
  PiP/session, bounded input and xterm fallback behavior implemented. The
  API 23 device reproduction showed that the custom Native Drawing surface can
  turn `41207000` into `Device lost` and `SIGABRT` inside `SurfaceFlush`; the
  visible SSH page is therefore gated to the mature xterm.js renderer until a
  safe GPU backend is available. Native surface recovery code is retained but
  is not a current acceptance path.
- Same-page SSH host switching now rejects stale async connect/attach/data/PiP
  continuations using an independent binding generation, cancels pending
  handshakes before switching, and retains detach-race output per host. The
  top-tab switch stays in one persistent page, serializes the binding handoff,
  detaches the old session callback and adopts the retained target session. The
  visible xterm WebView has an explicit
  detach/rebind gate; during a host switch the old XComponent/WebView is removed
  and the target surface is mounted only after the new binding is committed;
  the page publishes an observable host/binding identity, and Pad/PC native VT rebinds a retained
  XComponent surface when ArkUI does not emit a new surface callback. A last
  known surface retry, owner-checked detach, per-document xterm bridge and an
  independent render revision and deterministic keyed remount now close the
  destroy/recreate race that could leave the second host connected but visually
  stale. An adopted session's transient native `CONNECTING` state no longer
  hides the newly bound page, and mount retries re-probe native state immediately.
  The page now publishes the keyed renderer after all binding props are written,
  then issues a generation-guarded bounded wake sequence that drains the target
  host's retained output FIFO and repaints until the new surface acknowledges
  its first frame.
  The fallback FIFO is host-scoped, returns unconfirmed batches across lifecycle handoffs, and the visible layer stays masked until xterm-ready; xterm writes are strictly callback-ordered, failed/timeout batches replay in full into a fresh document, reload watchdog/retry attempts use new lifecycle bridges, and inactive surfaces cancel those timers.
  `default@OhosTestCompileArkTS` passed; targeted physical-touchpad Rust tests are
  `3 passed, 0 failed`; inline xterm parse and ordered-batch protocol checks pass;
  `assembleHap` is blocked by the existing `ssh_adapter.cpp:2251` mixed-worktree error. Device installation/acceptance
  remains deferred by the current code-only rule.
- The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment has an independent PASS receipt; the strict xterm ACK/reload/watchdog increment also has an independent PASS receipt `ssh-terminal-xterm-ack-reload-pass-2026-08-06`. Do not claim full background SFTP execution, Level A, or Level B connectivity. The status command remains `REVIEW_REQUIRED` only because preserved unrelated mixed-worktree changes remain dirty.
- The first ProxyJump implementation and matching key preflight relay are
  committed, but keep them pending until bastion host-key policy and a real
  OpenSSH endpoint are verified.
- The native forwarding lifecycle contract is committed for local, remote and
  dynamic modes; `SshAdapter` binds runtime transitions to the session-owner
  reactor with transport-reset cleanup, and the guarded NAPI/ArkTS bridge now
  exposes configure/remove/start/listen/fail/stop/acquire/release/snapshot with
  explicit generation and SSH-type gates. SOCKS5 failure replies are flushed
  before close, listener failures clean runtime state, and FRP Visitor/STCP/
  SUDP/XTCP remain explicit fail-closed routes. Real SSH socket/channel wiring
  and endpoint interoperability remain open.
- The current RDP increment passes `default@OhosTestCompileArkTS`,
  `git diff --check`, direct real-FreeRDP object builds, and the host suite
  (`280 passed, 16 pre-existing VNC TLS fixture startup failures, 296 total`).
  `assembleHap` is blocked at the preserved SSH `std::string::assign` type
  error in `ssh_adapter.cpp:2251`; the OHOS callback binary requires a target
  device and is not executable on macOS.
  Keep review at `REVIEW_REQUIRED` while preserved user RDP hunks in mixed `protocol_adapter.h` and `HostListPage.ets` remain dirty; the current surface/forwarding/FRP review receipt is recorded.
## Next
- WP-T4 canvas user acceptance and benchmark using shared terminal fixtures; the
  code-only ACK/reload/rebind review and commit are complete.
- Keep device acceptance pending until the user lifts the current no-device/code-only boundary; retain mature xterm.js as the visible SSH renderer while the API 23 GPU backend is unsafe.
- Do not dispatch a duplicate reviewer; the guarded forwarding NAPI/ArkTS error
  mapping, surface-flush fallback and explicit FRP route behavior are covered by
  the recorded independent PASS receipt.
- Implement local/remote/dynamic libssh2 socket/channel transport behind that
  bridge, with endpoint-facing error propagation.
- WP-T5/WP-T6 terminal correctness and damage-frame renderer implementation.
- Real SFTP, bastion, forwarding and FRP endpoint interoperability tests when
  the corresponding services and HDC/device are available.
- Finish ProxyJump preflight/host-key binding, then add local/remote/dynamic
  forwarding and FRP Visitor/STCP/SUDP/XTCP contracts with endpoint tests.
## Later
- Complete the background transfer engine, UDMF drag/drop and SFTP lifecycle
  acceptance beyond the current page-owned execution path.
- WP-T7 terminal accessibility/lifecycle recovery and Level A acceptance.
## Evidence Gaps
- HDC target `5KLBB25928203528` passed cold SSH, ordered input, large output,
  Home retention, PiP/re-entry and 90-second idle command checks; real external
  keyboard/IME coverage remains an evidence gap. A later reproduction captured
  the native GPU abort described above; the visible path is now xterm.js.
- Current host-switch/initial-UI changes have no new real-device evidence by
  explicit user instruction; code-level validation is the active acceptance
  boundary.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 276 passing tests and 16 pre-existing VNC TLS fixture startup failures (292 total).
