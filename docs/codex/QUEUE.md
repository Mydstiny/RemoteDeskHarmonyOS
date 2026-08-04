# Shared Queue

Updated: 2026-08-04 Asia/Shanghai

## Now

- Homepage grouped-card follow-on is implemented and concentrated self-reviewed
  at `e877d12c2`; the switch affects Phone, Pad and PC small-window modes only,
  while PC large-window mode stays unchanged.
- Both mandatory Hvigor gates pass on the current homepage implementation.
- Checkpoint `d4731b790` commits the SSH-only T0-T3/WP-S0 implementation after
  self-review and both mandatory Hvigor gates.
- Preserve protocol owners: homepage changes consume read-only projections and
  do not alter RustDesk transport, VNC storage, SSH transport or cloud schemas.

## Next

- WP-S1/S2 complete durable transfer tasks and capability-aware local providers;
  current Task Store is metadata foundation only.
- WP-S3/S4 Pad/PC dual-pane workspace, UDMF token drag/drop and transfer queue.

## Later

- WP-T4 terminal core route decision, WP-T5 Unicode/reflow/mode correctness,
  WP-T6 damage-frame renderer and WP-T7 accessibility/lifecycle recovery.
- Level B ProxyJump, local/remote/dynamic forwarding and enterprise auth remain
  gated until contracts and endpoint evidence exist.

## Evidence Gaps

- No HDC device is listed; Phone/Pad/PC geometry, RustDesk presence, physical
  keyboard, orientation, background/reconnect, SFTP workspace and drag/drop
  evidence is pending.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 16 pre-existing VNC TLS fixture startup failures; all
  251 non-fixture tests, including SSH queue/diagnostics tests, pass.
