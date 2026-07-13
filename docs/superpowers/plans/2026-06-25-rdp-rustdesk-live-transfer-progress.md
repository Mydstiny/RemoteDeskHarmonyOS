# RDP RustDesk Live Transfer Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show RDP and RustDesk remote-desktop file transfer progress through HarmonyOS data-transfer live task notifications, with ordinary notification fallback.

**Architecture:** Add a small ArkTS transfer progress model and a `FileTransferLiveTaskService` that owns background-task startup, live/progress notification publishing, and graceful fallback. RDP and RustDesk keep their existing transfer flows but report begin/progress/success/failure through the service.

**Tech Stack:** ArkTS strict mode, API 23 `@kit.BackgroundTasksKit`, `@kit.NotificationKit`, `@kit.AbilityKit` WantAgent, existing `RemoteDesktop.ets` file transfer code, existing RustDesk native status polling.

## Global Constraints

- Scope is only RDP and RustDesk file transfer from `RemoteDesktop.ets`; do not modify SSH/SFTP transfer UI or backend.
- Do not directly create third-party `LIVE_VIEW` notifications. Use the data-transfer background task path and fall back if the system rejects it.
- Add `ohos.permission.KEEP_BACKGROUND_RUNNING` and `EntryAbility.backgroundModes=["dataTransfer"]`.
- Keep optional background/live notification failure non-fatal; file transfer must continue.
- RDP copy progress means "copied into local shared drive for `\\tsclient`", not "remote consumed it".
- RustDesk remains capped by the existing `RUSTDESK_FILE_MAX_BYTES` unless a separate task changes protocol buffering.
- Follow project rules: ArkTS strict mode, no `any`/`unknown`, error strings carry traceable codes, build before commit.

---

### Task 1: Transfer Progress Model

**Files:**
- Create: `entry/src/main/ets/services/FileTransferProgressModel.ets`
- Test: build validation plus static call sites in Task 3/4

**Interfaces:**
- Produces: `TransferProtocol`, `TransferState`, `FileTransferProgressSnapshot`, `clampTransferProgress(transferred, total): number`, `makeTransferTitle(protocol, state): string`, `makeTransferStatusText(snapshot): string`.

- [ ] **Step 1: Add a pure model file**

```ts
export type TransferProtocol = 'rdp' | 'rustdesk';
export type TransferState = 'preparing' | 'transferring' | 'waitingRemote' | 'completed' | 'failed';

export interface FileTransferProgressSnapshot {
  taskId: string;
  protocol: TransferProtocol;
  fileName: string;
  transferred: number;
  total: number;
  progressValue: number;
  state: TransferState;
  statusText: string;
}
```

- [ ] **Step 2: Add clamped formatting helpers**

```ts
export function clampTransferProgress(transferred: number, total: number): number {
  if (total <= 0 || transferred <= 0) { return 0; }
  const ratio = transferred / total;
  if (ratio >= 1) { return 100; }
  return Math.max(0, Math.min(99, Math.floor(ratio * 100)));
}
```

- [ ] **Step 3: Build-check the model**

Run `hvigorw assembleHap`.
Expected: ArkTS compiles, no strict-mode type errors.

### Task 2: Live Task Service With Fallback

**Files:**
- Create: `entry/src/main/ets/services/FileTransferLiveTaskService.ets`
- Modify: `entry/src/main/module.json5`

**Interfaces:**
- Consumes: `FileTransferProgressSnapshot`.
- Produces: singleton `FileTransferLiveTaskService.getInstance()`, `begin(snapshot)`, `update(snapshot)`, `complete(snapshot)`, `fail(snapshot)`.

- [ ] **Step 1: Add manifest capability**

Add `backgroundModes: ["dataTransfer"]` to `EntryAbility` and request `ohos.permission.KEEP_BACKGROUND_RUNNING`.

- [ ] **Step 2: Add service startup**

Use `backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], wantAgentObj)` to obtain `notificationId`. Store `continuousTaskId` when returned.

- [ ] **Step 3: Publish live progress**

Publish a `notificationManager.NotificationRequest` with `notificationContentType: NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`, `notificationSlotType: LIVE_VIEW`, `template.name: 'downloadTemplate'`, and `progressValue` from the snapshot.

- [ ] **Step 4: Fallback**

If start or live publish fails, publish a normal `SERVICE_INFORMATION` or `OTHER_TYPES` notification with `downloadTemplate`; if that fails too, log and continue.

- [ ] **Step 5: Stop task**

On complete/fail, publish a final state and call `backgroundTaskManager.stopBackgroundRunning(context, continuousTaskId)` if a task was started.

### Task 3: RDP Transfer Reporting

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes: `FileTransferLiveTaskService`, model helpers.
- Produces: RDP copy progress snapshots during `copyFileToRdpDrive()`.

- [ ] **Step 1: Begin live task after file validation**

Create an RDP task snapshot when the destination file is opened and before the copy loop starts.

- [ ] **Step 2: Update per chunk**

After each successful chunk write, update the live task with copied bytes and progress.

- [ ] **Step 3: Complete or fail**

Call `complete()` after the current success toast and `fail()` on every early error path in `copyFileToRdpDrive()`.

### Task 4: RustDesk Transfer Reporting

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes: `FileTransferLiveTaskService`.
- Produces: RustDesk progress snapshots for local read, submit, waiting remote, done, error.

- [ ] **Step 1: Begin when local read starts**

Report `preparing` at 0 percent before opening the selected file.

- [ ] **Step 2: Replace one-shot read status with live task stages**

Report 90 percent when the file is read and submitted to RustDesk core, 95 percent while polling remote confirmation.

- [ ] **Step 3: Complete or fail**

Call `complete()` on confirmed done and `fail()` on submit/read/timeout/remote error.

### Task 5: Verification And Commit

**Files:**
- No new feature files beyond Tasks 1-4.
- Update Mission transformation handoff/task/memory only after build passes.

- [ ] **Step 1: Run targeted search**

Confirm no SSH/SFTP files changed.

- [ ] **Step 2: Build**

Run the project `assembleHap` command from `CODEWALK.md`.
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

Commit with message `feat(file): show rdp rustdesk transfer progress in live task`.

