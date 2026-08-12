# Moonlight Complete Upgrade Queue

Updated: 2026-08-12 Asia/Shanghai

## Closed checkpoint

- `6b0c1aa8` closes the local-only U1-06～U1-12 UI shell: homepage host management, host detail, per-host app catalog, nine-section settings, RustDesk-style launch/connection/stream overlays, official tintable icon and desktop sidebar slot.
- `8b1ccd22` + `4548499c` + `647113a5` close S1-01/S1-02 dormant shared-session coordination, exact owner/account/session fences, atomic reservation/promotion, stop failure and watchdog cleanup. Runtime remains absent and fail closed.
- `75d769c2` closes S1-03: scoped coordinator snapshots, StreamPage lifecycle subscription/teardown, real phase/error/degradation/first-frame presentation and no false connected state.
- `fae7c36dd` + `f7f39c0f` + `665df714` close S1-04: responsive RustDesk-aligned session toolbar/control center, edge-rail bounds, explicit non-xl collapse, xl pin/5-second auto-hide, Sheet/breakpoint timer reconciliation and policy regression cases.
- Final S1-04 review reused task `019fe966-d99a-7ce1-8b53-4ef725597053`: PASS, P0/P1/P2 = 0; one accepted P3 covers ArkUI timer instantiation limits in pure tests. No other protocol, cloud, native or runtime source was changed.
- Final current-workspace signed HAP SHA-256 is `cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`; both mandatory Hvigor gates passed.
- Final HAP was installed/started outside the sandbox on PC `127.0.0.1:5555` and phone `127.0.0.1:5557`. Final evidence is only the newly captured/viewed `moonlight-s104-final-cb1086-*` set: PC root/max/sidebar picker/disabled click and phone root/picker/disabled click all pass; no old screenshot is used.
- FAB/sidebar and all runtime actions remain disabled (`moonlightProtocolAvailable=false`); no transport, media, controller, cloud, timer/background work is opened by the dormant product path.
- User-owned `entry/src/main/ets/services/CloudStore.ets` remains the only unstaged change and is excluded from this task.

## Next

- S1-05A: native HarmonyOS GameController listener plus narrow typed NAPI, feeding the existing N3-08/N3-05/N3-01/common-c chain. Do not add a public input owner, second queue or ArkTS wire encoder; real-device capability remains false until receipts exist.
- N2-09: real Sunshine and user ARM64 evidence for pairing, H.264/Opus media, first frame, lifecycle, input, network, thermal and long-run behavior.
- S1-06/S1-07/S1-08: continue control center/diagnostics/media lifecycle only after their specified runtime prerequisites; keep the single Sheet owner and existing input/session policy.

## Parked / blocked

- Moonlight cloud sync stays parked: no `moonlightrecordv1`, table registration, selection, transfer or secret recovery.
- `ohosTest@OhosTestCompileArkTS` remains blocked because task `00306054` is not registered; compile registration is not device execution.
- A signed HAP/UI shell is verified, but Moonlight is not a release-ready streaming capability until runtime, media, controller and external-device gates produce current receipts.
