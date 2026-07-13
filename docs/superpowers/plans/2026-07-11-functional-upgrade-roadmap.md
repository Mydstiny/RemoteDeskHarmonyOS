# RemoteDesktop Functional Upgrade Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a truthful, production-oriented remote-work experience: users can organize hosts, see only capabilities that genuinely work, exchange text and files safely, and understand background-session state.

**Architecture:** Keep `ProtocolAdapter` as the native session transport seam, but place user-facing capability truth in small ArkTS policies that combine protocol, runtime feature gates, and verified device support. Reuse existing `RemoteHost` persistence fields and SFTP/transfer flows; extract only the policy and presentation units that need independent tests instead of rewriting the active RDP/RustDesk render pipelines.

**Tech Stack:** ArkTS strict/API 23, ArkUI, existing NAPI bridge, FreeRDP 3.x, RustDesk FFI, libssh2/SFTP, OHAudio, Hypium, lightweight C++ policy tests.

## Global Constraints

- Preserve the existing RDP/RustDesk background restore rule: detach/reattach renderer without protocol reconnect unless protocol loss is proven.
- Treat all capability claims as false until the complete user path has code, automated coverage, and device evidence.
- Do not surface VNC as connectable while `vnc_adapter.cpp` remains a mock.
- Do not advertise microphone, recording, chat, virtual display, TCP tunnel, multi-display, remote clipboard receive, or file download until their protocol paths work end-to-end.
- High-risk operations—direct RustDesk access, clipboard, file transfer, microphone, credential use—must default to disabled when identity, permission, or state cannot be verified.
- Do not move the user’s existing uncommitted configuration, FreeRDP, or historical-plan changes into feature commits.
- No release may pass while sensitive cloud fields can fall back to plaintext, account data is not owner-isolated, or signing/AGC secrets remain exposed; these are release gates, not scope expansion for this feature plan.

---

## Evidence-Based Scope

| Capability | Code state | User-facing decision |
|---|---|---|
| SSH SFTP browse/upload/download | Implemented with 64 KiB loops and 512 MiB limit | Improve and extract into shared transfer UX; do not rewrite transport first |
| RDP shared drive | UI copy path exists but runtime gate is off; no remote-visible evidence | Hide from normal flow until mount and remote visibility are device-verified |
| RustDesk file upload | Upload-only, whole-file memory buffer, 100 MiB limit, text-polled status | Label as experimental until stream/download/cancel/verified completion exist |
| RDP clipboard | Local cache only; no `cliprdr` consumer/producer path | Show disabled with a precise reason |
| RustDesk clipboard | Local-to-remote send path, inbound messages dropped | Do not label as bidirectional; implement inbound before enabling sync |
| Host favorites/groups/sort/history/health | Persisted in `RemoteHost`/`CloudStore`; not shown or operated | First low-risk, user-visible feature package |
| Background restore | Renderer detach/reattach, cached RDP frame and decoder recovery are implemented | Productize state visibility and negative-path testing; retain existing transport path |
| Multi-display | RDP forcibly disables it; RustDesk handles display 0 only | Hide setting and defer |
| VNC | Registered mock returns connected | Keep outside all user flows; return unsupported in a dedicated hardening task |

## Delivery Order

1. **Release gate A — executable test baseline.** Fix the ArkTS test-target parse/SourceMap failure before accepting any feature completion; do not confuse an `assembleHap` pass with test coverage.
2. **Wave 1 — capability truth and host workbench.** Make settings/topbar/file actions accurately report state, then expose persisted favorites, groups, sort, recent connections and health.
3. **Wave 2 — reliable content exchange.** Build a reusable transfer session model around the working SFTP flow, then close RDP and RustDesk transfer gaps; implement pure-text bidirectional clipboard only after actual receive callbacks exist.
4. **Wave 3 — session continuity as a product feature.** Replace page-local status booleans with the existing state model, expose background/restore states, and complete the device matrix.
5. **Wave 4 — PC usability.** Keyboard-first navigation, accessibility semantics, localized strings and explicit PC/2in1 support.
6. **Deferred protocol tracks.** Secure multi-display, microphone, VNC/RFB, recording, chat, tunnels, camera and enterprise redirections start only as separate specs after their prerequisites are met.

