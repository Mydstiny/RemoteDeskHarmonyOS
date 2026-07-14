# 云同步详情与设置 Sheet 生命周期修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 始终展示云同步前提说明，并修复从本地恢复确认 Sheet 被系统叉号关闭后设置内弹窗无法再次打开的问题。

**Architecture:** 用两个纯策略文件锁定文案与 Sheet 状态转换，`HostListPage` 只负责绑定 UI 状态与调用系统文件选择器。设置二级 Sheet 的所有关闭路径收敛到一个幂等 helper；本地恢复选择不再与云同步 Sheet 同时启动，只有取得有效 JSON 后才重新打开确认 Sheet。

**Tech Stack:** HarmonyOS NEXT ArkTS、ArkUI `bindSheet`、`@ohos/hypium`、`@kit.CoreFileKit` picker、现有 `CloudStore`/`LocalBackupService`。

## Global Constraints

- 七张云表及字段保持不变：`cryptoparams`、`usersettings`、`remotehosts`、`rdpcredentials`、`rustdeskrelays`、`sshkeys`、`totpentries`。
- 不读取、不修改系统云同步开关；没有可靠平台状态 API 时只能说明前提，不能断言开关状态。
- 不改变云同步上传、下载、冲突处理、本地 JSON 格式，且本地恢复绝不自动上传。
- 不修改 RDP、RustDesk、SSH、VNC、渲染、音频、输入、加密格式或主机安全锁。
- 工作树已有无关 `.planning/`、AGPL 计划和 `logs/` 未跟踪文件，绝不暂存、修改或提交。

---

### Task 1: 建立云同步详情文案策略与回归测试

**Files:**
- Create: `entry/src/main/ets/services/CloudSyncGuidancePolicy.ets`
- Create: `entry/src/test/CloudSyncGuidancePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces `cloudSyncDetailSpec(cloudReady: boolean): CloudSyncDetailSpec`。
- `CloudSyncDetailSpec` 包含 `statusText: string`、`statusAvailable: boolean`、`prerequisites: string[]`。
- UI 只能显示 `statusText`，不得把 `cloudReady === false` 映射为“系统云同步开关已关闭”。

- [ ] **Step 1: 写失败测试**

```ts
import { cloudSyncDetailSpec } from '../main/ets/services/CloudSyncGuidancePolicy';

it('describes_ready_cloud_without_claiming_system_switch_state', 0, (): void => {
  const detail = cloudSyncDetailSpec(true);
  expect(detail.statusAvailable).assertTrue();
  expect(detail.statusText).assertEqual('应用端云数据库已就绪');
  expect(detail.prerequisites.length).assertEqual(4);
});

it('describes_unavailable_cloud_as_an_app_connection_state', 0, (): void => {
  const detail = cloudSyncDetailSpec(false);
  expect(detail.statusAvailable).assertFalse();
  expect(detail.statusText).assertEqual('应用暂未建立端云连接，请检查使用条件');
  expect(detail.statusText.indexOf('已关闭')).assertEqual(-1);
});
```

- [ ] **Step 2: 注册并执行 RED 验证**

在 `List.test.ets` 导入并调用 `cloudSyncGuidancePolicyTest()`；运行：

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS --no-daemon
```

期望：新模块未定义导致测试编译失败；若目标仍先被既有 `HostListPage.ets:2794` / SourceMap 阻断，记录为既有阻断，不把它归因于本任务。

- [ ] **Step 3: 实现最小策略**

```ts
export interface CloudSyncDetailSpec {
  statusText: string;
  statusAvailable: boolean;
  prerequisites: string[];
}

const PREREQUISITES: string[] = [
  '登录与其他设备相同的华为账号',
  '已开通华为云空间服务',
  '系统设置中的云同步开关已打开',
  '设备网络可用'
];

export function cloudSyncDetailSpec(cloudReady: boolean): CloudSyncDetailSpec {
  return {
    statusAvailable: cloudReady,
    statusText: cloudReady ? '应用端云数据库已就绪' : '应用暂未建立端云连接，请检查使用条件',
    prerequisites: PREREQUISITES.slice()
  };
}
```

- [ ] **Step 4: GREEN 验证**

重跑同一测试命令；若既有测试目标仍阻断，执行生产构建以确认新策略可被 ArkTS 编译：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

期望：`assembleHap` 成功。

- [ ] **Step 5: 提交策略任务**

```powershell
git add entry/src/main/ets/services/CloudSyncGuidancePolicy.ets entry/src/test/CloudSyncGuidancePolicy.test.ets entry/src/test/List.test.ets
git commit -m "feat(cloud): describe sync prerequisites"
```

### Task 2: 建立设置二级 Sheet 生命周期策略与回归测试

