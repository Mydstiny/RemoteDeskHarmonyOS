# Cloud Sync Reliability Without Cloud Schema Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing seven Huawei Cloud tables reliable and user-selectable without changing their schemas: all synchronization is explicitly coordinated by the app, local changes are pushed promptly, startup and safe refreshes pull cloud changes, and manual/backup recovery is atomic from the application's point of view.

**Architecture:** `CloudSyncCoordinator` becomes the only public synchronization gateway. It freezes the selected-table snapshot for each operation, serializes cloud work, coalesces automatic per-table pushes, persists retry intent, and prevents restore/download and cloud events from racing. `CloudStore` keeps RDB schema, encryption conversion, and the one-table Huawei `cloudSync()` primitive; services continue to own in-memory maps and reload only after the coordinator completes a cloud-first operation.

**Tech Stack:** HarmonyOS NEXT ArkTS, `@kit.ArkData` relationalStore/cloudData/preferences, Hypium tests, DevEco hvigor.

## Checkpoint — 2026-07-12

- 已落地：单一同步协调队列、`autoSync=false` 的显式单表同步、选择快照、启动/前台/登录/云事件拉取、成功本地 CRUD 后自动推送、手动下载的快照回滚、恢复锁、严格 JSON 备份校验、设置页同步管理与华为云空间引导。
- 已补：下载/恢复期间 raw 加密迁移写入锁、恢复排队期锁、`updateLastConnected` 的“先持久化再改内存”顺序，以及关闭系统自动同步后加密迁移的显式表推送。
- 最新生产构建在最后一组补丁之前已通过；下次继续前必须重新运行 `assembleHap`。
- 仍待完成（不可遗漏）：多表自动失败的持久化重试不能覆盖；`cryptoparams` 前置失败后必须保留业务表重试意图；下载回滚失败需显式上报；所有 `insertSync/updateSync/deleteSync` 必须检查返回值；本地恢复后须刷新加密状态；仅服务不可用时展示华为云空间引导；补齐相应回归用例并完成最终复审。

## Global Constraints

- Do not add, remove, rename, or alter columns of `cryptoparams`, `usersettings`, `remotehosts`, `rdpcredentials`, `rustdeskrelays`, `sshkeys`, or `totpentries`.
- Keep user table selection local-only in `RemoteDesktopAppPrefs`; the default remains all six user-selectable data groups, with `cryptoparams` derived only when an encrypted selected group needs it.
- Call `setDistributedTables(..., { autoSync: false })`; application calls to `cloudSync()` must remain available when Huawei Cloud Space is enabled.
- Preserve cloud-first pull on launch and native-first push after successful CRUD. Do not ever use timestamp ordering to make an empty new device overwrite cloud data.
- Keep the existing crypto format and enforce `cryptoparams` before encrypted business tables on pulls and uploads.
- A local JSON restore must not automatically upload to Huawei Cloud. No RDP, RustDesk, SSH, VNC, renderer, audio, input, or security-lock behavior may change.
- Local backup JSON is intentionally plaintext; validation must reject malformed, extra, missing, or type-invalid rows before any RDB mutation.
- Preserve the existing UI copy that tells users to enable Huawei Cloud Space and the system cloud-sync switch when `setDistributedTables`/explicit sync reports the service is unavailable.

---

## File Structure

