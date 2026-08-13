# Moonlight Complete Upgrade Queue

Updated: 2026-08-13 Asia/Shanghai

## Closed in the current working increment

- Product LAN discovery, verification, pairing, local host/trust persistence, local app cache, catalog refresh, launch and exact Catalog-to-Stream handoff.
- RustDesk-style FAB/add flow, phone host directory/detail/catalog/settings/stream pages and dedicated adaptive PC Moonlight tab.
- Official common-c session transport, conservative H.264 Surface video, Opus/OHAudio stereo, first-frame readiness and asynchronous stop terminal receipt.
- Session-owned keyboard, pointer, touch, virtual controller and physical GameControllerKit input; exact backpressure retry, remove-first source handoff and terminal neutral/cleanup.
- GameControllerKit activation-time dynamic loading. Both production ABIs are free of a mandatory GameControllerKit ELF dependency, preserving startup and unrelated-protocol isolation.
- Local rename/delete and app-cache cleanup with account/page/store fencing and partial-failure rollback.
- Both mandatory Hvigor gates, both native ABIs, ELF isolation and all Moonlight host-native cases pass. Signed HAP SHA-256: `8301133af6083c992e2a93f7bd504ef351491bbca3c1103faf12b80cf2150a2b`.

## Immediate next

1. Restore an online HDC target and install the current signed HAP on both PC and phone form factors.
2. Capture only fresh screenshots for FAB, local host directory, detail, catalog, settings bindSheets, connection stage, stream controls and virtual controller.
3. Run N2-09 against a real Sunshine host: discovery → pairing → catalog → launch → H.264/Opus first frame → input/controller → clean stop/reconnect.
4. Record physical-controller arrival/state/remove receipts and confirm missing GameControllerKit degrades physical input only.
5. Wire and verify the remaining Moonlight-specific settings; do not duplicate public display/PIP/host-management settings.
6. Complete network-change, rotation, foreground/background, thermal, two-hour and ARM64 acceptance before a release-ready Moonlight claim.

## Parked or externally blocked

- Moonlight cloud table and cloud synchronization remain parked by product decision.
- Current HDC targets `127.0.0.1:5555` and `127.0.0.1:5557` are Offline and rejected reconnect on 2026-08-13; current-package deployment and fresh UI acceptance are pending.
- A real Sunshine host, physical controller and user ARM64 device receipts are external prerequisites for N2-09.
- `ohosTest` remains unavailable while task `00306054` is unregistered; compile success is not device-test execution.
- The user-owned `entry/src/main/ets/services/CloudStore.ets` diff remains unstaged and outside this queue.
