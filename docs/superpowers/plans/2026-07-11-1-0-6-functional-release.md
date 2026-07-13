# 1.0.6 Functional Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver RemoteDesktop `1.0.6` with executable tests, truthful protocol actions, host organization, reliable content exchange, bidirectional text clipboard, and a one-time-per-version update Swiper.

**Architecture:** Keep native adapters as protocol transports and put visible availability in pure ArkTS policies. `GuidePage` remains the sole startup page and selects either the existing first-install tutorial, a registered release Swiper, or LoginPage from persisted version state. Transfer and clipboard state are session-scoped; an action remains disabled until its native callback and device evidence exist.

**Tech Stack:** ArkTS strict/API 23, ArkUI, Preferences, Hypium, NAPI/C++, FreeRDP 3.x, RustDesk FFI, libssh2 SFTP, CMake/Hvigor.

## Global Constraints

- Preserve the existing RDP/RustDesk renderer detach/reattach background rule; do not reconnect merely to recover a surface.
- Default every unknown protocol, absent callback, unavailable mount, or unverified peer to disabled.
- Do not expose VNC as connectable while `entry/src/main/cpp/vnc/vnc_adapter.cpp` remains mock-only.
- Search, diagnostics, clipboard logs, and transfer logs must never contain passwords, private keys, tokens, TOTP values, clipboard text, or raw local file paths.
- Keep SFTP at its existing 512 MiB file cap and 64 KiB chunk size for this release.
- Keep RDP graphics on the current stable single-display/GDI path; this release does not enable multi-display or RDPGFX.
- Do not change user-owned uncommitted files: `build-profile.json5`, `entry/oh-package.json5`, the FreeRDP submodule, old background-plan edits, `.superpowers/sdd/`, or `logs/`.
- Change `AppScope/app.json5` to `versionCode: 1000006` and `versionName: "1.0.6"` only in Task 8, after all release-note cards are backed by completed features.

---

## File Map

| File | Responsibility |
|---|---|
| `entry/src/main/ets/services/ReleaseNotesPolicy.ets` | Pure startup-mode and semantic-version decisions |
| `entry/src/main/ets/services/ReleaseNotesRegistry.ets` | Static, released-version page data only |
| `entry/src/main/ets/pages/GuidePage.ets` | Preferences integration and tutorial/release Swiper presentation |
| `entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets` | Closed protocol capability contract |
| `entry/src/main/ets/services/HostWorkspacePolicy.ets` | Host grouping, filtering, sorting and health display |
| `entry/src/main/ets/services/TransferSessionPolicy.ets` | Per-transfer lifecycle and cancellation decisions |
| `entry/src/main/ets/services/ClipboardSyncPolicy.ets` | Text validation, direction and echo prevention |
| `entry/src/main/cpp/extensions/extension_loader_napi.cpp` | Typed native session status and callback bridge |
| `entry/src/main/cpp/rdp/freerdp_adapter.*` | RDP drive/cliprdr truth and callbacks |
| `entry/src/main/cpp/rustdesk/rustdesk_bridge.*` | RustDesk transfer/clipboard callbacks |
| `rustdesk_ffi/src/connector.rs` | RustDesk protocol receive dispatch |

---

### Task 1: Restore the Executable Acceptance Baseline

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets:2611-2660`
- Modify: `entry/src/main/cpp/test/test_main.cpp`
- Modify: `entry/src/test/cpp/extension_registry_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt:123-154`
- Create: `docs/test-results/1.0.6-baseline.md`

**Consumes:** Current `default@OhosTestBuildArkTS` failure at `HostListPage.ets:2627:11` and the standalone extension-registry test.

**Produces:** ArkTS test compilation proceeds past HostListPage; `rdp_native_tests` runs registry assertions rather than leaving them in a separate executable.

- [ ] **Step 1: Capture the current failure before editing**

Run:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME=$env:DEVECO_SDK_HOME
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS --analyze=normal --parallel --incremental --daemon
```

Record the first compiler diagnostic, the SourceMap follow-on error, current commit SHA, and command in `docs/test-results/1.0.6-baseline.md`.

- [ ] **Step 2: Make the registry test callable from the shared runner**

Replace the second `main()` in `entry/src/test/cpp/extension_registry_test.cpp` with:

