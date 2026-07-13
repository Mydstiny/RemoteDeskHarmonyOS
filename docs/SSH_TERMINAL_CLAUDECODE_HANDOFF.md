# SSH Terminal Layout Optimization Handoff for Claude Code

本文档是当前 SSH 终端优化的任务中转站。请覆盖旧的“大迁移计划”来使用本文件。

当前重点不是重新迁移 terminal_core, 也不是继续做大范围重构。Rust `terminal_core`、ArkTS `TerminalCoreBridge`、`NativeTerminalRenderer` 已经接入, 默认路径已经走 native terminal core。接下来请围绕用户明确反馈的问题继续优化:

- 显示内容行与指示光标容易错位。
- 虚拟键盘弹出/收起后, 最新输出行容易从底部跳到倒数第三行一类的位置。
- 键盘挤压期间滚动/跟随底部容易异常。
- 顶栏需要进一步避开系统状态栏、摄像头/挖孔区域。

## 当前基线

最近相关提交:

```text
6afc956 fix: stabilize ssh terminal layout
29c1e8f feat: refine ssh terminal chrome
```

`6afc956` 已完成:

- `SshTerminal.ets`
  - 增加 `topSafeHeight`, 从 `TYPE_SYSTEM.topRect` 与 `TYPE_CUTOUT.topRect` 获取顶部避让。
  - 顶栏高度改为 `56 + topChromeOffset()`。
  - 顶栏 padding top 改为 `6 + topChromeOffset()`。
  - 移动端键盘/视口变化后使用 `requestTerminalScrollToBottomSettled()` 多次回到底部。
  - 向 `NativeTerminalRenderer` 和 `TerminalEmulator` 传入 `viewportHeight: terminalPaneHeight()`。

- `NativeTerminalRenderer.ets`
  - 增加 `viewportHeight` prop。
  - 增加 `gridTop()` 和 `canvasHeight()`。
  - 全量绘制、行绘制、单 cell 绘制、光标绘制统一加上 `gridTop()`。
  - `viewportHeight` 变化时, 如果处于 follow bottom, 先滚到底部再重绘。

- `TerminalEmulator.ets`
  - 与 native renderer 保持相同的 `viewportHeight` / `gridTop()` / `canvasHeight()` 模型。
  - Canvas 改为占满父容器。
  - 选区触摸坐标减去 `gridTop()`。

验证:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry assembleHap
```

构建已通过。仍有大量既有 warning, 主要来自 AGConnect typings、deprecated APIs、权限提示, 不是本轮 SSH 改动新增错误。

## 执行前必须阅读

1. `AGENTS.md`
2. `CLAUDE.md` 如果存在
3. `docs/TECH_SPEC.md`
4. `entry/src/main/ets/pages/SshTerminal.ets`
5. `entry/src/main/ets/components/NativeTerminalRenderer.ets`
6. `entry/src/main/ets/components/TerminalEmulator.ets`
7. `entry/src/main/ets/components/VirtualKeyBar.ets`
8. `entry/src/main/ets/napi/TerminalCoreBridge.ets`
9. `rustdesk_ffi/src/terminal_core/`

## 不要做的事

- 不要回退 `6afc956` 或 `29c1e8f`。
- 不要删除 `TerminalEmulator.ets`; 它仍是 fallback。
- 不要把 SSH 网络层、terminal core parser、界面布局一次性混改。
- 不要让隐藏 `TextInput` 保存用户输入内容; 它只能作为 IME 锚点。
- 不要把滚动交给页面 Scroll; 页面本身不能滚动, 只能滚动终端 viewport。
- 不要用 `any`。
- 不要提交未跟踪的 `AGENTS.md`。

## 主要假设

当前错位的根因很可能不是 ANSI parser, 而是布局/绘制坐标链路在键盘动画期间不同步:

```text
shellAreaH
  -> terminalPaneHeight()
  -> terminal Stack 实际 height
  -> termAreaH onAreaChange
  -> recalcGrid() 得到 rows
  -> NativeTerminalRenderer rows + viewportHeight
  -> Canvas gridTop + row/cursor y
