# 主机列表精简与更新说明布局 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除收藏、最近和名称排序能力，恢复手机/Pad 的沉浸光感悬浮底栏，并让 Pad/PC 的版本更新说明显示为半屏居中弹窗。

**Architecture:** 收藏字段从 ArkTS 主机模型、同步服务、云端读写和列表视图中移除；旧 RDB 的 `isfavorite` 列保持不迁移但不再读取或写入。主机页以 `HdsTabs` 替换当前普通 `Tabs`，只恢复历史已验证的视觉配置并保留现有四个 Tab。`ReleaseNotesPolicy` 新增纯函数决定更新说明是否使用弹窗，`GuidePage` 根据该结果在同一路由内选择全屏或居中卡片容器。

**Tech Stack:** HarmonyOS NEXT API 23、ArkTS 严格模式、ArkUI、`@kit.UIDesignKit`、Hypium、DevEco hvigor。

## Global Constraints

- 所有 ArkTS 代码保持严格类型，使用显式返回类型，注释和用户文案使用中文。
- 兼容既有本地 RDB：不得删除或迁移 `remotehosts.isfavorite` 列；新代码不得读取或写入该列。
- 不修改连接协议、同步流程、版本号、更新说明文案、首次安装教程、SFTP、剪贴板或原生 C++/Rust 代码。
- 更新说明只在 `StartupMode.RELEASE_NOTES` 且 `currentBreakpoint !== 'sm'` 时使用弹窗；手机和首次安装教程必须全屏。
- 继续在主工作区 `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop` 的 `codex/rdp-rustdesk-video-performance` 分支工作；不纳入当前已暂存的 RustDesk 构建改动。

---

### Task 1: 删除主机收藏状态与遗留持久化读写

**Files:**
- Modify: `entry/src/main/ets/model/RemoteHost.ets:41-52,188-191,279-290,330-350`
- Modify: `entry/src/main/ets/services/HostSyncService.ets:174-180`
- Modify: `entry/src/main/ets/services/CloudStore.ets:1278,1350,1700,1853`
- Modify: `entry/src/test/CloudStore.test.ets:216-248,364-370,427`
- Modify: `entry/src/test/HostSyncService.test.ets:120-128`

**Interfaces:**
- Consumes: `RemoteHostJSON` 和现有 `HostSyncService` CRUD 接口。
- Produces: 不含 `isFavorite` 的 `RemoteHost`/`RemoteHostJSON`；`HostSyncService` 不再公开 `toggleFavorite(hostId: string)`。

- [ ] **Step 1: 将收藏 round-trip 测试替换为遗留字段忽略测试**

在 `CloudStore.test.ets` 用以下测试替换 `isFavorite_true_roundtrip`，并从完整 JSON 往返和默认值断言中移除 `isFavorite`：

```ts
it('legacy_favorite_field_should_be_ignored', 0, (): void => {
  const host = new RemoteHost();
  const legacy: Record<string, Object> = host.toJSON() as Record<string, Object>;
  legacy['isFavorite'] = true;
  const restored = RemoteHost.fromJSON(legacy as RemoteHostJSON);
  expect(Object.prototype.hasOwnProperty.call(restored.toJSON(), 'isFavorite')).assertFalse();
});
```

从 `HostSyncService.test.ets` 删除 `toggle_favorite_should_persist_the_new_value`，保留并继续验证分组和手动排序接口。

- [ ] **Step 2: 运行测试，确认当前实现不符合新契约**

