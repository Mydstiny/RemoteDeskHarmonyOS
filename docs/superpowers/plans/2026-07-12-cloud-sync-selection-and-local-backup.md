# 云同步选择与本地 JSON 备份 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户按设备选择七张云表的同步范围，并安全地执行全量本地 JSON 备份和事务恢复。

**Architecture:** `CloudSyncSelectionPolicy` 是唯一的表选择与加密依赖决策点，`CloudSyncSelectionStore` 只负责本机 Preferences 持久化。`CloudStore` 在所有云 API 边界应用策略；`LocalBackupService` 仅通过 CloudStore 导出/恢复原始表快照，并在恢复窗口抑制自动推送。设置页沿用单一叶子 Sheet，以内部状态展示选择、备份风险和恢复确认。

**Tech Stack:** ArkTS、ArkData RDB/Preferences、CoreFileKit `picker`/`fileIo`、CryptoArchitectureKit SHA-256、Hypium、Hvigor。

## Global Constraints

- 固定七张表，不新增云表；取消选择不得删除任何本地或云端数据。
- 启动/下载为 cloud-first，上传/CRUD 为 native-first；任何同步调用均必须先过滤有效表。
- 只要有加密业务表参与，`cryptoparams` 自动参与且先拉取；`usersettings` 可独立取消。
- 本地备份始终包含七表、为明文 JSON、具备版本/哈希/字段校验；恢复必须在单个事务中替换并禁止自动回传。
- 不创建嵌套 `bindSheet`，不改动 RDP、RustDesk、SSH、VNC、渲染、音频、输入或现有加密格式。

---

### Task 1: 表选择策略与本机持久化

**Files:**
- Create: `entry/src/main/ets/services/CloudSyncSelectionPolicy.ets`
- Create: `entry/src/main/ets/services/CloudSyncSelectionStore.ets`
- Create: `entry/src/test/CloudSyncSelectionPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces `cloudSyncSelectableTables(): string[]`, `effectiveCloudSyncTables(selected: string[]): string[]`, `hasCloudSyncBusinessSelection(selected: string[]): boolean`.
- Produces singleton `CloudSyncSelectionStore.init(context)`, `selectedBusinessTables()`, `replaceSelectedBusinessTables(tables)`, `effectiveTables()`.

- [ ] Write failing Hypium cases for default six business-table selection, invalid/duplicate sanitization, zero selection, usersettings-only selection, and automatic cryptoparams dependency.
- [ ] Run the test target; verify failure is missing-module/API rather than an assertion error.
- [ ] Implement the pure policy, then the Preferences store using one JSON string key and fail-safe defaults.
- [ ] Re-run policy tests and register them in `List.test.ets`.
- [ ] Commit the policy-only change.

### Task 2: 在所有云同步路径强制应用选择

**Files:**
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/main/ets/services/CloudSyncPolicy.ets`
- Modify: `entry/src/test/CloudSyncPolicy.test.ets`
- Modify: `entry/src/test/CloudStore.test.ets`

**Interfaces:**
- `CloudStore.syncableTables()` returns the store’s effective tables.
- `CloudStore.pushTable(table)` is a no-op for unselected tables or during restore suppression.
- `uploadAllToCloud()` and `downloadAllFromCloud()` use `syncableTables()`; `syncTablesSequentially()` accepts only its caller-provided filtered list.
- `CloudStore.setAutomaticPushSuppressed(value)` controls restoration guard.

- [ ] Add failing tests asserting selected tables drive upload/download, unselected CRUD tables do not enqueue a push, cloud-first starts with cryptoparams, and suppression wins over selection.
- [ ] Run the focused test target and observe failures caused by absent filtering/suppression APIs.
- [ ] Initialize selection storage in `CloudStore.init`, apply its effective list in manual, startup and cloud-event pulls, and guard `pushTable` before queue state changes.
- [ ] Run focused policy/store tests; inspect diff to ensure protocol-specific services remain untouched.
- [ ] Commit the sync-boundary change.

### Task 3: 可校验的全表本地备份与事务恢复服务

**Files:**
- Create: `entry/src/main/ets/services/LocalBackupPolicy.ets`
- Create: `entry/src/main/ets/services/LocalBackupService.ets`
- Create: `entry/src/test/LocalBackupPolicy.test.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- `LocalBackupPolicy.createDocument(tables, createdAt, appVersion)` and `validateDocument(text)` return typed, non-sensitive summaries.
- `CloudStore.exportAllTableRows()` returns stable, raw seven-table rows; `CloudStore.replaceAllTableRows(snapshot)` validates caller input, opens one transaction, replaces all seven tables and restores automatic-push state in `finally`.
- `LocalBackupService.writeBackup(uri)` and `readAndValidate(uri)` use `DocumentViewPicker`/`fileIo`; `restoreValidated(snapshot)` returns a table-count summary.

- [ ] Add failing pure tests for seven-table package shape, canonical SHA-256 stability, tamper detection, version rejection and missing/unknown table rejection.
- [ ] Run the policy test and verify it fails before production implementation exists.
- [ ] Implement canonical JSON/hash validation and allow-list column schemas; add CloudStore raw snapshot/export/transaction replace methods with no cloud calls.
- [ ] Implement CoreFileKit read/write adapter, warning-safe result types and service-level restore guard.
- [ ] Run focused policy and store tests; inspect no sensitive values are passed to logs/toasts.
- [ ] Commit the backup-service change.

### Task 4: 设置页的同步管理、备份和恢复交互

**Files:**
- Modify: `entry/src/main/ets/services/CloudSyncSheetPolicy.ets`
- Modify: `entry/src/main/ets/services/SettingsSheetRoutePolicy.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/test/CloudSyncSheetPolicy.test.ets`
- Modify: `entry/src/test/SettingsSheetRoutePolicy.test.ets`

**Interfaces:**
- Sheet states include `manageTables`, `backupWarning`, `restorePreview`, `restoreConfirm`, `backingUp`, `restoring` in the existing cloud-sheet route.
- HostListPage obtains all display labels and disable decisions from policy/store; it refreshes host/key/relay/settings views only after a successful local restore.

- [ ] Write failing sheet-policy tests for the new root action, zero-selection disable copy, Chinese table cards, sensitive backup warning and destructive restore confirmation.
- [ ] Run the focused tests and observe missing-state/spec failures.
- [ ] Add the three cards in the existing 云同步 accordion, keeping it between 外观 and 连接实况窗; implement internal page navigation, cards, checks, progress locks, picker calls and clear error feedback.
- [ ] Run focused tests, then manually inspect the sheet’s safe area, back/close behavior and disabled states.
- [ ] Commit the UI integration.

### Task 5: 集成验证与交付

**Files:**
- Modify: `docs/superpowers/specs/2026-07-12-cloud-sync-selection-and-local-backup-design.md`
- Modify: `docs/superpowers/plans/2026-07-12-cloud-sync-selection-and-local-backup.md`

- [ ] Run `git diff --check` and all focused Hypium tests; record exact results.
- [ ] Run production `assembleHap` with a recoverable non-daemon invocation and confirm a fresh signed HAP timestamp.
- [ ] Run `default@OhosTestBuildArkTS`; if the existing HostListPage/SourceMap blocker persists, capture it separately from feature verification.
- [ ] Review every spec requirement against tasks and implementation; update the spec status and plan checkboxes.
- [ ] Commit documentation/verification record and hand off the HAP path plus device test checklist.
