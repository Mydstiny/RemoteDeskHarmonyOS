# Shared Queue
Updated: 2026-08-07 Asia/Shanghai
## Now
- RDP setting lifecycle hardening is complete for this increment: clipboard
  toggles, file paste/drop, delayed bridges and cliprdr callbacks are guarded by
  the current setting plus session generation; clipboard send/upload stays
  unavailable until the current cliprdr channel is ready, and enabling it after
  a handshake without cliprdr requires reconnect. RDP diagnostics polling is
  isolated from RustDesk. Keep the existing single-monitor and drive capability
  boundaries explicit in UI and capability reasons. RustDesk PC 实体触控板限定
  为 `SourceTool.TOUCHPAD` 的二维滚轮/Pinch，Windows/macOS 分别使用 Ctrl/Command，虚拟路径不变。
- RDP startup is fail-closed: input worker, frame pump, redraw callback and event
  loop failures cannot publish false `CONNECTED`; cliprdr lifetime is serialized
  through reconnect/cleanup. Keep device long-connection validation pending.
- SFTP checkpoint is closed for integrity, durable metadata, local-provider and Pad/PC
  workspace; Pad uses a centered root bindSheet selected by `isPadDevice`,
  `cc68965` keeps the root-sheet geometry explicit, `caefd47` keeps the right pane chooser-only with a sheet-safe close offset, and Phone (including landscape) keeps the bottom-sheet interaction.
- Mobile SFTP endpoint selection is closed: right side has local/SSH-host buttons;
  picker is nested in the mounted surface, initial pane is chooser-only, and
  add-host waits for native exit. Root opening commits in the same UI turn; its
  internal readiness gate cannot rebuild the Sheet during entrance, while child
  opening waits for the parent to be live. Queued requests are cancellable, mount
  tokens fence stale callbacks, and picker exit/reopen is serialized; each
  mounted Sheet has one native dismiss driver; stale callbacks finish only their
  old instance; cleanup waits for onDisappear and explicit root close is not
  blocked by transient guards. Pad uses a wide root bindSheet, respects the
  inset, and has no duplicate empty-state plus.
- SSH keyboard-interactive/MFA prompts use a page-owned broker bindSheet with
  echo-aware multi-prompts, hop/round metadata, cancel/expiry and stale-request
  fencing; checkpoint `f72b5fb` is code-only pending the existing reviewer.
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
  `assembleHap` is `BUILD SUCCESSFUL`. The signed HAP is installed on
  `127.0.0.1:5555`; the hidden xterm prewarm reached ready and repeated visible
  SSH entries reached page/report ready without a crash. Multi-host and
  virtual-keyboard/function-bar acceptance remain next.
- The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment has an independent PASS receipt; the strict xterm ACK/reload/watchdog increment also has an independent PASS receipt `ssh-terminal-xterm-ack-reload-pass-2026-08-06`. Background SSH now owns a session collection and the page-independent SFTP engine can reattach retained tabs, but real background transfer/restart evidence is still open; do not claim Level A or Level B connectivity. The status command remains `REVIEW_REQUIRED` only because preserved mixed-worktree changes remain dirty.
- The first ProxyJump implementation and matching key preflight relay are committed;
  keep them pending until bastion host-key policy and a real OpenSSH endpoint are verified.
- The native forwarding lifecycle contract is committed for local, remote and
  dynamic modes; `SshAdapter` binds runtime transitions to the session-owner
  reactor with transport-reset cleanup, stale-runtime cleanup, byte/expiry
  limits and TCP half-close draining. The guarded NAPI/ArkTS bridge exposes
  configure/remove/start/listen/fail/stop/acquire/release/snapshot with explicit
  generation and SSH-type gates. SOCKS5 failure replies are flushed before
  close, listener failures clean runtime state, and FRP Visitor/STCP/SUDP/XTCP
  remain explicit fail-closed routes. Real SSH socket/channel wiring and
  endpoint interoperability remain open.
- RDP-only checkpoint passed `default@OhosTestCompileArkTS`, `git diff --check`, direct FreeRDP builds and host suite (`294 passed, 16 pre-existing VNC TLS fixture startup failures, 310 total`); the 2026-08-07 rerun and `assembleHap` passed.
  Gateway stages stay separate; `CONTINUE_ONCE` leaves persisted records unchanged;
  Restricted Admin + RD Gateway fails closed with `E-RDP-GATEWAY-AUTH`;
  `gatewayTransportSelected` is requested-only, negotiated transport is unknown without wire/instrumentation, and OHOS/device evidence plus mixed-worktree review remain open.
- RustDesk RAW/OES geometry follow-up keeps RAW BGRA viewport sizing on the
  actual uploaded texture so VP8/VP9/AV1 software downscaling is unchanged;
  H.264/H.265 OES uses logical remote dimensions with OES output as a
  first-frame fallback. Native policy assertions and both required Hvigor
  gates passed on 2026-08-07. HDC target
  `5KLBB25928203528` remains offline, so device codec evidence is open.
## Next
- RDP Gateway plan: `docs/codex/plans/2026-08-06-rdp-gateway-aware-certificate-preflight-plan.md` covers real dual-cert, transport-observation and rotation acceptance.
- WP-T4 canvas user acceptance and benchmark using shared terminal fixtures; the code-only ACK/reload/rebind review and commit are complete.
- Complete second-host switching and virtual-keyboard/function-bar acceptance on the installed xterm.js path; retain xterm.js as the visible SSH renderer while the API 23 GPU backend is unsafe.
- Implement local/remote/dynamic libssh2 socket/channel transport behind that bridge, with endpoint-facing error propagation.
- WP-T5/WP-T6 terminal correctness and damage-frame renderer implementation.
- Real SFTP, bastion, forwarding and FRP endpoint interoperability tests when
  services and HDC/device are available; finish ProxyJump host-key binding and
  local/remote/dynamic plus FRP Visitor/STCP/SUDP/XTCP endpoint contracts.
## Later
- Complete background transfer restart/authentication recovery, UDMF drag/drop and SFTP lifecycle acceptance beyond the current code-level handoff path.
- WP-T7 terminal accessibility/lifecycle recovery and Level A acceptance.
## Evidence Gaps
- HDC target `5KLBB25928203528` passed cold SSH, ordered input, large output, Home retention, PiP/re-entry and 90-second idle command checks; external keyboard/IME remains an evidence gap. A later reproduction captured the native GPU abort; the visible path is now xterm.js.
- The current device run verifies prewarm readiness plus first/repeat SSH xterm page readiness, welcome output and input without a crash; host-switch, virtual-keyboard/function-bar and external-IME evidence remain open.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`); Light compliance is blocked by baseline SBOM package `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