- Create `entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets`: pure operation, queue, retry, and table-snapshot rules.
- Create `entry/src/main/ets/services/CloudSyncCoordinator.ets`: single asynchronous app-level synchronization queue, retry persistence, lifecycle entry points, and operation results.
- Modify `entry/src/main/ets/services/CloudStore.ets`: register all seven tables with system auto-sync disabled, expose a coordinator-only one-table executor, add transactional snapshot/restore helpers, remove direct sync aliases, and notify runtime consumers only after a completed coordinator pull.
- Modify `entry/src/main/ets/services/HostSyncService.ets` and `entry/src/main/ets/services/KeyVaultService.ets`: remove duplicate launch pulls; route successful CRUD and normalization writes to the coordinator; provide one reload callback each.
- Modify `entry/src/main/ets/entryability/EntryAbility.ets` and `entry/src/main/ets/pages/HostListPage.ets`: initialize once, invoke foreground refresh through the coordinator, and immediately apply pulled `usersettings` to preferences/AppStorage using the existing allowlist.
- Modify `entry/src/main/ets/services/LocalBackupPolicy.ets`, `LocalBackupService.ets`, and `CloudStore.ets`: strict per-table JSON row schema checks, restore queue lock, and a pre-download snapshot/rollback path.
- Modify focused tests under `entry/src/test/` and test registration only as required by the existing test harness.

## Task 1: Define Coordinator Rules and Regression Tests

**Files:**
- Create: `entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets`
- Create: `entry/src/test/CloudSyncCoordinatorPolicy.test.ets`
- Modify: `entry/src/main/ets/services/CloudSyncPolicy.ets`
- Modify: `entry/src/test/CloudSyncPolicy.test.ets`

**Interfaces:**
- Produces `CloudSyncRequest`, `CloudSyncSource`, `CloudSyncRetryState`, `snapshotSyncTables(selected: string[]): string[]`, `coalesceAutomaticPushes(existing, incoming)`, and `nextRetryDelayMs(attempt: number): number`.
- Consumes `effectiveCloudSyncTables()` and `cloudPullOrder()`.

- [ ] **Step 1: Write failing policy tests**

```ts
it('freezes_selected_tables_when_the_request_is_created', 0, (): void => {
  const frozen = snapshotSyncTables(['sshkeys']);
  expect(frozen.length).assertEqual(2);
  expect(frozen[0]).assertEqual('cryptoparams');
  expect(frozen[1]).assertEqual('sshkeys');
});

it('coalesces_only_automatic_pushes_for_the_same_table', 0, (): void => {
  expect(coalesceAutomaticPushes(['sshkeys'], 'sshkeys')).assertTrue();
  expect(coalesceAutomaticPushes(['sshkeys'], 'totpentries')).assertFalse();
});

it('never_allows_system_auto_sync_to_be_the_selection_bypass', 0, (): void => {
  expect(cloudDistributedTableAutoSync()).assertFalse();
});
```

- [ ] **Step 2: Run the focused test target and verify RED**

Run the project-supported ArkTS test build for the new file. Expected: import/symbol errors for the missing coordinator policy and `cloudDistributedTableAutoSync`, not an unrelated parser failure.

- [ ] **Step 3: Implement the minimal pure policy**

```ts
export const CLOUD_SYNC_MAX_RETRIES: number = 3;
export function cloudDistributedTableAutoSync(): boolean { return false; }
export function snapshotSyncTables(selected: string[]): string[] {
  return cloudPullOrder().filter((table: string): boolean =>
    effectiveCloudSyncTables(selected).indexOf(table) >= 0);
}
export function nextRetryDelayMs(attempt: number): number {
  return attempt <= 1 ? 1000 : attempt === 2 ? 5000 : 30000;
}
```

- [ ] **Step 4: Run focused policy tests and verify GREEN**

Run the same test command. Expected: all new coordinator-policy and existing cloud-policy cases pass.

- [ ] **Step 5: Commit the isolated policy/test change**

```powershell
git add entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets entry/src/main/ets/services/CloudSyncPolicy.ets entry/src/test/CloudSyncCoordinatorPolicy.test.ets entry/src/test/CloudSyncPolicy.test.ets
git commit -m "test(cloud): define explicit synchronization policy"
```

## Task 2: Add the Single Coordinator Queue and Durable Retry Intent

**Files:**
- Create: `entry/src/main/ets/services/CloudSyncCoordinator.ets`
- Create: `entry/src/test/CloudSyncCoordinatorPolicy.test.ets` additions
- Modify: `entry/src/main/ets/services/CloudSyncSelectionStore.ets`

