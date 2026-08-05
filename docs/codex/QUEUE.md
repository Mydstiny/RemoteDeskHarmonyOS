# Shared Queue

Updated: 2026-08-05 Asia/Shanghai

## Now

- SFTP checkpoint is closed for the implemented integrity, durable metadata,
  local-provider and Pad/PC workspace scope; do not expand it in this pass.
- Alacritty `0.26.0` is now the default VT core behind terminalCore; the
  reactor keepalive, PiP/session lifecycle, bounded Canvas consumption and
  IME/socket diagnostics are committed; the fresh signed HAP passed cold,
  large-output, background/re-entry and 90-second idle acceptance.
- User-accept the remaining external-keyboard/third-party-IME paths on the
  signed `4a7642d` HAP, while keeping the old Rust core as an explicit fallback.
- Keep the review state at the matching PASS receipt; do not claim full
  background SFTP execution, Level A, or Level B connectivity.
- The first ProxyJump implementation and matching key preflight relay are
  committed, but keep them pending until bastion host-key policy and a real
  OpenSSH endpoint are verified.

## Next

- WP-T4 user acceptance and benchmark using shared terminal fixtures.
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
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 16 pre-existing VNC TLS fixture startup failures.