**Files:**
- Create: `entry/src/main/ets/services/SettingsLeafSheetLifecyclePolicy.ets`
- Create: `entry/src/test/SettingsLeafSheetLifecyclePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces `settingsLeafSheetClosedState(): SettingsLeafSheetClosedState`。
- Produces `shouldOpenRestoreConfirmation(hasValidDocument: boolean): boolean`。
- `SettingsLeafSheetClosedState` 固定为 `{ visible: false, mode: 0, cancelPendingOpen: true }`；`mode=0` 与 `SETTINGS_SHEET_NONE` 对齐。

- [ ] **Step 1: 写失败测试**

```ts
import {
  settingsLeafSheetClosedState,
  shouldOpenRestoreConfirmation
} from '../main/ets/services/SettingsLeafSheetLifecyclePolicy';

it('resets_the_leaf_sheet_after_an_external_system_dismissal', 0, (): void => {
  const state = settingsLeafSheetClosedState();
  expect(state.visible).assertFalse();
  expect(state.mode).assertEqual(0);
  expect(state.cancelPendingOpen).assertTrue();
});

it('opens_restore_confirmation_only_for_a_valid_backup', 0, (): void => {
  expect(shouldOpenRestoreConfirmation(false)).assertFalse();
  expect(shouldOpenRestoreConfirmation(true)).assertTrue();
});
```

- [ ] **Step 2: RED 验证**

注册 `settingsLeafSheetLifecyclePolicyTest()` 后执行 Task 1 的测试命令。期望：模块缺失导致失败，或被同一既有测试构建阻断。

- [ ] **Step 3: 实现最小策略**

```ts
export interface SettingsLeafSheetClosedState {
  visible: boolean;
  mode: number;
  cancelPendingOpen: boolean;
}

export function settingsLeafSheetClosedState(): SettingsLeafSheetClosedState {
  return { visible: false, mode: 0, cancelPendingOpen: true };
}

export function shouldOpenRestoreConfirmation(hasValidDocument: boolean): boolean {
  return hasValidDocument;
}
```

- [ ] **Step 4: GREEN 验证**

重跑 Task 1 的测试命令，并以 `assembleHap` 成功作为 ArkTS 编译回归证据。

- [ ] **Step 5: 提交生命周期策略任务**

```powershell
git add entry/src/main/ets/services/SettingsLeafSheetLifecyclePolicy.ets entry/src/test/SettingsLeafSheetLifecyclePolicy.test.ets entry/src/test/List.test.ets
git commit -m "fix(settings): define leaf sheet lifecycle"
```

### Task 3: 集成固定详情卡片与安全的本地恢复文件选择流程

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets:19-24, 212-222, 683-776, 3857-3891, 4660-4835, 2766-2779`
- Modify: `entry/src/main/ets/services/CloudSyncSheetPolicy.ets`
- Test: `entry/src/test/CloudSyncGuidancePolicy.test.ets`
- Test: `entry/src/test/SettingsLeafSheetLifecyclePolicy.test.ets`

**Interfaces:**
- Consumes `cloudSyncDetailSpec(CloudStore.getInstance().isCloudAvailable())`。
- Consumes `settingsLeafSheetClosedState()` and `shouldOpenRestoreConfirmation(document !== null)`。
- Adds `CLOUD_SYNC_SHEET_DETAILS` to `CloudSyncSheetPolicy`, a dismissible read-only sheet step.

- [ ] **Step 1: 写 UI 行为失败测试说明并确认 RED 现象**

在两份策略测试中保留 Task 1/2 的断言，并在真机或现有设备复现：进入设置 → 从本地恢复 → 选择有效 JSON → 在确认恢复 Sheet 点击右上角叉号 → 点击外观或云同步卡片。期望的 RED 现象是：原生 Sheet 已关闭但设置内新 Sheet 不出现，FAB Sheet 仍可出现。

- [ ] **Step 2: 实现统一关闭 helper**

在 `HostListPage` 添加如下方法，并让主动关闭与 `bindSheet.onDisappear` 都调用它：

```ts
private resetSettingsLeafSheetAfterDismiss(): void {
  const next = settingsLeafSheetClosedState();
  if (next.cancelPendingOpen && this.pendingSheetOpenTimer !== -1) {
    clearTimeout(this.pendingSheetOpenTimer);
    this.pendingSheetOpenTimer = -1;
  }
  this.showSettingsLeafSheet = next.visible;
  this.settingsLeafSheetMode = next.mode;
  this.noteSheetDismissed();
}

private closeSettingsLeafSheet(): void {
  this.closeLegacySettingsSheetFlags();
  this.resetSettingsLeafSheetAfterDismiss();
}
```

