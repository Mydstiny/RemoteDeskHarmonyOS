# Shared Queue

Updated: 2026-08-05 Asia/Shanghai

## Now

- SFTP checkpoint is closed for the implemented integrity, durable metadata,
  local-provider and Pad/PC workspace scope; do not expand it in this pass.
- Alacritty `0.26.0` is now the default VT core behind terminalCore; the
  reactor keepalive, PiP/session lifecycle and bounded Canvas consumption are
  committed; cold/large-output/background/re-entry acceptance is recorded.
- User-accept the remaining external-keyboard/third-party-IME paths on the
  signed HAP, while keeping the old Rust core as an explicit fallback.
- Keep the review state at the matching PASS receipt; do not claim full
  background SFTP execution, Level A, or Level B connectivity.

## Next

- WP-T4 user acceptance and benchmark using shared terminal fixtures.
- WP-T5/WP-T6 terminal correctness and damage-frame renderer implementation.
- Real SFTP, bastion, forwarding and FRP endpoint interoperability tests when
  the corresponding services and HDC/device are available.
- Implement a separate Level B contract for ProxyJump, port forwarding and FRP.

## Later

- Complete the background transfer engine, UDMF drag/drop and SFTP lifecycle
  acceptance beyond the current page-owned execution path.
- WP-T7 terminal accessibility/lifecycle recovery and Level A acceptance.

## Evidence Gaps

- HDC target `5KLBB25928203528` passed cold SSH, large output, Home retention,
  PiP/re-entry and resumed-command checks; real external keyboard/IME coverage
  remains an evidence gap.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 16 pre-existing VNC TLS fixture startup failures.