```cpp
void runExtensionRegistryTests() {
    std::cout << "=== Extension Registry 单元测试 ===" << std::endl;
    test_register_and_get();
    test_get_by_name();
    test_list_names();
    test_unregister();
    test_extension_system_singleton();
}
```

Declare `void runExtensionRegistryTests();` in `test_main.cpp` and call it before `return runAllTests();`. Add `test/cpp/extension_registry_test.cpp` to the `rdp_native_tests` source list in `CMakeLists.txt`.

- [ ] **Step 3: Isolate and repair the HdsTabs parser failure**

Keep all four `TabContent` children unchanged. Move the phone/Pad `HdsTabs` configuration chain into a single builder expression that begins with `HdsTabs({ controller: this.tabsCtrl })` and ends after the `.onChange(...)` callback, leaving no standalone component modifier after the builder closes. Preserve the current values: overlap enabled, horizontal pan gesture distance `10`, bottom bar height `64`, floating widths `280/320/380`, animation duration `300`, and handedness support.

Run the ArkTS target again. Expected: no diagnostic at `HostListPage.ets:2627:11`; if another source diagnostic occurs, append it as a separate failure in the baseline report.

- [ ] **Step 4: Build and run the registered native suite**

Configure the existing host target with `RDP_BUILD_TESTS=ON`, run `rdp_native_tests`, and record the named registry cases in the baseline report. Do not report historical test counts as current evidence.

- [ ] **Step 5: Commit the baseline increment**

```bash
git add entry/src/main/ets/pages/HostListPage.ets entry/src/main/cpp/test/test_main.cpp entry/src/test/cpp/extension_registry_test.cpp entry/src/main/cpp/CMakeLists.txt docs/test-results/1.0.6-baseline.md
git commit -m "test: restore 1.0.6 acceptance baseline"
```

### Task 2: Establish the Closed Capability Contract

**Files:**
- Create: `entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets`
- Create: `entry/src/test/RemoteSessionCapabilityPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`
- Modify: `entry/src/main/ets/components/RemoteSessionTopBar.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/cpp/vnc/vnc_adapter.cpp`

**Consumes:** Connection state and native facts created by later transfer/clipboard tasks.

**Produces:** One ArkTS object determines every enabled top-bar, file and clipboard action.

- [ ] **Step 1: Write failing policy tests**

```ts
expect(resolveSessionCapabilities({ protocol: 'vnc', connected: false, rdpDriveMounted: false,
  sftpConnected: false, rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false }).connect.enabled).assertFalse();
expect(resolveSessionCapabilities({ protocol: 'rdp', connected: true, rdpDriveMounted: false,
  sftpConnected: false, rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false }).fileUpload.enabled).assertFalse();
expect(resolveSessionCapabilities({ protocol: 'ssh', connected: true, rdpDriveMounted: false,
  sftpConnected: true, rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false }).fileDownload.enabled).assertTrue();
```

Register `RemoteSessionCapabilityPolicy.test.ets` in `List.test.ets`.

- [ ] **Step 2: Implement the policy interfaces**

```ts
export interface SessionCapabilityState {
  protocol: 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | string;
  connected: boolean;
  rdpDriveMounted: boolean;
  sftpConnected: boolean;
  rustDeskVerifiedPeer: boolean;
  rustDeskInboundClipboard: boolean;
  rustDeskTransferConfirmed: boolean;
}
export interface CapabilityAvailability { enabled: boolean; reason: string; }
export interface RemoteSessionCapabilities {
  connect: CapabilityAvailability; clipboardSend: CapabilityAvailability;
  clipboardReceive: CapabilityAvailability; fileUpload: CapabilityAvailability;
  fileDownload: CapabilityAvailability; multiDisplay: CapabilityAvailability;
}
export function resolveSessionCapabilities(state: SessionCapabilityState): RemoteSessionCapabilities;
```

Every returned field is disabled unless its protocol-specific prerequisites are true. `vnc` always returns disabled with the reason `当前版本尚未提供 VNC 连接支持`.

- [ ] **Step 3: Consume the same result in all visible actions**

Replace `RUSTDESK_ENABLED_ACTIONS` membership as the source of truth with the resolved availability. Before opening a picker, starting local clipboard monitoring, sending a file, or rendering a success toast in `RemoteDesktop.ets`, resolve the same session facts and show the returned reason if disabled.

