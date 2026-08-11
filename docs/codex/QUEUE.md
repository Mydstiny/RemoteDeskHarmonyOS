# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Closed checkpoint

- `6b0c1aa8` closes the local-only U1-06～U1-12 UI shell and its review fixes: homepage host management, host detail, per-host app catalog, nine-section settings, RustDesk-style launch/connection/stream overlays, desktop sidebar slot, and fresh PC/phone evidence.
- The final incremental review reused task `019fe966-d99a-7ce1-8b53-4ef725597053` and passed with P0/P1/P2/P3 all zero. Legacy-read/new-write settings compatibility, forced-safe certificate controls, local-commit truth, stream timer fencing, and tintable desktop icon findings are closed.
- Latest fresh r2 evidence was captured only after installing the latest signed HAP; no old screenshot is used for the final acceptance record.
- Homepage owns Moonlight host management. Moonlight settings has no duplicate host-management row and no duplicated shared display/PIP options.
- FAB and sidebar remain explicitly disabled (`moonlightProtocolAvailable=false`); UI shell components do not open transport, native, timer, repository, cloud, or background work.
- Both mandatory Hvigor gates, signed HAP generation, sandbox-external HDC install/start on PC and phone, `git diff --check`, and static cross-protocol isolation review pass.
- User-owned `CloudStore.ets` remains the sole unstaged change and is not part of this task.

## Next

- S1-01/S1-02: connect the dormant local-only Moonlight UI shell to the existing remote-session registry/coordinator without creating a second active-session owner; keep picker, Host Control, transport, media, input, first-frame and cloud truth fail closed.
- S1-05A: native HarmonyOS GameController listener plus narrow typed NAPI; ArkTS remains a view/controller surface only.
- N2-09: real Sunshine + user ARM64 evidence for media, first frame, input, lifecycle, network, thermal and long-run behavior.

## Parked / blocked

- Keep Moonlight cloud sync parked: no `moonlightrecordv1`, table registration, selection, transfer or secret recovery.
- Register/execute `ohosTest` only after the project task is actually available; current blocker is `00306054` task-not-registered.
- A signed HAP build is verified, but Moonlight itself is not a release-ready streaming capability until the runtime and external gates above produce receipts.
