# Moonlight Complete Upgrade Queue

Updated: 2026-08-13 Asia/Shanghai

## Closed in the current working increment

- Product LAN discovery, verification, pairing, local host/trust persistence, local app cache, catalog refresh, launch and exact Catalog-to-Stream handoff.
- RustDesk-style FAB/add flow, phone host directory/detail/catalog/settings/stream pages and dedicated adaptive PC Moonlight tab.
- Official common-c session transport, conservative H.264 Surface video, Opus/OHAudio stereo, first-frame readiness and asynchronous stop terminal receipt.
- Session-owned keyboard, pointer, touch, virtual controller and physical GameControllerKit input; exact backpressure retry, remove-first source handoff and terminal neutral/cleanup.
- GameControllerKit activation-time dynamic loading. Both production ABIs are free of a mandatory GameControllerKit ELF dependency, preserving startup and unrelated-protocol isolation.
- Local rename/delete and app-cache cleanup with account/page/store fencing and partial-failure rollback.
- Two-layer release admission: FAB enables real LAN discovery/HTTP verification with compiled transport; PIN pairing separately requires secure identity/Host Control and fails closed before mutation when unavailable.
- API-23 credential-encrypted Asset Store add/query/remove/list and runtime probe lifecycle are proven on both simulators; concurrent environments cannot delete each other's live probe and crashed probes are reclaimed in progressing batches.
- Both mandatory Hvigor gates, both native ABIs, ELF isolation and all Moonlight host-native cases pass. Signed HAP SHA-256: `7e84303d06b33926fa702a2384584010612a2517b88aa38aad8d7e4c23096318`.
- Exact current HAP installed and started on phone `127.0.0.1:5555` and PC `127.0.0.1:5557`; both report all five Moonlight capability bits true and `blocker=none`. Fresh `7e84303d` FAB screenshots pass.

## Immediate next

1. S1-06: remove hidden legacy settings routes/builders and wire the remaining Moonlight-only reconnect/background/diagnostics controls without duplicating public display/PIP/volume/host-management settings.
2. Run N2-09B against a real Sunshine host: discovery → HTTP verify → pairing → catalog → launch → H.264/Opus first frame → input/controller → clean stop/reconnect.
3. Capture fresh real-host detail, catalog, connection, stream controls and virtual/physical-controller receipts on phone and PC layouts.
4. Record physical-controller arrival/state/remove receipts and confirm missing GameControllerKit degrades physical input only.
5. Complete network-change, rotation, foreground/background, thermal, two-hour and ARM64 acceptance before a release-ready Moonlight claim.

## Parked or externally blocked

- Moonlight cloud table and cloud synchronization remain parked by product decision.
- Current HDC targets are online and have the exact package; deployment/UI smoke is no longer blocked.
- Secure identity/Host Control is proven on both current simulators. A real Sunshine host, physical controller and user ARM64 receipts are prerequisites for the remaining N2-09B/C path.
- `ohosTest` remains unavailable while task `00306054` is unregistered; compile success is not device-test execution.
- The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains unstaged and outside this queue.