在 `.bindSheet($$this.showSettingsLeafSheet, ...)` 的 `onDisappear` 先保存是否需要刷新 crypto，再调用 `resetSettingsLeafSheetAfterDismiss()`，最后仅在原 mode 为 crypto popup 时执行 `refreshCryptoStatus()`。这样外部系统叉号关闭时状态必定复位，而重复触发保持幂等。

- [ ] **Step 3: 实现文件 picker 与确认 Sheet 的交接**

删除“从本地恢复”行中的 `this.openCloudSyncSheet(); this.chooseLocalRestore();` 并改为仅调用 `this.chooseLocalRestore()`。

将 `chooseLocalRestore()` 收敛为：调用 `selectAndValidate()`；取消/异常时 `promptAction.showToast` 并返回；有效文档时设置 `pendingLocalRestore`、`cloudSyncStep = CLOUD_SYNC_SHEET_RESTORE_CONFIRM`、`popupSheetMode = 3`，然后调用 `openSettingsLeafSheet(SETTINGS_SHEET_POPUP)`。`openSettingsLeafSheet` 会先关闭父设置 Sheet 并复用现有延迟保护后显示确认 Sheet，因此 picker 与叶 Sheet 不再并发。

```ts
if (!shouldOpenRestoreConfirmation(document !== null) || document === null) {
  promptAction.showToast({ message: '未选择有效的本地备份文件', duration: 1800 });
  return;
}
this.pendingLocalRestore = document;
this.cloudSyncError = '';
this.cloudSyncStep = CLOUD_SYNC_SHEET_RESTORE_CONFIRM;
this.popupSheetMode = 3;
this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP);
```

- [ ] **Step 4: 实现固定详情卡片与只读详情 Sheet**

在“管理云同步”行之后加入同风格的 `Row`，副标题使用 `cloudSyncDetailSpec(...).statusText`；添加分隔线。点击时设置 `cloudSyncStep = CLOUD_SYNC_SHEET_DETAILS`、`popupSheetMode = 3` 并调用 `openSettingsLeafSheet(SETTINGS_SHEET_POPUP)`。

在 `CloudSyncSheetPolicy` 增加：

```ts
export const CLOUD_SYNC_SHEET_DETAILS: string = 'details';
```

并为其返回可关闭的标题/说明。`cloudSyncSheet()` 新增 details 分支，使用 `cloudSyncDetailSpec` 显示当前应用状态和四条前提；它不调用上传、下载、恢复或任何写入方法。

- [ ] **Step 5: GREEN 验证**

运行 `git diff --check`，再运行 Task 1 的 `assembleHap` 命令。真机完整回归：

1. 固定详情卡片在云端数据区域始终显示，且未连接文案不声称系统开关已关闭。
2. 从本地恢复选择有效 JSON 后，在确认 Sheet 点击系统叉号；随后打开外观、云同步、加密、关于等设置 Sheet，全部可用。
3. 取消 picker、无效 JSON、恢复失败、恢复成功四种路径后重复第 2 项；恢复成功仍不触发云上传。

- [ ] **Step 6: 提交 UI 集成任务**

```powershell
git add entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/services/CloudSyncSheetPolicy.ets entry/src/main/ets/services/CloudSyncGuidancePolicy.ets entry/src/main/ets/services/SettingsLeafSheetLifecyclePolicy.ets entry/src/test/CloudSyncGuidancePolicy.test.ets entry/src/test/SettingsLeafSheetLifecyclePolicy.test.ets entry/src/test/List.test.ets
git commit -m "fix(settings): recover sheet lifecycle after local restore"
```

### Task 4: 完成验证与接力记录

**Files:**
- Modify: `docs/superpowers/specs/2026-07-13-cloud-sync-guidance-and-sheet-lifecycle-design.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if a reusable Sheet-lifecycle rule is added.

**Interfaces:**
- Documents exact build result, ArkTS test-target blocker if present, and device verification matrix result.

- [ ] **Step 1: 运行完整静态与生产验证**

```powershell
git diff --check
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

期望：无 diff 格式错误，`assembleHap` 成功并生成 `entry/build/default/outputs/default/entry-default-signed.hap`。

- [ ] **Step 2: 记录测试目标状态**

执行 Task 1 的 ArkTS 测试命令。若它仍被 `HostListPage.ets:2794` 和 DevEco SourceMap 阻断，记录精确错误与“新增用例已注册但未执行”；不篡改无关测试基础设施。

- [ ] **Step 3: 更新文档并提交验证记录**

更新设计文档的实现/验证段，更新 HANDOFF、TASKS 和项目状态记忆；只在新增通用 Sheet 规则时更新 CODEWALK。然后：

```powershell
git add docs/superpowers/specs/2026-07-13-cloud-sync-guidance-and-sheet-lifecycle-design.md
git commit -m "docs: verify cloud sync guidance and sheet recovery"
```
