# Cloud Sync Recovery And Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore safe Huawei Cloud synchronization for all configured data types and expose a consistent manual cloud-sync control in Settings.

**Architecture:** `CloudStore` becomes the single owner of the exact seven-table cloud contract and returns an explicit result for table registration and pull/push operations. Startup performs a pull-first recovery in dependency order and only refreshes in-memory services after a completed pull. `HostListPage` reuses its existing accordion/card and single leaf-sheet router to add the cloud-sync card and destructive-operation confirmations.

**Tech Stack:** ArkTS API 23, `@kit.ArkData` relationalStore/cloudData, Hypium, ArkUI bindSheet.

## Cloud Contract

| Cloud data type | Local table | Purpose | Startup order |
|---|---|---|---|
| `cryptoparams` | `cryptoparams` | encryption status, salt, verifier | 1 |
| `usersettings` | `usersettings` | cloud-syncable personalization | 2 |
| `remotehosts` | `remotehosts` | RDP/RustDesk/SSH hosts | 3 |
| `rdpcredentials` | `rdpcredentials` | reusable RDP credential records | 3 |
| `sshkeys` | `sshkeys` | SSH private/public keys | 3 |
| `totpentries` | `totpentries` | 2FA authenticator entries | 3 |
| `rustdeskrelays` | `rustdeskrelays` | relay/server/account configuration | 3 |

## Safety Rules

- `setDistributedTables` must receive all seven names and any error leaves the cloud service unavailable.
- A failed/unsupported pull must not clear host, SSH key, TOTP, relay, or user-setting memory state.
- Startup and manual download are pull-first; neither may initiate a push before its pull result is known.
- Upload and download require separate confirmation sheets. Upload warns about cloud replacement; download warns about local replacement.
- The UI must report Huawei Cloud Space/sync unavailability rather than treating it as an empty cloud database.

---

### Task 1: Define and test the seven-table synchronization contract

**Files:**
- Create: `entry/src/main/ets/services/CloudSyncPolicy.ets`
- Create: `entry/src/test/CloudSyncPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

- [ ] Add a pure `cloudSyncTableNames()` function that returns the seven exact names in the dependency order above.
- [ ] Add `cloudPullOrder()` and `cloudOperationRequiresConfirmation(operation)` helpers.
- [ ] Write Hypium tests that fail when a table is omitted, duplicated, reordered before `cryptoparams`, or mapped to the wrong confirmation requirement.
- [ ] Register the test suite in `List.test.ets`.

### Task 2: Repair CloudStore registration, pull, push, and local schemas

**Files:**
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/test/CloudStore.test.ets`

- [ ] Create/migrate the `usersettings` table and retain `rustdeskrelays` as its own distributed table.
- [ ] Replace the hard-coded partial table array with `cloudSyncTableNames()`.
- [ ] Make `setDistributedTables` failure observable through `isCloudAvailable()` and a typed `SyncStatus`; do not mark cloud sync ready after failure.
- [ ] Add `pullAllFromCloud()` that synchronizes `cryptoparams` first, then all remaining tables, waits for each callback, and returns failure details without clearing local data.
- [ ] Add `uploadAllToCloud()` and `downloadAllFromCloud()` wrappers that use the same status/error path and never silently ignore a table failure.
- [ ] Update automatic CRUD paths so every cloud-backed object writes its own table and schedules a table push only after the local write succeeds.
- [ ] Preserve `rustdeskrelays` as database rows; remove its JSON-in-`cryptoparams` transport path after migration compatibility has been verified.

### Task 3: Make app startup restore data before exposing empty lists

**Files:**
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/services/KeyVaultService.ets`
- Modify: `entry/src/test/HostSyncService.test.ets`

- [ ] Initialize CloudStore once, then await `pullAllFromCloud()` before the first Host/KeyVault memory refresh.
- [ ] Keep the latest valid in-memory state if startup pull fails and publish a recoverable sync error.
- [ ] Reload hosts, credentials, relays, SSH keys, and TOTP only after a completed pull.
- [ ] Register cloud change events only after initial recovery, and coalesce event-triggered pulls to prevent concurrent reload races.
- [ ] Add tests for pull-first ordering and for retaining local state on a pull failure.

### Task 4: Synchronize user settings and cloud-relay models

**Files:**
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/services/RustDeskRelayService.ets` or current relay owner
- Create: `entry/src/test/CloudSyncSettingsPolicy.test.ets`

- [ ] Define the exact personalization keys eligible for cross-device sync; exclude device-local UI state, credentials used only by the local signing/build environment, and temporary session data.
- [ ] Persist eligible settings through `usersettings`, pull them after `cryptoparams`, and apply them only after validation.
- [ ] Move relay persistence to `rustdeskrelays` and verify create/update/delete pushes its own table.
- [ ] Add tests covering allowed and excluded settings plus relay table selection.

### Task 5: Add the Settings cloud-sync card and confirmation sheets

**Files:**
- Modify: `entry/src/main/ets/services/SettingsAccordionPolicy.ets`
- Modify: `entry/src/test/SettingsAccordionPolicy.test.ets`
- Modify: `entry/src/main/ets/services/SettingsSheetRoutePolicy.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`

- [ ] Add `SETTINGS_SECTION_CLOUD_SYNC` between appearance and connection-live sections; test accordion toggling and action behavior.
- [ ] Render the card with the existing header/card/divider/palette/animation primitives so spacing, blur, shadow, icon transition, and expand/collapse curve match adjacent sections.
- [ ] On card press, open the existing single settings leaf bindSheet with two choices: upload all local data and download all cloud data.
- [ ] Each choice opens a second routed bindSheet confirmation: upload warns that cloud data will be replaced; download warns that local data will be replaced.
- [ ] Before either operation, query cloud availability. If Huawei Cloud Space or system cloud sync is unavailable, show the required explanatory sheet and do not perform a mutation.
- [ ] Surface table-level progress/results and reload services only after a successful download.

### Task 6: Verify safely on device and package for installation

**Files:**
- Modify: `docs/CLOUD_SYNC_TEST_CHECKLIST.md`

- [ ] Add a seven-table verification matrix, including encrypted and unencrypted host/key/TOTP cases.
- [ ] Test on two same-account devices: initial cold start recovery, add/update/delete immediate push, cloud-card upload confirmation, cloud-card download confirmation, service-off warning, and relay/settings synchronization.
- [ ] Run focused Hypium suites, `default@OhosTestBuildArkTS`, and `assembleHap --no-daemon`.
- [ ] Inspect runtime `CloudSync` logs for successful registration and one completion callback per table; record any Huawei service error code without exposing secrets.