```

只要这条链路某一步晚一帧、使用旧 rows 或旧 viewportHeight, 就会出现最新行不贴底、光标画到旧行、滚动位置回弹异常。

## 下一步优化计划

### Phase A: 建立可复现验收清单

目标: 先让“错位”变成可以反复验证的清单。

建议新增或更新:

```text
docs/SSH_TERMINAL_TEST_CASES.md
```

至少覆盖:

- 手机竖屏打开 SSH, 自动聚焦弹出键盘, 执行 `seq 1 80`。
- 手机竖屏键盘已弹出, 连续执行 `pwd`, `ls`, `seq 1 200`。
- 手机竖屏键盘收起再弹出, 最新行仍贴虚拟键栏顶部。
- Pad 横屏键盘弹出, 最新行不跳到倒数第三行。
- 输出过程中旋转或改变窗口尺寸, 光标与当前输入行不分离。
- 手动上滑查看历史后, 新输出不能强制抢回到底部; 点输入/键盘变化后才回底部。
- PC 端滚轮只滚动 scrollback, 不影响远端真实光标位置。
- `top`/进度条/光标移动类输出, 光标不残留、不乱跳。
- `clear`, `vim` 或全屏 TUI 启动/退出后, 可视区行和光标仍一致。

验收文档需要写清楚:

```text
操作步骤 / 预期结果 / 失败表现 / 是否通过 / 备注
```

### Phase B: 去抖并集中 bottom sync

目标: 避免键盘动画期间多处同时发 scrollToBottom, 导致顺序不可控。

当前 `SshTerminal.ets` 中这些地方会请求回到底部:

- `schedulePtyResize()` 完成后
- `onKeyboardInsetChange()`
- terminal Stack `onAreaChange()`
- shell Stack `onAreaChange()`

建议把它们集中为一个小型调度器:

```ts
private bottomSyncTimers: number[] = [];

