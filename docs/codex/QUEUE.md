# Moonlight Complete Upgrade Queue

Updated: 2026-08-12 Asia/Shanghai

## Closed checkpoint

- `6b0c1aa8` closes the local-only U1-06～U1-12 UI shell and its review fixes: homepage host management, host detail, per-host app catalog, nine-section settings, RustDesk-style launch/connection/stream overlays, desktop sidebar slot, and fresh PC/phone evidence.
- `8b1ccd22` closes S1-01/S1-02 as a dormant contract checkpoint: Moonlight is represented in the shared session/capability model and is coordinated through the single existing active-session registry with owner/account/operation fences. The runtime port is intentionally absent, so no real connection can start.
- `4548499c` closes the review fixes: atomic reservation/promotion prevents cross-protocol overwrite, prelaunch cancel and stop failure/timeout have local-terminal cleanup, and post-launch events require the matching native session ID.
- `647113a5` adds the actual stop watchdog and corrects the prelaunch-cancel contract test; the reused reviewer task rechecked the complete S1 delta and returned PASS with no actionable findings.
- The coordinator now has nine focused cases for runtime gating, cross-protocol arbitration, transient endpoint isolation, surface/first-frame ordering, stale events, stop cleanup, stop timeout, native-session mismatch and account-scope invalidation. `MoonlightStreamPage` subscribes to account changes and cancels route-owned work.
- The final incremental review reused task `019fe966-d99a-7ce1-8b53-4ef725597053` and passed with P0/P1/P2/P3 all zero. Legacy-read/new-write settings compatibility, forced-safe certificate controls, local-commit truth, stream timer fencing, and tintable desktop icon findings are closed.
- Latest fresh `final4` evidence was captured only after installing the final signed HAP; no old screenshot is used for the final acceptance record. It covers the PC large-screen sidebar/picker, phone root/picker, disabled-click, settings, Moonlight accordion and Quick Settings bindSheet.
- Homepage owns Moonlight host management. Moonlight settings has no duplicate host-management row and no duplicated shared display/PIP options.
- FAB and sidebar remain explicitly disabled (`moonlightProtocolAvailable=false`); UI shell components do not open transport, native, timer, repository, cloud, or background work.
- Both mandatory Hvigor gates, signed HAP generation, sandbox-external HDC install/start on PC and phone, `git diff --check`, and static cross-protocol isolation review pass.
- User-owned `CloudStore.ets` remains the sole unstaged change and is not part of this task.

## Next

- S1-03: connect-stage overlay contract and stage/error presentation; keep it bound to coordinator snapshots and do not claim `connected` before first frame.
- S1-04/S1-05A: session toolbar/control center and native HarmonyOS GameController listener plus narrow typed NAPI; ArkTS remains a view/controller surface only.
- S1-05A: native HarmonyOS GameController listener plus narrow typed NAPI; ArkTS remains a view/controller surface only.
- N2-09: real Sunshine + user ARM64 evidence for media, first frame, input, lifecycle, network, thermal and long-run behavior.

## Parked / blocked

- Keep Moonlight cloud sync parked: no `moonlightrecordv1`, table registration, selection, transfer or secret recovery.
- Register/execute `ohosTest` only after the project task is actually available; current blocker is `00306054` task-not-registered.
- A signed HAP build is verified, but Moonlight itself is not a release-ready streaming capability until the runtime and external gates above produce receipts.