Change `VncAdapter::connect()` to leave the adapter disconnected, call its state callback with `"VNC is not supported"`, and return `-95`; change `protocolVersion()` to `"unsupported"` and both codec queries to report no codecs.

- [ ] **Step 4: Verify the contract**

Run the focused Hypium registration and manually check RDP without a drive, SSH with SFTP, RustDesk without inbound clipboard, and VNC. Each disabled action must be inert and show its specific reason.

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets entry/src/test/RemoteSessionCapabilityPolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets entry/src/main/ets/components/RemoteSessionTopBar.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/cpp/vnc/vnc_adapter.cpp
git commit -m "feat(session): expose verified capability availability"
```

### Task 3: Deliver the Host Workbench

**Files:**
- Create: `entry/src/main/ets/services/HostWorkspacePolicy.ets`
- Create: `entry/src/test/HostWorkspacePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/HostListFilterService.ets`
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`

**Consumes:** Existing `RemoteHost` persistence fields and `HostSyncService.updateHost(host)`.

**Produces:** Persisted favorites, groups, deterministic sort modes, recent hosts and readable health cards without a database migration.

- [ ] **Step 1: Write policy tests**

```ts
expect(sortHosts(hosts, HostSortMode.FAVORITES_FIRST)[0].id).assertEqual('favorite');
expect(sortHosts(hosts, HostSortMode.RECENT)[0].id).assertEqual('recent');
expect(filterHostsByWorkspace(hosts, 'ops').length).assertEqual(2);
expect(searchHosts(hosts, 'admin')[0].id).assertEqual('user-match');
expect(displayConnectionHealth(ConnectionHealth.HEALTHY, 34)).assertEqual('连接正常 · 34 ms');
```

- [ ] **Step 2: Implement the pure workspace policy**

```ts
export enum HostSortMode { FAVORITES_FIRST = 'favorites', RECENT = 'recent', MANUAL = 'manual', NAME = 'name' }
export function normalizeGroupId(value: string): string;
export function groupIdsForHosts(hosts: RemoteHost[]): string[];
export function sortHosts(hosts: RemoteHost[], mode: HostSortMode): RemoteHost[];
export function filterHostsByWorkspace(hosts: RemoteHost[], groupId: string): RemoteHost[];
export function displayConnectionHealth(health: ConnectionHealth, latencyMs: number): string;
```

`searchHosts` must include `label`, `host`, `username`, `protocol`, and normalized `groupId`; it must not touch credential fields.

- [ ] **Step 3: Add persistence-safe HostSync methods**

Add `toggleFavorite(hostId: string): boolean`, `setGroup(hostId: string, groupId: string): boolean`, and `setSortOrder(hostId: string, sortOrder: number): boolean`. Each method clones the host, invokes `updateHost`, mutates the map only after success, and emits one data-change event.

- [ ] **Step 4: Wire the host page in focused builders**

Add `HostWorkspaceFilterBar`, `HostGroupChip`, `HostQuickActions`, and `HostConnectionHealth` builders. Preserve existing connection routes, lock gate, certificate sheets and SSH preflight. The release UI supports star/unstar, group assignment, sort mode, recent filter, and health text; it does not add drag reorder or import/export.

- [ ] **Step 5: Verify and commit**

Device sequence: add host → favorite → group `ops` → close/reopen → filter `ops` → reconnect → verify recent/health. Then commit:

```bash
git add entry/src/main/ets/services/HostWorkspacePolicy.ets entry/src/test/HostWorkspacePolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/services/HostListFilterService.ets entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/pages/HostListPage.ets
git commit -m "feat(hosts): add workspace organization"
```

### Task 4: Introduce Session-Scoped Transfer Semantics