**Interfaces:**
- Produces `CloudSyncCoordinator.getInstance()`, `init(context, executor, onPullApplied)`, `requestStartupPull()`, `requestForegroundPull()`, `requestCloudEventPull()`, `requestAutomaticPush(table)`, `requestManualUpload()`, `requestManualDownload()`, `runExclusiveRestore(work)`.
- `executor(table, direction, label): Promise<boolean>` is supplied by `CloudStore`; coordinator must not import relationalStore.
- Each operation exposes `{ ok: boolean, source: CloudSyncSource, tables: string[], failedTables: string[] }`.

- [ ] **Step 1: Write failing tests for serialization and retry state**

```ts
it('runs_cloud_first_after_a_pending_push_instead_of_racing_it', 0, async (): Promise<void> => {
  const trace: string[] = [];
  const coordinator = makeCoordinator((table, direction): Promise<boolean> => {
    trace.push(direction + ':' + table); return Promise.resolve(true);
  });
  coordinator.requestAutomaticPush('sshkeys');
  await coordinator.requestStartupPull();
  expect(trace[0]).assertEqual('nativeFirst:sshkeys');
  expect(trace[1]).assertEqual('cloudFirst:cryptoparams');
});

it('stores_only_failed_tables_for_a_bounded_retry', 0, async (): Promise<void> => {
  const result = await failingCoordinator.requestManualUpload();
  expect(result.failedTables[0]).assertEqual('sshkeys');
  expect(readRetryState().attempt).assertEqual(1);
});
```

- [ ] **Step 2: Run the focused coordinator test and verify RED**

Expected: `CloudSyncCoordinator`/test seam does not exist yet.

- [ ] **Step 3: Implement coordinator queue and retry persistence**

Use one promise tail (`queueTail`) so every global operation begins only after its predecessor settles. Maintain a `Set<string>` only for automatic tables waiting behind the active request. Capture `selectionStore.effectiveTables()` before enqueueing and do not read selection again while executing. Persist `{ source, direction, tables, failedTables, attempt, nextRetryAt }` as JSON in `RemoteDesktopAppPrefs`; retry only failed selected tables three times with 1 s, 5 s, and 30 s delays. Manual operations return failure to the UI and do not schedule an invisible destructive retry.

- [ ] **Step 4: Run focused coordinator tests and verify GREEN**

Expected: serialization, same-table coalescing, frozen selection, retry bounds, and manual-operation no-background-retry tests all pass.

- [ ] **Step 5: Commit the coordinator**

```powershell
git add entry/src/main/ets/services/CloudSyncCoordinator.ets entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets entry/src/main/ets/services/CloudSyncSelectionStore.ets entry/src/test/CloudSyncCoordinatorPolicy.test.ets
git commit -m "feat(cloud): serialize explicit synchronization"
```

## Task 3: Make CloudStore a Coordinator-Only RDB/Cloud Executor

**Files:**
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/test/CloudStore.test.ets`

**Interfaces:**
- `CloudStore.init()` calls `setDistributedTables(TABLES, DISTRIBUTED_CLOUD, { autoSync: cloudDistributedTableAutoSync() })`.
- Coordinator calls `executeSyncTable(table: string, direction: CloudSyncDirection, label: string): Promise<boolean>`.
- `CloudStore` publishes `onCloudDataApplied()` only after coordinator cloud-first completion; no `dataChange` handler may call `cloudSync()` directly.

- [ ] **Step 1: Write failing CloudStore tests**

```ts
it('does_not_expose_legacy_direct_sync_entry_points', 0, (): void => {
  const cloud = CloudStore.getInstance() as Object;
  expect(Object.prototype.hasOwnProperty.call(cloud, 'syncHosts')).assertFalse();
});