运行：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS
```

预期：目标测试或 ArkTS 编译因当前 `RemoteHostJSON` 仍包含 `isFavorite` 而失败；若已知 SourceMap `reading 'share'` 在测试执行前阻断，记录该环境错误并改用生产编译验证类型变更。

- [ ] **Step 3: 删除模型、服务与 CloudStore 的收藏读写**

在 `RemoteHost.ets` 删除接口、类字段、`toJSON()` 字段和 `fromJSON()` 赋值：

```ts
// 删除 RemoteHostJSON 中的 isFavorite: boolean
// 删除 RemoteHost 中的 isFavorite: boolean = false
// 删除 toJSON() 的 isFavorite: this.isFavorite
// 删除 fromJSON() 的 json.isFavorite 分支
```

删除 `HostSyncService.toggleFavorite()`。在 `CloudStore.ets` 的 `hostToBucket`、`hostToBucketRaw` 和两条行读取路径删除以下读写：

```ts
vb['isfavorite'] = h.isFavorite ? 1 : 0;
h.isFavorite = rs.getLong(rs.getColumnIndex('isfavorite')) !== 0;
```

不要改动 `CREATE TABLE` 或 `ALTER TABLE`：旧列继续由既有 RDB 承载，但不再参与应用数据模型。

- [ ] **Step 4: 运行测试与静态检索**

运行：

```powershell
rg -n "isFavorite|toggleFavorite" entry/src/main/ets entry/src/test -g "*.ets"
git diff --check -- entry/src/main/ets/model/RemoteHost.ets entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/services/CloudStore.ets entry/src/test/CloudStore.test.ets entry/src/test/HostSyncService.test.ets
```

预期：第一条命令无匹配；第二条命令无空白错误。

- [ ] **Step 5: 提交独立模型与持久化变更**

```powershell
git add entry/src/main/ets/model/RemoteHost.ets entry/src/main/ets/services/HostSyncService.ets entry/src/main/ets/services/CloudStore.ets entry/src/test/CloudStore.test.ets entry/src/test/HostSyncService.test.ets
git commit -m "refactor(hosts): remove favorite state"
```

### Task 2: 精简主机列表控件并恢复沉浸光感悬浮底栏

**Files:**
- Modify: `entry/src/main/ets/services/HostWorkspacePolicy.ets:1-54`
- Modify: `entry/src/test/HostWorkspacePolicy.test.ets:1-42`
- Modify: `entry/src/main/ets/pages/HostListPage.ets:1-65,143-153,1162-1175,2625-2655,2858-2923`

**Interfaces:**
- Consumes: `filterHostsByWorkspace(hosts, groupId)`、`groupIdsForHosts(hosts)` 与现有 `TabsController` 导航语义。
- Produces: `HostWorkspacePolicy` 只保留分组、搜索和健康状态策略；移动端使用 `HdsTabsController` 与 `HdsTabs`。

- [ ] **Step 1: 用输入顺序保持测试替代排序测试**

在 `HostWorkspacePolicy.test.ets` 删除收藏和最近排序测试及 `HostSortMode`/`sortHosts` 导入，增加：

```ts
it('workspace_filter_should_keep_source_order', 0, (): void => {
  const first = host('first', 'First');
  const second = host('second', 'Second');
  first.groupId = 'ops';
  second.groupId = 'ops';
  const result = filterHostsByWorkspace([second, first], 'ops');
  expect(result[0].id).assertEqual('second');
  expect(result[1].id).assertEqual('first');
});
```

- [ ] **Step 2: 运行测试，确认旧排序 API 仍存在**

运行与 Task 1 相同的 `default@OhosTestBuildArkTS` 命令。预期：新的策略测试在旧实现下失败；若 SourceMap 环境错误先发生，保留错误输出作为受限验证证据。

- [ ] **Step 3: 删除排序 UI 与恢复 HdsTabs 配置**

在 `HostWorkspacePolicy.ets` 删除 `HostSortMode`、`compareName()` 和 `sortHosts()`；保留 `normalizeGroupId`、`groupIdsForHosts`、`filterHostsByWorkspace`、`searchHosts`、`displayConnectionHealth`。

在 `HostListPage.ets`：

```ts
// import 中仅保留 filterHostsByWorkspace, groupIdsForHosts, displayConnectionHealth
// 删除 @State hostSortMode、@State recentOnly、toggleHostFavorite()
// visibleHostsForCurrentMode() 的末尾改为：
return filterHostsByWorkspace(visible, this.workspaceGroupId);
// HostWorkspaceFilterBar() 只保留“全部”和工作区 groupId 行
// 删除 HostQuickActions() 及主机卡片中对此 builder 的调用
```

将当前移动端 `Tabs` 换为 `HdsTabs`，把控制器和导入恢复为：

```ts
import { HdsTabs, HdsTabsController, hdsMaterial, DividerMode } from '@kit.UIDesignKit';
private tabsCtrl: HdsTabsController = new HdsTabsController();
```

保留当前四个 `TabContent`（主机、密钥库、中继、设置），并在其链上增加历史基线配置：

```ts
.barOverlap(true)
.barPosition(BarPosition.End).vertical(false).barHeight(64)
.barFloatingStyle({
  barWidth: { smallWidth: 280, mediumWidth: 320, largeWidth: 380 },
  barBottomMargin: this.breakpoint === 'lg' ? 24 : (this.breakpoint === 'md' ? 20 : 24),
  barSideMargin: 8,
  gradientMask: { maskColor: this.haloMaskColor(), maskHeight: 92 },
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.IMMERSIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  },
  adaptToHandedness: true
})
.divider({ mode: DividerMode.NONE })
```

保留现有 `priorityGesture`、`onChange`、当前 Tab 索引和 FAB 的握姿判定，不回退其他主机页改动。

- [ ] **Step 4: 编译与人工检查**

运行：

```powershell
rg -n "HostSortMode|sortHosts|recentOnly|toggleHostFavorite|isFavorite|收藏|最近|名称" entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/services/HostWorkspacePolicy.ets
git diff --check -- entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/services/HostWorkspacePolicy.ets entry/src/test/HostWorkspacePolicy.test.ets
```

预期：第一条命令无匹配；第二条命令无空白错误。真机检查主机卡片不再有星标，分组仍可筛选，手机/Pad 底栏有光晕与沉浸材质，四个 Tab 可切换。

- [ ] **Step 5: 提交列表与底栏变更**

```powershell
git add entry/src/main/ets/services/HostWorkspacePolicy.ets entry/src/test/HostWorkspacePolicy.test.ets entry/src/main/ets/pages/HostListPage.ets
git commit -m "refactor(hosts): simplify list and restore floating tabs"
```

### Task 3: 为更新说明增加可测试的 Pad/PC 弹窗呈现策略

**Files:**
- Modify: `entry/src/main/ets/services/ReleaseNotesPolicy.ets:1-35`
- Modify: `entry/src/test/ReleaseNotesPolicy.test.ets:1-27`

**Interfaces:**
- Consumes: `StartupMode` 和字符串断点（`sm`、`md`、`lg`、`xl`）。
- Produces: `shouldPresentReleaseNotesAsDialog(mode: StartupMode, breakpoint: string): boolean`。

- [ ] **Step 1: 写出断点呈现策略测试**

在 `ReleaseNotesPolicy.test.ets` 导入 `shouldPresentReleaseNotesAsDialog`，增加：

```ts
it('uses_dialog_only_for_non_phone_release_notes', 0, (): void => {
  expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'sm')).assertFalse();
  expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'md')).assertTrue();
  expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'xl')).assertTrue();
  expect(shouldPresentReleaseNotesAsDialog(StartupMode.FIRST_INSTALL_GUIDE, 'xl')).assertFalse();
});
```

- [ ] **Step 2: 运行测试，确认策略尚未导出**

运行与 Task 1 相同的 `default@OhosTestBuildArkTS` 命令。预期：失败信息包含缺少 `shouldPresentReleaseNotesAsDialog`；若 SourceMap 阻断，保存该环境阻断信息。

- [ ] **Step 3: 实现纯策略函数**

在 `ReleaseNotesPolicy.ets` 末尾加入：

```ts
export function shouldPresentReleaseNotesAsDialog(mode: StartupMode, breakpoint: string): boolean {
  return mode === StartupMode.RELEASE_NOTES && breakpoint !== 'sm';
}
```

- [ ] **Step 4: 运行对应测试并检查注册入口**

运行：

```powershell
rg -n "releaseNotesPolicyTest" entry/src/test/List.test.ets
git diff --check -- entry/src/main/ets/services/ReleaseNotesPolicy.ets entry/src/test/ReleaseNotesPolicy.test.ets
```

预期：测试已由 `List.test.ets` 注册，且差异没有空白错误。

- [ ] **Step 5: 提交呈现策略**

```powershell
git add entry/src/main/ets/services/ReleaseNotesPolicy.ets entry/src/test/ReleaseNotesPolicy.test.ets
git commit -m "feat(release): add responsive notes presentation policy"
```

### Task 4: 在 GuidePage 实现半屏更新说明弹窗并完成生产验证

**Files:**
- Modify: `entry/src/main/ets/pages/GuidePage.ets:7-24,92-181`
- Test: `entry/src/test/ReleaseNotesPolicy.test.ets`（Task 3 已覆盖决策逻辑）
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`