**Files:**
- Create: `entry/src/main/ets/services/TransferSessionPolicy.ets`
- Create: `entry/src/test/TransferSessionPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/FileTransferProgressModel.ets`
- Modify: `entry/src/main/ets/pages/SshTerminal.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Consumes:** Existing `writeRemoteFileChunk`, `readRemoteFileChunk`, RDP shared-drive staging and RustDesk send entry points.

**Produces:** Transfer records cannot misreport unconfirmed remote work as complete.

- [ ] **Step 1: Add lifecycle tests**

```ts
expect(canTransition('preparing', 'transferring')).assertTrue();
expect(canTransition('waitingRemote', 'completed')).assertTrue();
expect(canTransition('completed', 'transferring')).assertFalse();
expect(cancelTransfer({ stage: 'transferring', canCancel: true }).stage).assertEqual('cancelled');
```

- [ ] **Step 2: Implement the transfer contract**

```ts
export type TransferStage = 'preparing' | 'transferring' | 'waitingRemote' | 'completed' | 'failed' | 'cancelled';
export interface TransferSession {
  id: string; protocol: 'ssh' | 'rdp' | 'rustdesk'; direction: 'upload' | 'download';
  fileName: string; totalBytes: number; transferredBytes: number; stage: TransferStage;
  canCancel: boolean; diagnosticCode: string;
}
export function canTransition(from: TransferStage, to: TransferStage): boolean;
export function cancelTransfer(session: TransferSession): TransferSession;
```

- [ ] **Step 3: Migrate SFTP first**

Replace page-local `sftpBusy` completion decisions with one active `TransferSession`. At each 64 KiB read/write boundary, check the cancellation flag before the next native call. Retry creates a new session from the recorded offset; download resume appends at the known local byte count, upload resume continues at the remote confirmed offset. Preserve the 512 MiB guard before opening a descriptor.

- [ ] **Step 4: Gate RDP and RustDesk until their evidence exists**

RDP may stage only after Task 5 reports mounted. RustDesk remains `waitingRemote` after its final chunk until Task 5 supplies a typed confirmation callback; no `completed` state may depend on `LAST_ERROR` text.

- [ ] **Step 5: Verify and commit**

Run transition tests; device-test SSH upload/download/cancel/resume, RDP unavailable-drive, and RustDesk remote-confirmation timeout. Commit:

```bash
git add entry/src/main/ets/services/TransferSessionPolicy.ets entry/src/test/TransferSessionPolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/services/FileTransferProgressModel.ets entry/src/main/ets/pages/SshTerminal.ets entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "feat(transfer): add session-scoped transfer state"
```

### Task 5: Bridge Native Drive and RustDesk Transfer Truth

**Files:**
- Modify: `entry/src/main/cpp/extensions/protocol_adapter.h`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Modify: `rustdesk_ffi/src/lib.rs`
- Modify: `rustdesk_ffi/src/connector.rs`

**Consumes:** `TransferSession` and capability policy contracts.

**Produces:** Per-session mounted-drive and RustDesk transfer-completion facts are queryable without parsing logs or global error strings.

- [ ] **Step 1: Write native-policy tests before exposing state**

Add fixture assertions for these transitions: RDP mount request → mounted, RDP mount error → unavailable, RustDesk transfer id `42` → progress `4096/8192`, RustDesk transfer id `42` → completed, and RustDesk transfer id `42` → failed with non-secret code.

- [ ] **Step 2: Define typed adapter status**

```cpp
enum class TransferRuntimeState { UNAVAILABLE, READY, TRANSFERRING, CONFIRMED, FAILED };
struct SessionTransferStatus {
    bool rdpDriveMounted = false;
    TransferRuntimeState rustdeskTransfer = TransferRuntimeState::UNAVAILABLE;
    uint64_t transferId = 0;
    uint64_t transferredBytes = 0;
    uint64_t totalBytes = 0;
    std::string diagnosticCode;
};
```

Expose `getSessionTransferStatus(sessionId)` through NAPI as an object with booleans, numeric counters and diagnostic code only. `FreeRdpAdapter::mountDriveAfterConnected` sets `rdpDriveMounted=true` only after `CHANNEL_RC_OK`; failure leaves the desktop connection state unchanged.

- [ ] **Step 3: Replace RustDesk global completion inference**

Carry a generated transfer id through ArkTS → NAPI → `RustDeskBridge` → FFI. `connector.rs` emits progress/completed/failed events with that id; `rustdesk_bridge.cpp` stores the latest state per active session; `LAST_ERROR` remains diagnostics only and cannot determine completion.

- [ ] **Step 4: Wire facts into Tasks 2 and 4**

`ExtensionLoader` converts the NAPI object into an explicit ArkTS interface. `RemoteDesktop` refreshes capability state after connection state changes and transfer callbacks; an RDP upload is enabled only when `rdpDriveMounted`, and RustDesk becomes complete only when its current id is `CONFIRMED`.

- [ ] **Step 5: Build both Rust targets, verify and commit**

Build `rustdesk_ffi` for arm64 and x86_64, then run native fixtures and production HAP build. Device-test RDP `\\tsclient\\RemoteDesktop` visibility/read/write plus RustDesk upload/progress/cancel/completion. Commit:

```bash
git add entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/cpp/rdp/freerdp_adapter.h entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/rustdesk/rustdesk_bridge.h entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "feat(transfer): report verified protocol transfer state"
```

### Task 6: Enable Verified Bidirectional Text Clipboard

**Files:**
- Create: `entry/src/main/ets/services/ClipboardSyncPolicy.ets`
- Create: `entry/src/test/ClipboardSyncPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/ClipboardBridgeService.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.*`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.*`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `rustdesk_ffi/src/connector.rs`