it('does_not_start_automatic_push_while_restore_is_suppressed', 0, (): void => {
  const cloud = CloudStore.getInstance();
  cloud.setAutomaticPushSuppressed(true);
  cloud.pushTable('sshkeys');
  expect(cloud.pendingSyncTableCount()).assertEqual(0);
});
```

- [ ] **Step 2: Run the focused CloudStore test and verify RED**

Expected: legacy API is present and queue-observability method is missing.

- [ ] **Step 3: Implement the store boundary**

Replace `{ autoSync: true }` with the policy value and log `autoSync=false`. Register the `dataChange` callback only to call `CloudSyncCoordinator.requestCloudEventPull()`; de-duplicate while a pull is queued/active. Move all `cloudSync()` calls into the one executor, make direct `syncHosts`, `syncSshKeys`, and `syncTotpEntries` private/deleted, and make `pushTable()` delegate to `requestAutomaticPush`. Preserve table status counters and availability errors so the existing Huawei Cloud Space warning sheet continues to be chosen by UI code.

- [ ] **Step 4: Add transactional cloud-first protection**

Before a manual download, export an internal seven-table RDB snapshot. If any selected table fails, restore that snapshot in one transaction before returning `ok=false`. On any cloud-first success, check crypto state first and invoke runtime reload callbacks once, after the complete operation rather than per table.

- [ ] **Step 5: Run focused CloudStore tests and verify GREEN**

Expected: no direct legacy APIs, auto-sync disabled policy, suppression, unavailable-service safety, and snapshot rollback behavior all pass.

- [ ] **Step 6: Commit the CloudStore boundary change**

```powershell
git add entry/src/main/ets/services/CloudStore.ets entry/src/test/CloudStore.test.ets
git commit -m "fix(cloud): disable system bypass and protect pulls"
```

## Task 4: Route Application Lifecycle and Every CRUD Path through the Coordinator

**Files:**
- Modify: `entry/src/main/ets/services/HostSyncService.ets`
- Modify: `entry/src/main/ets/services/KeyVaultService.ets`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/test/HostSyncService.test.ets`
- Modify: `entry/src/test/KeyVaultService.test.ets`

**Interfaces:**
- Services call `coordinator.requestAutomaticPush(table)` only after their local RDB mutation returns `true`.
- One application-owned startup request is `coordinator.requestStartupPull()`. Services retain local-cache-first initialization and register reload callbacks but must not independently call `pullNowAsync()`.
- Ability foreground calls `coordinator.requestForegroundPull()` after the existing foreground work; it is a no-op/coalesced when a recent/active cloud-first operation exists.

- [ ] **Step 1: Write failing service tests**

```ts
it('pushes_sshkeys_once_after_a_successful_add', 0, (): void => {
  const trace = makeKeyVaultWithCloudSuccess();
  expect(trace.addSshKey(new SshKey())).assertTrue();
  expect(trace.requestedTables[0]).assertEqual('sshkeys');
});

it('does_not_start_a_second_launch_pull_from_key_vault', 0, async (): Promise<void> => {
  const trace = makeInitializedKeyVault();
  await trace.init(fakeContext());
  expect(trace.startupPullCount).assertEqual(0);
});
```

- [ ] **Step 2: Run focused service tests and verify RED**

Expected: tests show duplicate pull behavior or no coordinator request seam.

- [ ] **Step 3: Implement narrow service/lifecycle routing**

Keep `insert/update/delete` order as RDB success → in-memory map mutation → `requestAutomaticPush(table)` → listeners. Cover hosts, RDP credentials, RustDesk relays, SSH keys, TOTP entries, user settings persistence, and crypto parameter changes. Replace the two service startup pulls with a single EntryAbility/initialization composition root request after both services have registered their reload listeners. On foreground and cloud event only schedule selected tables and reload maps after the complete pull.

- [ ] **Step 4: Run focused service tests and verify GREEN**

Expected: all CRUD groups request the exact mapped table once, no unselected-table push request is sent, and startup initiates exactly one pull.

- [ ] **Step 5: Commit lifecycle/CRUD wiring**