## Workstream Boundaries

| Workstream | Primary files | Independent deliverable |
|---|---|---|
| Test baseline | `entry/src/ohosTest`, `entry/src/test`, `HostListPage.ets`, build configuration | Repeatable ArkTS/native/Rust test reports for the current commit |
| Capability truth | `RemoteSessionTopBarPolicy.ets`, `RemoteDesktop.ets`, `ExtensionLoader.ets` | No control appears enabled unless its full path is usable |
| Host workbench | `RemoteHost.ets`, `CloudStore.ets`, `HostSyncService.ets`, `HostListFilterService.ets`, `HostListPage.ets` | Favorites/groups/sort/recent/health usable and persisted |
| Content exchange | `SshTerminal.ets`, `RemoteDesktop.ets`, transfer services, native adapters | SFTP reliable; RDP/RustDesk actions safely gated and later independently promoted |
| Clipboard | `ClipboardBridgeService.ets`, RDP adapter, RustDesk FFI/bridge | Bidirectional plain-text sync with direction/permission controls |
| Background productization | `RemoteSessionState.ets`, `ActiveRemoteSessionRegistry.ets`, `RemoteDesktop.ets`, background services | Visible, testable preserve/restore/error state without reconnect regressions |
| PC/accessibility/i18n | `EntryAbility.ets`, `HostListPage.ets`, `RemoteDesktop.ets`, resources | Keyboard and screen-reader usable layouts on supported form factors |

---

### Task 1: Restore the Feature Acceptance Baseline

**Files:**
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets` only after isolating the parser failure
- Modify: `entry/src/main/cpp/CMakeLists.txt`
- Modify: `docs/DEVICE_VERIFICATION_CHECKLIST.md`
- Create: `docs/test-results/current-baseline.md`

**Consumes:** The current failing `default@OhosTestBuildArkTS` target and the existing ArkTS/native test aggregators.

**Produces:** A repeatable report containing commit SHA, command, test count, failing test names, device matrix status, and generated HAP checksum. The CMake native target includes `entry/src/test/cpp/extension_registry_test.cpp` or an equivalent registered test.

- [ ] **Step 1: Reproduce the ArkTS failure without changing source**

Run the API 23 Hvigor test target recorded in `CODEWALK.md`; capture the first parser diagnostic and SourceMap error in `docs/test-results/current-baseline.md`.

Expected: either a precise source location to repair or a reproducible toolchain issue. Do not accept later diagnostics before the first syntax error is removed.

- [ ] **Step 2: Add a regression test before repairing the isolated policy/helper failure**

Keep page logic out of the test. Extract the malformed or over-complex expression into a pure service policy and register it in the existing test aggregator. Use this shape:

```ts
export function resolvesExpectedUiState(input: ExpectedUiStateInput): boolean {
  return input.pageActive && input.enabled && !input.backgrounded;
}
```

Add a Hypium assertion for each branch that was previously embedded in the page.

- [ ] **Step 3: Repair only the isolated source expression and rerun the target**

Run: `default@OhosTestBuildArkTS`.

Expected: the parser and SourceMap stages complete and registered tests run; if an unrelated test fails, record it separately rather than weakening the assertion.

- [ ] **Step 4: Register native contract tests in the CMake test executable**

Add the existing registry test source to `rdp_native_tests`, then configure/build the lightweight target with `RDP_BUILD_TESTS=ON` using the current dependency layout.

Expected: the native executable reports named pass/fail results and includes extension registry coverage.

- [ ] **Step 5: Commit the baseline only after tests and documentation agree**

Commit message: `test: restore functional upgrade acceptance baseline`.

### Task 2: Introduce Session Capability Truth

**Files:**
- Create: `entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets`
- Create: `entry/src/test/RemoteSessionCapabilityPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`
- Modify: `entry/src/main/ets/components/RemoteSessionTopBar.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Consumes:** Protocol name, current runtime gates, connection state, and verified transport support.