**Interfaces:**
- Consumes: `shouldPresentReleaseNotesAsDialog()`、`currentBreakpoint`、当前 `finish()` 的一次性版本已读写入。
- Produces: 全屏教程/手机更新说明与 Pad/PC 居中半屏更新说明的同一套 Swiper 控件。

- [ ] **Step 1: 添加可复用的模式和卡片尺寸辅助方法**

在 `GuidePage` 增加断点状态和助手：

```ts
@StorageProp('currentBreakpoint') breakpoint: string = 'sm';

private presentReleaseNotesAsDialog(): boolean {
  return shouldPresentReleaseNotesAsDialog(this.mode, this.breakpoint);
}

private releaseNotesDialogWidth(): string | number {
  return this.breakpoint === 'xl' ? 640 : 560;
}

private releaseNotesDialogHeight(): string | number {
  return this.breakpoint === 'xl' ? '60%' : '58%';
}
```

导入策略函数；不要修改 `aboutToAppear()`、`resolveStartupMode()` 或 `finish()`。

- [ ] **Step 2: 抽取 Swiper 和底部导航为共享 Builder**

将当前 `build()` 中的 Swiper 与按钮行提取到 `@Builder guideSwiperContent()`。保持以下行为不变：

```ts
.loop(false).indicator(false)
.onChange((i: number): void => { this.currentIndex = i; })
// 第一页教程仍显示“跳过”；更新说明最后一页仍显示“继续”
// 只有 finish() 写入 last_seen_release_version 并 replaceUrl 到 LoginPage
```

