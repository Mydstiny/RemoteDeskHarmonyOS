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
  an independent ArkUI render revision forces stale surface recreation, and
  native rendering restores EGL context plus explicitly repaints retained
  snapshots after a host rebind; the fresh signed HAP passed both code-only
  gates.
- Same-page SSH host switching now rejects stale async connect/attach/data/PiP
  continuations using an independent binding generation, cancels pending
  handshakes before switching, and retains detach-race output per host. The
  visible xterm WebView has an explicit detach/rebind gate; the page publishes
  an observable host/binding identity, and Pad/PC native VT rebinds a retained
  XComponent surface when ArkUI does not emit a new surface callback. A last
  known surface retry, owner-checked detach, per-document xterm bridge and an
  independent render revision now close the destroy/recreate race that could
  leave the second host connected but visually stale.
  Both code-only Hvigor gates passed on 2026-08-06; device validation is deferred.
- Keep the review state at the matching PASS receipt; do not claim full
  background SFTP execution, Level A, or Level B connectivity.
- The first ProxyJump implementation and matching key preflight relay are
  committed, but keep them pending until bastion host-key policy and a real
  OpenSSH endpoint are verified.

## Next

- WP-T4 user acceptance and benchmark using shared terminal fixtures.
- Independently review the committed same-page SSH binding-generation,
  initial-UI view-remount, surface-owner, fallback, render-revision and EGL
  refresh fix.
- WP-T5/WP-T6 terminal correctness and damage-frame renderer implementation.
- Real SFTP, bastion, forwarding and FRP endpoint interoperability tests when
  the corresponding services and HDC/device are available.
- Implement a separate Level B contract for ProxyJump, port forwarding and FRP.
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
- Host native suite has 16 pre-existing VNC TLS fixture startup failures.