**Produces:** One capability object used by both the topbar and file/clipboard actions; unavailable controls show a reason and never invoke a misleading transport path.

- [ ] **Step 1: Write failing capability-policy cases**

Cover these mandatory cases:

```ts
expect(resolveSessionCapabilities({ protocol: 'rdp', rdpDriveMounted: false }).fileUpload.enabled)
  .assertFalse();
expect(resolveSessionCapabilities({ protocol: 'rustdesk', rustDeskInboundClipboard: false }).clipboardReceive.enabled)
  .assertFalse();
expect(resolveSessionCapabilities({ protocol: 'ssh', sftpConnected: true }).fileDownload.enabled)
  .assertTrue();
expect(resolveSessionCapabilities({ protocol: 'vnc' }).connect.enabled).assertFalse();
```

- [ ] **Step 2: Implement a closed capability contract**

Create these exact interfaces:

```ts
export interface SessionCapabilityState {
  protocol: string;
  connected: boolean;
  rdpDriveMounted: boolean;
  sftpConnected: boolean;
  rustDeskInboundClipboard: boolean;
  rustDeskVerifiedPeer: boolean;
}

export interface CapabilityAvailability {
  enabled: boolean;
  reason: string;
}

export interface RemoteSessionCapabilities {
  connect: CapabilityAvailability;
  clipboardSend: CapabilityAvailability;
  clipboardReceive: CapabilityAvailability;
  fileUpload: CapabilityAvailability;
  fileDownload: CapabilityAvailability;
  multiDisplay: CapabilityAvailability;
}
```

`resolveSessionCapabilities()` must default every unrecognized protocol or absent runtime proof to disabled.

- [ ] **Step 3: Use one capability source in the topbar and transfer entry points**

Replace the unconditional RustDesk enabled-action list with availability from `resolveSessionCapabilities()`. In `RemoteDesktop.ets`, call the same resolver before opening a document picker, starting clipboard monitoring, or showing a transfer success toast.

Expected: RDP file upload is disabled while the drive gate is off; RustDesk clipboard receive is disabled until its inbound callback exists; VNC cannot enter a session.

- [ ] **Step 4: Verify policy and UI smoke behavior**

Run the focused Hypium suite and manually check RDP, RustDesk, and SSH topbars on a device/emulator. Record screenshots and action reasons in `docs/test-results/current-baseline.md`.

- [ ] **Step 5: Commit the truthful capability contract**

Commit message: `feat(session): expose verified capability availability`.

### Task 3: Deliver the Host Workbench