```powershell
git add entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/services/KeyVaultService.ets entry/src/main/ets/entryability/EntryAbility.ets entry/src/test/HostSyncService.test.ets entry/src/test/KeyVaultService.test.ets
git commit -m "fix(cloud): coordinate startup and CRUD synchronization"
```

## Task 5: Apply Pulled User Settings and Preserve the Cloud Sync UI Contract

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets` only if an existing pure helper is insufficient
- Modify: `entry/src/test/CloudSyncSettingsPolicy.test.ets`
- Modify: `entry/src/test/CloudSyncSheetPolicy.test.ets`

**Interfaces:**
- After successful `usersettings` pull, invoke the same allowlisted preference/AppStorage application path used for local setting changes.
- Cloud management sheet continues to show upload, download, selection management, local backup, and restore; every action invokes the coordinator result API rather than CloudStore direct multi-table sync.
- An unavailable cloud result shows the existing Huawei Cloud Space/sync-switch guidance before any destructive confirmation.

- [ ] **Step 1: Write failing pure-policy tests**

```ts
it('applies_only_allowlisted_pulled_settings_to_runtime', 0, (): void => {
  const applied = cloudSettingsToRuntimePatch({ themeMode: 'dark', maliciousKey: 'x' });
  expect(applied['themeMode']).assertEqual('dark');
  expect(Object.keys(applied).indexOf('maliciousKey')).assertEqual(-1);
});

it('shows_service_guidance_before_the_overwrite_confirmation', 0, (): void => {
  expect(cloudSheetNextStep('download', false)).assertEqual('serviceUnavailable');
});
```

- [ ] **Step 2: Run focused policy tests and verify RED**

Expected: runtime patch or unavailable-state ordering test fails.

- [ ] **Step 3: Implement the runtime refresh integration**

Use the existing settings allowlist and key-to-AppStorage mapping; do not deserialize arbitrary cloud keys. Refresh HostListPage state only through its existing update/reload methods so theme, settings accordion, and cards retain their current animation/layout. Keep the current cloud card located between `外观` and `连接实况窗`, reusing the existing row styling and bindSheet transitions.

- [ ] **Step 4: Run focused policy tests and verify GREEN**

Expected: allowed settings apply, unknown settings do not, and all cloud sheet warning/confirmation ordering cases pass.

- [ ] **Step 5: Commit settings/UI integration**

```powershell
git add entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/services/CloudSyncSettingsPolicy.ets entry/src/test/CloudSyncSettingsPolicy.test.ets entry/src/test/CloudSyncSheetPolicy.test.ets
git commit -m "fix(cloud): refresh runtime settings after pull"
```

## Task 6: Harden Manual Download and Local Backup/Restore Validation

**Files:**
- Modify: `entry/src/main/ets/services/LocalBackupPolicy.ets`
- Modify: `entry/src/main/ets/services/LocalBackupService.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/test/LocalBackupPolicy.test.ets`

**Interfaces:**
- `validateLocalBackupDocument(text)` returns null unless exactly seven known table names exist, every row uses known columns, and every field is the expected string/integer representation for that table.
- `runExclusiveRestore(work)` blocks/queues automatic pushes, foreground pulls, and cloud-event pulls until the RDB transaction is committed or rolled back.

- [ ] **Step 1: Write failing backup tests**

```ts
it('rejects_unknown_columns_in_a_backup_row', 0, (): void => {
  expect(validateLocalBackupDocument(documentWithColumn('sshkeys', 'unexpected', 'x')) === null).assertTrue();
});

