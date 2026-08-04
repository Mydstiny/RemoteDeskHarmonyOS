# Shared Queue

Updated: 2026-08-04 Asia/Shanghai

## Now

- SFTP checkpoint is closed for the implemented integrity, durable metadata,
  local-provider and Pad/PC workspace scope; do not expand it in this pass.
- Alacritty `0.26.0` is now the default VT core behind terminalCore; finish
  snapshot/damage comparison and keep the old core as an explicit fallback.
- Diagnose terminal input stalls, IME/physical-keyboard churn, commands that do
  not execute, Canvas misalignment and output/frame backpressure.
- Run shared VT/Unicode/resize/TUI/large-output fixtures through the default
  Alacritty C ABI and compare snapshots/damage with the old core.
- Keep the current review state `REVIEW_REQUIRED`; do not claim full background
  SFTP execution, Level A, or Level B connectivity.

## Next

- WP-T4 default Alacritty route acceptance and a small proof-of-concept
  benchmark using shared terminal fixtures.
- WP-T5/WP-T6 terminal correctness and damage-frame renderer implementation.
- Real SFTP, bastion, forwarding and FRP endpoint interoperability tests when
  the corresponding services and HDC/device are available.
- Implement a separate Level B contract for ProxyJump, port forwarding and FRP.

## Later

- Complete the background transfer engine, UDMF drag/drop and SFTP lifecycle
  acceptance beyond the current page-owned execution path.
- WP-T7 terminal accessibility/lifecycle recovery and Level A acceptance.

## Evidence Gaps

- HDC target `5KLBB25928203528` is connected and the homepage follow-on was
  checked; SFTP workspace and physical-device acceptance are still pending.
- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance is blocked by baseline SBOM package
  `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Host native suite has 16 pre-existing VNC TLS fixture startup failures.