- [ ] **Step 3: 根据模式选择全屏或遮罩卡片容器**

使用 `Stack` 包裹页面；非弹窗时继续全屏渲染 `guideSwiperContent()`。弹窗时使用不可点击的遮罩和居中卡片：

```ts
if (this.presentReleaseNotesAsDialog()) {
  Column().width('100%').height('100%').backgroundColor('rgba(0,0,0,0.28)')
  Column() { this.guideSwiperContent() }
    .width(this.releaseNotesDialogWidth())
    .height(this.releaseNotesDialogHeight())
    .constraintSize({ maxWidth: '88%', maxHeight: '62%' })
    .borderRadius(24)
    .backgroundColor(this.pal().bg)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .shadow({ radius: 28, color: 'rgba(0,0,0,0.22)', offsetY: 12 })
    .padding({ top: 12 })
    .align(Alignment.Center)
} else {
  this.guideSwiperContent()
}
```

遮罩不得绑定点击、手势、路由返回或关闭处理；用户只能用最后一页的“继续”完成更新说明。

- [ ] **Step 4: 生产构建和验收检查**

运行：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git diff --check
git status --short
```

预期：`assembleHap` 完成 Native、ArkTS、PackageHap、PackingCheck 和可用本机证书下的 SignHap；无空白错误；状态中除本计划明确文件外，已有 RustDesk 构建改动仍保持原状。人工验收：手机全屏、Pad/PC 半屏弹窗、教程全屏、最后一页“继续”后同版本不再展示。

- [ ] **Step 5: 更新交接记录并提交最终 UI 变更**

在交接文件中记录本次提交、生产构建结果、已知 `OhosTestBuildArkTS` SourceMap 阻断（如仍存在）和设备验收清单，然后运行：

```powershell
git add entry/src/main/ets/pages/GuidePage.ets C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
git commit -m "feat(release): present notes in responsive dialog"
```

## Plan Self-Review

- **规格覆盖：** Task 1 覆盖整个收藏状态及遗留数据兼容；Task 2 覆盖最近/名称栏删除、分组保留和历史沉浸底栏恢复；Task 3–4 覆盖仅更新说明在 Pad/PC 的半屏弹窗、手机和教程保持全屏、不可误关闭及一次性已读语义。
- **占位扫描：** 本计划没有未完成标记或模糊实现；每个任务均列出精确文件、接口、测试、命令和提交范围。
- **类型一致性：** `shouldPresentReleaseNotesAsDialog(mode: StartupMode, breakpoint: string)` 在测试、策略与 `GuidePage` 中使用相同签名；收藏 API 的所有调用点在 Task 1–2 一并删除。

## Execution Mode

用户已明确要求不使用子代理。后续按 **Inline Execution** 在本会话逐任务执行，每个任务完成后进行测试与独立提交。