it('rejects_non_numeric_value_for_integer_columns', 0, (): void => {
  expect(validateLocalBackupDocument(documentWithValue('remotehosts', 'port', 'not-a-number')) === null).assertTrue();
});
```

- [ ] **Step 2: Run focused backup tests and verify RED**

Expected: generic-string parser accepts at least one invalid document.

- [ ] **Step 3: Implement explicit local backup schemas and exclusive restore**

Define a local-only column/type map that mirrors the existing `CREATE TABLE` definitions without changing them. Require all required primary keys, reject unknown keys, validate integer text with a strict signed-integer check, and rebuild values buckets only from schema-approved columns. Put the entire file restore in coordinator exclusive mode; clear queued automatic changes caused by restore writes and do not enqueue an upload after success or failure.

- [ ] **Step 4: Run focused backup tests and verify GREEN**

Expected: valid complete backup passes checksum/schema validation; unknown/missing table, extra column, malformed number, checksum failure, and partially failing restore all reject or roll back before observable mutation.

- [ ] **Step 5: Commit backup hardening**

```powershell
git add entry/src/main/ets/services/LocalBackupPolicy.ets entry/src/main/ets/services/LocalBackupService.ets entry/src/main/ets/services/CloudStore.ets entry/src/test/LocalBackupPolicy.test.ets
git commit -m "fix(backup): validate and isolate local restore"
```

## Task 7: Register Tests, Verify, Review, and Document Remaining Boundary

**Files:**
- Modify: `entry/src/test/List.test.ets` (only if it requires registration)
- Modify: `docs/superpowers/specs/2026-07-12-cloud-sync-reliability-without-schema-design.md` only to record implemented verification
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`

- [ ] **Step 1: Confirm all new test suites are registered and run the focused cloud/backup suites**

Run the available ArkTS test target and record the exact output. If the known `HostListPage` parser/DevEco SourceMap failure blocks the target, retain the full error and run every independently compilable pure policy verification available; do not attribute that existing blocker to this feature.

- [ ] **Step 2: Run static and production verification**

```powershell
git diff --check
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

Expected: `git diff --check` has no errors and `assembleHap` exits 0, producing `entry/build/default/outputs/default/entry-default-signed.hap`.

- [ ] **Step 3: Perform final requirements audit**

Verify seven-table names/columns are unchanged; verify no direct production `store.cloudSync()` exists outside `CloudStore.executeSyncTable`; verify `autoSync: false`; verify selected-table snapshots gate startup/foreground/event/manual/automatic paths; verify service-unavailable guidance remains available; verify local restore never schedules a push. Document the unresolved platform boundary: without metadata changes, two offline devices simultaneously editing/deleting the same row rely on Huawei Cloud's conflict behavior and cannot get application-defined per-row merge semantics.

- [ ] **Step 4: Commit final verification and exchange-state updates**

```powershell
git add entry/src/test/List.test.ets docs/superpowers/specs/2026-07-12-cloud-sync-reliability-without-schema-design.md
git add -f C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
git commit -m "docs: verify cloud synchronization reliability"
```

## Completion Record — 2026-07-13

- [x] Automatic retry persistence now keeps an independent record per originating table, retains the business-table retry when `cryptoparams` fails first, and rechecks the current user selection before executing a scheduled retry.
- [x] Manual download exposes a failed rollback instead of reporting a false success. Local RDB replacement validates every insert, locks the in-memory DEK after a whole-database replacement, and refreshes crypto state before services reload.
- [x] Every cloud-backed CRUD/raw mutation checks the RDB result before changing in-memory state or requesting a push. Download/local-restore locks also cover crypto migration writes and relay local writes.
- [x] Disable/reset encryption now uses checked, transactional local writes. Failed decryptions roll back as a unit; no cloud `disabled`/`reset` signal or sensitive-table push is issued after a partial local operation.
- [x] Huawei Cloud Space guidance is reserved for service-unavailable evidence, rather than generic network/strategy failures.
- [x] Independent final review found and cleared the retry-selection and crypto-transaction P0/P1 defects.

Verification: `git diff --check` passed and signed production `assembleHap` passed on 2026-07-13. `default@OhosTestBuildArkTS` remains blocked before tests by the pre-existing `HostListPage.ets:2794:11 Declaration or statement expected` and the DevEco SourceMap `reading 'share'` failure. The seven cloud tables/fields remain unchanged. The unresolved offline same-row conflict boundary still relies on Huawei Cloud because no schema metadata may be added.