private clearBottomSyncTimers(): void
private scheduleBottomSync(reason: string): void
```

行为建议:

- 每次布局变化先清理旧 timers。
- 立即触发一次。
- 以 48/140/260ms 再触发三次。
- `aboutToDisappear()` 必须清理 timers。
- debug 阶段可暂时 hilog 打印 reason、rows、viewportHeight、termAreaH、kbHeight、navHeight。

验收:

- 键盘弹出期间不出现多组定时器互相打架。
- 页面离开后没有残留 timer 继续触发。
- `assembleHap` 通过。

### Phase C: 固化 viewport/rows 单一来源

目标: 减少 `terminalPaneHeight()` 反复计算导致的值不一致。

建议在 `SshTerminal.ets` 中增加明确状态:

```ts
@State terminalViewportH: number = 0;
```

由一个方法统一更新:

```ts
private updateTerminalViewport(reason: string): void
```

建议规则:

- `terminalViewportH = terminalPaneHeight()` 的结果只在这一处写入。
- Renderer 只接收 `terminalViewportH`。
- `recalcGrid()` 也优先使用 `terminalViewportH` 或 `termAreaH` 中已稳定的值, 不要混用多个来源。
- 如果父 Stack `onAreaChange` 已经给了真实高度, 以真实高度为准。

验收:

- 键盘动画中 `rows * cellH <= viewportHeight` 恒成立。
- `gridTop()` 范围始终是 `[0, cellH)` 或合理的小余量。
- 最新输出在 follow bottom 时贴近虚拟键栏顶部, 不跳到倒数第三行。

### Phase D: 光标绘制抗错位增强

目标: 光标行和内容行使用完全一致的坐标和快照。

检查 `NativeTerminalRenderer.ets`:

- `drawRow()`、`drawCellAt()`、`drawCursor()` 必须全部使用同一个 `gridTop()`。
- `eraseOldCursor()` 中旧光标如果落在 viewport 外, 必须安全 no-op。
- `applyDirtySnapshot()` 应同时包含:
  - dirty rows
  - 新 cursor row
  - 旧 cursor row

当前 native renderer 只强制包含新 cursor row, 旧 cursor 依赖 `eraseOldCursor()` 重画单 cell。建议显式把旧 cursor row 加入 dirtyRows, 更稳:

```ts
if (this.lastCursorY >= 0 && this.lastCursorY < snap.rows) {
  this.dirtyRows.add(this.lastCursorY);
}
```

验收:

- 方向键移动光标不残留下划线。
- 长输出滚屏时旧光标不留在历史行。
- `top`/进度条输出不出现双光标。

### Phase E: 顶栏安全区二次打磨

目标: 顶栏既避开状态栏/摄像头, 又不显得过厚。

当前逻辑:

```ts
topChromeOffset() = isDesktop ? 0 : Math.max(8, topSafeHeight)
headerHeight() = 56 + topChromeOffset()
padding.top = 6 + topChromeOffset()
```

建议实机确认后再微调:

- 如果移动端顶栏过厚, 可改为 `Math.max(6, topSafeHeight)`。
- 如果有设备 `TYPE_CUTOUT.topRect.height` 为 0 但仍遮挡, 尝试 `getWindowAvoidAreaIgnoringVisibility(TYPE_CUTOUT)` 或 ArkUI `safeAreaPadding` 路线, 先查本地 API 23 文档。
- PC 端保持 `topChromeOffset() == 0`, 不要把桌面标题栏也撑高。

验收:

- 手机/平板顶部内容不压状态栏。
- 摄像头/挖孔区域不遮住返回按钮、主机名、粘贴按钮。
- PC 顶栏高度保持现状。

### Phase F: 真实设备验证与微调

优先在真实手机/Pad 上验证, 模拟器不一定可靠复现软键盘避让。

建议记录这些运行时值:

```text
shellAreaH
terminalViewportH
termAreaH
termRows
cellHvp
kbHeight
navHeight
topSafeHeight
barTop
scrollToBottomRequest
```

如果问题仍复现, 首先判断是哪一种:

- rows 算多: `rows * cellH > actual visible terminal area`。
- viewportHeight 过大: renderer 认为还有空间, 实际被键盘遮住。
- bottom sync 顺序错: 先 scroll bottom, 后 resize rows, 导致 snapshot 又被旧行数覆盖。
- native snapshot 问题: `screenTop/viewTop/cursorY` 映射错误。
- ArkUI Canvas 缩放问题: Canvas CSS 高度与内部绘制坐标不是同一单位。

## Claude Code 可直接使用的起始 Prompt

```text
请阅读并严格执行 docs/SSH_TERMINAL_CLAUDECODE_HANDOFF.md。当前任务是在已有提交 6afc956 和 29c1e8f 的基础上继续优化 SSH 终端界面稳定性, 不要重做 Rust terminal_core 迁移。

本轮优先做 Phase A、Phase B、Phase D:
1. 更新或新增 docs/SSH_TERMINAL_TEST_CASES.md, 写出键盘挤压、最新行贴底、光标不错位、顶栏避让的手工验收用例。
2. 在 SshTerminal.ets 中把 scattered scrollToBottom 定时器集中为一个 bottom sync 调度器, aboutToDisappear 中清理 timer。
3. 在 NativeTerminalRenderer.ets 中增强 dirtyRows, 显式包含旧光标行和新光标行, 确保光标移动/滚屏不残留。
4. 不要删除 TerminalEmulator.ets, fallback 仍需保留。
5. 不要修改 SSH 网络连接或 Rust parser, 除非验证证明问题来自 terminal_core snapshot。
6. 修改后运行构建:
   $env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
   node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry assembleHap
7. 构建通过后提交一个清晰 commit。

完成前请汇报: 改了哪些文件、构建是否通过、还有哪些设备场景需要人工复测。
```

## 当前建议优先级

1. Phase A: 写清验收用例。
2. Phase B: 集中 bottom sync 调度器。
3. Phase D: 光标 dirty row 增强。
4. Phase C: 如果仍有跳行, 再统一 viewport/rows 来源。
5. Phase E/F: 根据真实设备表现微调顶部安全区和键盘避让。
