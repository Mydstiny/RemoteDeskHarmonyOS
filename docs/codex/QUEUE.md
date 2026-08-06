# Shared Queue

Updated: 2026-08-06 Asia/Shanghai

## Now

- SFTP checkpoint is closed for the implemented integrity, durable metadata,
  local-provider and Pad/PC workspace scope; do not expand it in this pass.
- Alacritty `0.26.0` is now the default VT core behind terminalCore on all form
  factors; the reactor keepalive, PiP/session lifecycle, bounded Canvas
  consumption and IME/socket diagnostics are committed. The keyed surface
  mount deduplicates repeated probes, the native registry rejects stale
  surface owners, a bounded ready fallback restores transcript-backed xterm,
  an independent ArkUI render revision plus a deterministic
  host/binding/revision page view key forces stale surface recreation, and
  native rendering restores EGL context, explicitly repaints retained snapshots
  after a host rebind, acknowledges surface-flush failure before retrying, and
  polls the surface ID when API 23 skips the lifecycle callback; the current
  keyed surface correction also passed both code-only gates. Reused GPU/Xterm
  children receive the same revision and explicitly rebind or reload; the
  revision also advances the native owner lease and renderer view IDs, while
  the xterm reload guard includes the revision token. GPU host/revision prop
  changes now invalidate stale surface observations and attach retries through
  a binding lease before a retained host core is rebound; refresh fences reject
  an old attached owner before reporting the new renderer ready. The explicit
  repaint fence now has one recovery transaction, and a failed native dirty
  frame triggers a retained full-snapshot redraw before the surface is retried.
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
  Both code-only Hvigor gates passed on 2026-08-06; device validation is deferred.
- The current surface fallback, SOCKS5 flush, listener/FRP route and ArkTS/native ABI increment has an independent PASS receipt; do not claim full background SFTP execution, Level A, or Level B connectivity. The status command remains `REVIEW_REQUIRED` only because preserved user RDP diagnostic hunks keep mixed `protocol_adapter.h` and `HostListPage.ets` dirty.
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
- The current code-only closeout passed `default@OhosTestCompileArkTS`, signed
  `assembleHap`, `git diff --check`, and the Makefile native rebuild; the host
  suite is `273 passed, 16 pre-existing VNC TLS fixture startup failures, 289 total`.
  Keep review at `REVIEW_REQUIRED` while preserved user RDP hunks in mixed `protocol_adapter.h` and `HostListPage.ets` remain dirty; the current surface/forwarding/FRP review receipt is recorded.

## Next

- WP-T4 user acceptance and benchmark using shared terminal fixtures.
- Independently review the current same-page SSH binding-generation and commit,
  initial-UI deterministic host/binding/revision keyed remount, surface-owner lease, fallback, render-revision,
  revision-aware document reload, GPU binding-lease invalidation, EGL refresh, surface-ID polling, measured-size rebind, mount-wake fix, and
  reused-renderer rebind/reload.
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
  keyboard/IME coverage remains an evidence gap.
- Current host-switch/initial-UI changes have no new real-device evidence by
  explicit user instruction; code-level validation is the active acceptance
  boundary.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 273 passing tests and 16 pre-existing VNC TLS fixture
  startup failures (289 total).
