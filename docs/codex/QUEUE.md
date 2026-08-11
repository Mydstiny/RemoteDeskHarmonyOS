# Moonlight Complete Upgrade Queue

Updated: 2026-08-11 Asia/Shanghai

## Now

- `2c37b0edf` closes the local-only U1-06～U1-12 UI shell: host detail, app catalog, add-save handoff, nine-section settings, RustDesk-style launch/connection/stream overlays, desktop sidebar slot, and fresh PC/phone evidence.
- Homepage owns Moonlight host management. Moonlight settings no longer contains a duplicate host-management entry or shared display/PIP settings.
- FAB and sidebar remain explicitly disabled (`moonlightProtocolAvailable=false`); UI shell components do not open transport, native, timer, repository, cloud, or background work.
- Both mandatory Hvigor gates and signed HAP generation pass. Fresh HDC install/start passed on PC and phone; no old screenshot is used.
- User-owned `CloudStore.ets` remains the sole unstaged change and is not part of this task.

## Next

- S1-01/S1-02: connect the dormant local UI shell to the existing remote-session registry/coordinator contracts without creating a second active-session owner.
- S1-05A: native HarmonyOS GameController listener plus narrow typed NAPI; ArkTS remains a view/controller surface only.
- N2-09: real Sunshine + user ARM64 evidence for media, first frame, input, lifecycle, network, thermal and long-run behavior.

## Later

- Keep Moonlight cloud sync parked: no `moonlightrecordv1`, table registration, selection, transfer or secret recovery.
- Register/execute `ohosTest` only after the project task is actually available; do not convert compile registration into device PASS.
