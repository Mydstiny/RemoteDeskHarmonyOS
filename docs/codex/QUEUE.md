# Moonlight Complete Upgrade Queue

Updated: 2026-08-12 Asia/Shanghai

## Closed checkpoint

- `db750cdb` closes U1-13 local-only host-add persistence: validated host/trust rows through the existing local repository port, owner/generation fencing, stable IDs, duplicate handling, readback-aware forward compensation/revival and Sheet `onDisappear` catalog/detail handoff.
- `6b0c1aa8` closes U1-06～U1-12 local-only UI shell: homepage host management, host detail, per-host app catalog, nine-section settings, RustDesk-style launch/connection/stream overlays, official tintable icon and desktop sidebar slot.
- `8b1ccd22` + `4548499c` + `647113a5` close S1-01/S1-02 dormant shared-session coordination; `75d769c2` closes S1-03 snapshots; `fae7c36dd` + `f7f39c0f` + `665df714` close S1-04 toolbar/control center. Runtime remains absent and fail closed.
- Final `db750cdb` HAP SHA-256 is `8b54784ac3112b30a5630ef074d35150fd7271099920e54ab97809ef1546263e`; both mandatory Hvigor gates passed and the HAP was installed/started on PC `5555` and phone `5557`.
- Fresh final UI evidence is only `/private/tmp/moonlight-final-gate.bIGtZD/`; it confirms PC/phone homepage ownership, grey “即将支持” picker, PC large-screen sidebar continuity, the consolidated Moonlight settings group and a real quick-settings bindSheet. No old screenshot is used.
- User-owned `entry/src/main/ets/services/CloudStore.ets` remains the only unstaged code file and is excluded.

## Next

- S1-05A: add the native HarmonyOS GameController listener, narrow typed NAPI and the single session-owned common-c input port feeding N3-08/N3-05/N3-01. Do not add a second input owner/queue or ArkTS wire encoder; real-device capability remains false.
- N2-09: real Sunshine and user ARM64 evidence for pairing, H.264/Opus media, first frame, lifecycle, input, network, thermal and long-run behavior.
- S1-06/S1-07/S1-08: continue control center/diagnostics/media lifecycle only after their runtime prerequisites.

## Parked / blocked

- Moonlight cloud sync stays parked: no `moonlightrecordv1`, table registration, selection, transfer or secret recovery.
- `ohosTest@OhosTestCompileArkTS` remains blocked because task `00306054` is not registered; compile registration is not device execution.
- A signed HAP/UI shell and local host persistence are verified, but Moonlight is not a release-ready streaming capability until runtime, media, controller and external-device gates produce current receipts.