**Consumes:** Capability contract and native callback bridge from Task 5.

**Produces:** RDP/RustDesk text clipboard receive is enabled only after active callback installation, with no echo loops.

- [ ] **Step 1: Add pure policy tests**

```ts
expect(shouldForwardClipboard({ source: 'local', sendEnabled: true, receiveEnabled: true })).assertTrue();
expect(shouldForwardClipboard({ source: 'remote', sendEnabled: true, receiveEnabled: false })).assertFalse();
expect(shouldForwardClipboard({ source: 'remoteEcho', sendEnabled: true, receiveEnabled: true })).assertFalse();
expect(validateClipboardText('x'.repeat(MAX_CLIPBOARD_TEXT_CHARS)).ok).assertTrue();
```

- [ ] **Step 2: Implement the explicit ArkTS contract**

```ts
export const MAX_CLIPBOARD_TEXT_CHARS = 65536;
export type ClipboardSource = 'local' | 'remote' | 'remoteEcho';
export interface ClipboardForwardInput { source: ClipboardSource; sendEnabled: boolean; receiveEnabled: boolean; }
export interface ClipboardValidation { ok: boolean; diagnosticCode: string; }
export function shouldForwardClipboard(input: ClipboardForwardInput): boolean;
export function validateClipboardText(text: string): ClipboardValidation;
```

Attach a monotonic source token to local writes so the matching Pasteboard change returns `remoteEcho` and is never forwarded again.

- [ ] **Step 3: Implement RDP cliprdr and RustDesk receive callbacks**

For RDP, send only after the negotiated cliprdr channel is ready and dispatch validated incoming Unicode text from the channel callback. For RustDesk, parse clipboard receive messages in `connector.rs`, pass bytes and session identity through FFI/C++/NAPI, and invoke an ArkTS callback registered for that session. Neither path logs text content.

- [ ] **Step 4: Wire user toggles and capability facts**

`RemoteDesktop` registers callbacks only for a connected active session, writes remote text to the local Pasteboard with its remote source token, and updates `rustDeskInboundClipboard` only after callback registration succeeds. Disabled send/receive keeps the existing local clipboard unchanged.

- [ ] **Step 5: Verify and commit per protocol boundary**

Device-test each direction, disabled send, disabled receive, 65,537-character text, unavailable Pasteboard, reconnect and two-peer echo for RDP and RustDesk. Use separate commits:

```bash
git commit -m "feat(rdp): enable verified text clipboard"
git commit -m "feat(rustdesk): receive verified text clipboard"
```

### Task 7: Add Version-Gated Release Notes to GuidePage

**Files:**
- Create: `entry/src/main/ets/services/ReleaseNotesPolicy.ets`
- Create: `entry/src/main/ets/services/ReleaseNotesRegistry.ets`
- Create: `entry/src/test/ReleaseNotesPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/pages/GuidePage.ets`

**Consumes:** Confirmed feature set from Tasks 1–6 and existing `RemoteDesktopAppPrefs` tutorial marker.

**Produces:** Existing users see the actual current-version update once after upgrade; new installs see only the tutorial.

- [ ] **Step 1: Write mode-selection tests**

```ts
expect(resolveStartupMode(false, '', '1.0.6', true)).assertEqual(StartupMode.FIRST_INSTALL_GUIDE);
expect(resolveStartupMode(true, '1.0.5', '1.0.6', true)).assertEqual(StartupMode.RELEASE_NOTES);
expect(resolveStartupMode(true, '1.0.6', '1.0.6', true)).assertEqual(StartupMode.LOGIN);
expect(resolveStartupMode(true, '1.0.6', '1.0.5', true)).assertEqual(StartupMode.LOGIN);
```