**Files:**
- Create: `entry/src/main/ets/services/HostWorkspacePolicy.ets`
- Create: `entry/src/test/HostWorkspacePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/HostListFilterService.ets`
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/model/RemoteHost.ets` only if a missing serializable field is proven

**Consumes:** Existing persisted `isFavorite`, `groupId`, `sortOrder`, `lastConnected`, `lastHealth`, and `lastLatency` columns in `CloudStore`.

**Produces:** Favorites, named groups, deterministic sorting, a recent list, and connection-health display without a schema migration.

- [ ] **Step 1: Add failing pure-policy tests for filtering and sorting**

Required order rules:

```ts
expect(sortHosts(hosts, SortOrder.FAVORITES_FIRST)[0].id).assertEqual('favorite-host');
expect(sortHosts(hosts, SortOrder.RECENT)[0].id).assertEqual('most-recent-host');
expect(filterHostsByWorkspace(hosts, 'ops').length).assertEqual(2);
expect(searchHosts(hosts, 'admin')[0].id).assertEqual('matching-username-host');
```

The search policy must include label, host, username, protocol, and group label; it must not search passwords, private keys, tokens, or TOTP values.

- [ ] **Step 2: Implement `HostWorkspacePolicy` without changing storage**

Implement `normalizeGroupId`, `groupIdsForHosts`, `sortHosts`, `filterHostsByWorkspace`, and `displayConnectionHealth`. Use `groupId` as a normalized user-owned label in this release; do not add a separate groups table until cloud owner isolation and migration work is complete.

- [ ] **Step 3: Add focused HostSync operations**

Add `toggleFavorite(hostId: string)`, `setGroup(hostId: string, groupId: string)`, and `setSortOrder(hostId: string, order: number)` that clone the host, persist via the existing update path, and only update the in-memory map after persistence reports success.

- [ ] **Step 4: Wire HostListPage presentation in extracted builders**

Add compact builders/components for:

```ts
@Builder HostWorkspaceFilterBar()
@Builder HostGroupChip(groupId: string)
@Builder HostQuickActions(host: RemoteHost)
@Builder HostConnectionHealth(host: RemoteHost)
```

Keep the existing connection, lock, certificate and SSH-preflight routes intact. The first release supports star/unstar, group assignment, sort selector, recent filter, and a readable last-connected/health indicator; it does not add drag reorder, import/export, or destructive bulk edit.

- [ ] **Step 5: Verify persistence and cloud-safe behavior**

Run focused HostWorkspace and HostSync tests, then test add → favorite → group → close/reopen → reconnect on a device. Do not claim cross-device synchronization until owner-isolation and encryption gates are complete.

- [ ] **Step 6: Commit the independent workbench increment**

Commit message: `feat(hosts): add favorites groups and connection workspace`.

### Task 4: Extract Reliable Transfer Session Semantics

**Files:**
- Create: `entry/src/main/ets/services/TransferSessionPolicy.ets`
- Create: `entry/src/test/TransferSessionPolicy.test.ets`
- Modify: `entry/src/main/ets/services/FileTransferProgressModel.ets`
- Modify: `entry/src/main/ets/pages/SshTerminal.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`

**Consumes:** Existing SFTP chunks, RDP shared-drive copy flow, RustDesk upload invocation, and `FileTransferLiveTaskService`.

**Produces:** A session-scoped transfer state model that prevents conflicting transfers and tells users exactly whether a transfer is local staging, protocol upload, remote confirmation, completed, cancelled, or failed.

- [ ] **Step 1: Write transfer-state transition tests**

Use these transitions:

```ts
expect(canTransition('preparing', 'transferring')).assertTrue();
expect(canTransition('waitingRemote', 'completed')).assertTrue();
expect(canTransition('completed', 'transferring')).assertFalse();
expect(transferActionForCapability(disabledCapability).kind).assertEqual('blocked');
```

- [ ] **Step 2: Implement protocol-neutral transfer records**

Create exact fields:

```ts
export type TransferStage = 'preparing' | 'transferring' | 'waitingRemote' | 'completed' | 'failed' | 'cancelled';
export interface TransferSession {
  id: string;
  protocol: 'ssh' | 'rdp' | 'rustdesk';
  direction: 'upload' | 'download';
  fileName: string;
  totalBytes: number;
  transferredBytes: number;
  stage: TransferStage;
  canCancel: boolean;
  diagnosticCode: string;
}
```

Do not infer completion from a global error string after this task; the RustDesk path remains marked `waitingRemote` until a future typed native callback exists.

- [ ] **Step 3: Migrate SFTP UI first**

Replace page-local progress mutation in `SshTerminal.ets` with `TransferSessionPolicy` transitions. Preserve the 512 MiB safety limit and 64 KiB chunk size. Add an explicit cancel control that stops future chunks, closes the local descriptor, and keeps the partially written remote path visible as incomplete rather than reporting success.

- [ ] **Step 4: Gate RDP and RustDesk actions rather than overpromising**

RDP: only allow staging to a shared drive after native code reports a successfully mounted drive. RustDesk: retain upload-only behavior, label it as experimental, retain the 100 MiB bound, and prevent a completed toast without a per-transfer confirmation token.

- [ ] **Step 5: Verify transfer state locally and on device**

Run policy tests; then conduct SSH upload/download/cancel, RDP disabled-drive, and RustDesk timeout tests. Record source URI redaction, size limit, cancellation behavior, and remote visibility separately.

- [ ] **Step 6: Commit the transfer-session layer**

Commit message: `feat(transfer): add protocol-aware transfer session state`.

### Task 5: Close Bidirectional Plain-Text Clipboard Before Enabling It

**Files:**
- Modify: `entry/src/main/ets/services/ClipboardBridgeService.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `rustdesk_ffi/src/connector.rs`
- Create: `entry/src/main/ets/services/ClipboardSyncPolicy.ets`
- Create: `entry/src/test/ClipboardSyncPolicy.test.ets`

