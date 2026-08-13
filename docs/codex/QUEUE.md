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
- Both mandatory Hvigor gates, both native ABIs, ELF isolation and all Moonlight host-native cases pass. Signed HAP SHA-256: `3ec6e5abb4c685d83097ce49793c408301679d8aed19f8376f611456b8a26d85`.
- Exact current HAP installed and started on phone `127.0.0.1:5555` and PC `127.0.0.1:5557`; fresh phone FAB/add-discovery and PC independent-category screenshots pass. The complete six-sheet phone/PC settings matrix was inspected in the same increment.

## Immediate next

1. Resolve or prove the API-23 Asset Store secure-identity runtime on the actual target; the current simulators return `hostControlReady=false`, while discovery/HTTP verification remain available.
2. Run N2-09 against a real Sunshine host: discovery → HTTP verify → pairing → catalog → launch → H.264/Opus first frame → input/controller → clean stop/reconnect.
3. Capture fresh real-host detail, catalog, connection, stream controls and virtual/physical-controller receipts on phone and PC layouts.
4. Record physical-controller arrival/state/remove receipts and confirm missing GameControllerKit degrades physical input only.
5. Remove the hidden legacy nine-route settings taxonomy/builders and complete any remaining Moonlight-only settings wiring without duplicating public display/PIP/host-management settings.
6. Complete network-change, rotation, foreground/background, thermal, two-hour and ARM64 acceptance before a release-ready Moonlight claim.

## Parked or externally blocked

- Moonlight cloud table and cloud synchronization remain parked by product decision.
- Current HDC targets are online and have the exact package; deployment/UI smoke is no longer blocked.
- The current simulators do not prove secure-identity/Host Control. A real Sunshine host, a secure-identity-capable target, physical controller and user ARM64 receipts are prerequisites for the remaining N2-09 path.
- `ohosTest` remains unavailable while task `00306054` is unregistered; compile success is not device-test execution.
- The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains unstaged and outside this queue.