- [ ] **Step 2: Implement policy and registry interfaces**

```ts
export enum StartupMode { FIRST_INSTALL_GUIDE, RELEASE_NOTES, LOGIN }
export interface ReleaseNotePage { symbol: ResourceStr; title: string; desc: string; }
export function compareReleaseVersion(left: string, right: string): number;
export function resolveStartupMode(guideShown: boolean, lastSeen: string, current: string,
  hasCurrentReleaseNotes: boolean): StartupMode;
export function pagesForReleasedVersion(version: string): ReleaseNotePage[];
```

`compareReleaseVersion` parses exactly three non-negative numeric components. Invalid data returns no release mode. The registry contains only the current release’s completed cards plus the fixed welcome card; it has no future release entries.

- [ ] **Step 3: Refactor GuidePage without changing tutorial appearance**

Keep the existing tutorial `pages`, Swiper layout, color palette, icon card, pagination and safe-area behavior. Add a `mode` state and select pages from the registry in release mode. First-install completion writes both `guide_shown_v4=true` and `last_seen_release_version=currentVersion`; release-mode completion writes only `last_seen_release_version=currentVersion`. Release mode has previous/next buttons and final `继续`, with no skip or close action.

- [ ] **Step 4: Verify persistence behavior**

Run tests, then on device test: fresh install; upgrade from seen `1.0.5`; force-close on the first release page; complete release notes; restart the same build; and simulate a version lower than the stored marker. Record each expected mode in `docs/test-results/1.0.6-release-notes.md`.

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/services/ReleaseNotesPolicy.ets entry/src/main/ets/services/ReleaseNotesRegistry.ets entry/src/test/ReleaseNotesPolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/pages/GuidePage.ets docs/test-results/1.0.6-release-notes.md
git commit -m "feat(release): show updates once per version"
```

### Task 8: Finalize Version 1.0.6 and Release Evidence

**Files:**
- Modify: `AppScope/app.json5`
- Modify: `entry/src/main/ets/services/ReleaseNotesRegistry.ets`
- Modify: `docs/DEVICE_VERIFICATION_CHECKLIST.md`
- Create: `docs/test-results/1.0.6-release-evidence.md`

**Consumes:** Passed functional tasks and their device records.

**Produces:** Version identifiers, release cards and verification evidence describe the same source revision.

- [ ] **Step 1: Freeze the release-card content from evidence**

Use at most these three earned cards before the welcome page: `能力状态更清晰`, `主机工作台`, and `可靠传输与剪贴板`. Remove any card whose corresponding Task 2–6 record lacks a passing automatic test and device success/failure result. Do not replace a removed card with a planned feature.

- [ ] **Step 2: Change both version fields**

```json5
"versionCode": 1000006,
"versionName": "1.0.6"
```

- [ ] **Step 3: Run the final release matrix**

Run ArkTS tests, registered native tests, Rust tests required by changed FFI, and production `assembleHap`. Record commit SHA, commands, result counts, HAP checksum, host-workbench persistence, SFTP transfer cases, RDP drive cases, RustDesk transfer cases, clipboard cases, and release-Swiper cases in `1.0.6-release-evidence.md`.

- [ ] **Step 4: Commit the version only after all records agree**

```bash
git add AppScope/app.json5 entry/src/main/ets/services/ReleaseNotesRegistry.ets docs/DEVICE_VERIFICATION_CHECKLIST.md docs/test-results/1.0.6-release-evidence.md
git commit -m "release: prepare version 1.0.6"
```

## Plan Self-Review

- Spec coverage: startup/update behavior is Task 7; executable baseline is Task 1; capability truth is Task 2; host organization is Task 3; reliable transfer is Tasks 4–5; clipboard is Task 6; versioning and truth-bound update copy are Task 8.
- Dependencies: Task 1 precedes all acceptance claims; Task 2 gates every visible action; Task 4 defines lifecycle before Task 5 supplies native facts; Task 6 consumes Task 5’s callback bridge; Task 8 is last.
- Safety: no task promotes a protocol function from UI presence alone; RDP drive and RustDesk completion require native facts, VNC remains unsupported, and copy is generated only from passed release evidence.
- Type consistency: `SessionCapabilityState`, `TransferSession`, `SessionTransferStatus`, `ClipboardForwardInput`, `StartupMode`, and `ReleaseNotePage` are defined before consuming tasks and use the same field names throughout.