**Consumes:** The capability contract from Task 2 and the existing local clipboard monitor.

**Produces:** Explicit direction and loop-prevention policy; protocol receive callbacks dispatch remote text to ArkTS only after format/size validation.

- [ ] **Step 1: Add failing loop-prevention and permission tests**

```ts
expect(shouldForwardClipboard({ source: 'local', receiveEnabled: true, sendEnabled: true })).assertTrue();
expect(shouldForwardClipboard({ source: 'remote', receiveEnabled: false, sendEnabled: true })).assertFalse();
expect(shouldForwardClipboard({ source: 'remoteEcho', receiveEnabled: true, sendEnabled: true })).assertFalse();
expect(validateClipboardText('x'.repeat(MAX_CLIPBOARD_TEXT_CHARS)).ok).assertTrue();
```

- [ ] **Step 2: Implement the ArkTS clipboard policy**

Use plain UTF-8 text only for this release. Define direction settings, a maximum text size, monotonic source token, and user-visible disabled reason. The policy must reject binary/file clipboard payloads and never log raw clipboard text.

- [ ] **Step 3: Implement RDP receive/send callbacks against the actual FreeRDP cliprdr path**

Do not treat `impl_->clipboardText` as successful transport. Wire the negotiated channel callbacks to emit validated remote text and send local text only after channel readiness. Add a native policy/fixture test for a send request and receive event before enabling the capability.

- [ ] **Step 4: Implement RustDesk inbound clipboard dispatch**

When `connector.rs` parses a clipboard message, validate text and route it through the FFI callback to `RustDeskBridge`, then through NAPI/ArkTS. Mark receive capability enabled only after this callback is installed for the active session.

- [ ] **Step 5: Verify two-peer loops and failure cases**

Test RDP local→remote, RDP remote→local, RustDesk local→remote, RustDesk remote→local, disabled receive, disabled send, oversized text, unavailable pasteboard, and remote reconnect. Each test must assert no echo loop and no raw clipboard log.

- [ ] **Step 6: Commit per protocol after device confirmation**

Use separate commits: `feat(rdp): enable verified text clipboard sync` and `feat(rustdesk): receive verified text clipboard`.

### Task 6: Productize Background Session Continuity

**Files:**
- Modify: `entry/src/main/ets/services/RemoteSessionState.ets`
- Modify: `entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionLiveViewService.ets`
- Modify: `entry/src/main/ets/services/NotificationLiveViewStrategy.ets`
- Create: `entry/src/test/RemoteSessionStateIntegrationPolicy.test.ets`
- Modify: `docs/RDP_RUSTDESK_BACKGROUND_CONTINUITY_TESTS.md`

**Consumes:** Existing detach/reattach/cached-frame/decoder-recovery paths.

**Produces:** One state source for foreground, preserved, restoring, failed, explicit disconnect and system-final-destroy states, with a privacy-safe notification label.

- [ ] **Step 1: Write transition tests using the existing state model**

```ts
expect(nextRemoteSessionState(connected, { kind: 'background' }).phase).assertEqual('backgroundPreserved');
expect(nextRemoteSessionState(backgroundPreserved, { kind: 'foreground' }).phase).assertEqual('foregroundRestoring');
expect(nextRemoteSessionState(backgroundPreserved, { kind: 'finalDestroy' }).phase).assertEqual('disconnecting');
```

- [ ] **Step 2: Make runtime code consume `RemoteSessionState`**

Replace duplicated background booleans only at lifecycle boundaries. Keep renderer detach/reattach call order unchanged. The runtime must update the state before asynchronous background-task/live-view calls so UI failure does not misrepresent protocol state.

- [ ] **Step 3: Expose compact status without host-address leakage**

Notification and AVSession metadata display protocol plus user-approved host label; never show raw host address by default. Add a setting for exposing address only after an explicit privacy choice.

- [ ] **Step 4: Execute the negative-path device matrix**

Record results for RDP and RustDesk: live-view on/off, audio/video/no-media, AVSession rejection, notification permission off, Home/foreground, recent-task clear, network switch, and repeated restore. No protocol reconnect may be introduced solely to pass a renderer failure.

- [ ] **Step 5: Commit state productization separately**

Commit message: `feat(session): surface background continuity state`.

### Task 7: Establish PC, Accessibility, and Localization Foundations

**Files:**
- Modify: `entry/src/main/module.json5`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/resources/base/element/string.json`
- Create: `entry/src/main/resources/en_US/element/string.json`
- Create: `entry/src/test/HostAccessibilityPolicy.test.ets`

**Consumes:** Current phone/tablet/2in1 declarations, breakpoint helpers, and existing PC side layout.

**Produces:** A supported-form-factor statement, keyboard operability for primary actions, semantic labels, and resource-backed visible strings for the upgraded workbench.

- [ ] **Step 1: Confirm PC delivery target before changing manifest**

Use API 23 documentation to decide whether `pc` is a supported device type for the target distribution. If it is not, retain `2in1` and remove PC-specific marketing claims; if it is, add the supported type and test it on real hardware.

- [ ] **Step 2: Add accessible primary controls**

Host connect, favorite, group filter, sort selector, file transfer, clipboard toggle, disconnect, and error retry need a semantic label, focusable keyboard path, 44vp target, Enter/Space action, and visible focus state. Do not use `Text(...).onClick()` for a primary action.

- [ ] **Step 3: Move wave-1 visible copy into resources**

Migrate the host workbench, capability-reason, transfer-status, and background-status strings to resource identifiers. Add English values that are complete for this scope; test long English labels at the narrowest supported width.

- [ ] **Step 4: Validate keyboard and large-font flows**

Run device/manual checks at default and 2.0 font scale for phone, tablet and supported PC/2in1: add host, filter, favorite, group, connect, transfer action, disconnect. Record focus order and clipped-text defects.

- [ ] **Step 5: Commit after accessibility verification**

Commit message: `feat(ui): add accessible host workspace foundations`.

## Deferred Work That Must Not Be Included in These Waves

- VNC/RFB implementation.
- RDP/RustDesk microphone capture and upstream audio.
- Multi-display/virtual display, camera, USB, printer, smart card, tunnel, recording, chat and remote restart.
- Cross-device group collaboration or credential sharing.
- Any release of direct RustDesk mode before RustDesk ID-to-peer-key binding is enforced.

## Completion Gates

| Gate | Required evidence |
|---|---|
| Code truth | Capability policy denies every unsupported/unsafe path by default |
| Tests | ArkTS target passes, native registered tests pass, Rust test command or a documented target-specific equivalent passes |
| Device | Each enabled RDP/RustDesk/SSH user path has a log/screenshot/video result and failure-path result |
| Security | No raw clipboard/file path/credential values logged; feature respects account and encryption gates |
| UX | Unsupported actions explain why; enabled actions have cancel/error/retry semantics where applicable |
| Release | Commit, HAP, test report, device matrix and checksum match the same source revision |

## Plan Self-Review

- Scope coverage: capability truth, host organization, file exchange, clipboard, background continuity and PC usability each have a distinct task.
- Dependencies: capability truth precedes visible controls; transfer/clipboard require native receive/confirmation proof; host workbench reuses existing persisted columns without new cloud schema; background work preserves current render rule.
- Explicit non-goals: VNC, microphone, multi-display, chat/recording and enterprise redirection are deferred.
- No capability is marked complete from UI presence alone; all promotion gates require automated and device evidence.
