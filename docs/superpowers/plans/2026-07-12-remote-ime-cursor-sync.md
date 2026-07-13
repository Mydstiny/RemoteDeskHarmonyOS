# Remote IME Cursor Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 HarmonyOS 系统虚拟键盘的空格滑动/光标拖拽手势在 RDP 和 RustDesk 远程编辑器中产生一致的相对光标移动，并消除长文本重复、丢失和输入位置错位。

**Architecture:** 使用持久但隐藏的 `TextArea` 作为系统 IME 的本地影子编辑器，通过纯 ArkTS 策略将独立的 selection 变化转换为远端 Left/Right 命令。所有 IME 文本、删除、回车和光标命令经过同一 ArkTS FIFO；RDP 再以原子 `TextBatch` 进入不可丢的 native FIFO，RustDesk 保持现有 `ControlMsg` FIFO 并新增消息构造与顺序测试。

**Tech Stack:** HarmonyOS NEXT API 23、ArkTS 严格模式、ArkUI `TextArea`/`TextAreaController`、Hypium、C++17、FreeRDP 3.x、Rust 2021、RustDesk protobuf、DevEco hvigor。

## Global Constraints

- 设计规格为 `docs/superpowers/specs/2026-07-12-remote-ime-cursor-sync-design.md`；实现不得扩大其范围。
- 只支持 RDP 与 RustDesk 的远程桌面键盘；不得改变 SSH `VirtualKeyBar`、SSH 终端输入或 VNC mock。
- 系统键盘的空格滑动是主交互；不得用自定义键盘、长按箭头栏或剪贴板粘贴替代。
- 只能保证最近同步锚点后的相对 caret 移动；不得声称读取了远端真实文本、选区或绝对 caret。
- `onDidInsert`/`onDidDelete` 是唯一远端文本/删除提交边界；`onChange` 只维护本地 shadow value。
- IME 预上屏、拼音中间态和候选切换不得发送到远端。
- 鼠标移动可以合并或丢弃；文本、键盘、鼠标按钮、滚轮、删除和 Enter 不得静默丢弃或重排。
- 日志不得包含 shadow text、插入文本、删除文本、候选文字或派生字符值，只允许长度、序号、selection 和队列指标。
- 不修改 RDP 证书、认证、ErrorInfo/no-frame、渲染/GFX/GDI、音频、剪贴板、rdpdr/共享盘或用户设置。
- 不修改 RustDesk 加密、frame reader、视频/音频、剪贴板、中继、文件传输、隐私模式或顶栏语义。
- 当前分支为 `codex/rdp-rustdesk-video-performance`，设计提交为 `1349316e`；保留工作区所有无关改动。
- 每个代码提交前必须先通过对应测试、`git diff --check` 和生产 `assembleHap`；已知 ohosTest SourceMap `reading 'share'` 若仍存在，单独记录，不能伪报测试通过。

## File Structure

- Create `entry/src/main/ets/services/RemoteImeSessionPolicy.ets`: 影子窗口、selection 分类、删除动作、recenter 与移动分块的纯函数。
- Create `entry/src/main/ets/services/RemoteImeCommandQueue.ets`: IME 非一次性命令 FIFO，确保大位移未完成时后续文本不能越过。
- Create `entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets`: ArkTS selection/IME 策略测试。
- Create `entry/src/ohosTest/ets/test/RemoteImeCommandQueue.test.ets`: ArkTS 命令顺序、分块和清理测试。
- Modify `entry/src/ohosTest/ets/test/List.test.ets`: 注册两个新增测试套件。
- Modify `entry/src/main/ets/pages/RemoteDesktop.ets`: 用隐藏 `TextArea` 接入策略、命令泵和生命周期重置。
- Create `entry/src/main/cpp/rdp/rdp_input_queue.h`: 纯 C++ 原子输入事件和不可丢队列。
- Create `entry/src/main/cpp/test/rdp_input_queue_test.cpp`: 队列压力、TextBatch、Unicode down/release 顺序测试。
- Modify `entry/src/main/cpp/rdp/freerdp_adapter.cpp`: 使用原子队列并在 worker 中展开 TextBatch。
- Modify `entry/src/main/cpp/rdp/rdp_render_policy.h`: 删除已迁移的 `RdpInputPolicy`。
- Modify `entry/src/main/cpp/test/rdp_render_policy_test.cpp`: 删除不再属于渲染策略的输入队列测试。
- Modify `entry/src/main/cpp/CMakeLists.txt`: 注册新的 native 测试。
- Modify `entry/src/main/cpp/extensions/protocol_adapter.h`: 增加输入队列诊断字段。
- Modify `entry/src/main/cpp/extensions/extension_loader_napi.cpp`: 导出新增诊断字段。
- Modify `entry/src/main/ets/types/rdpnapi.d.ts`: 声明新增诊断字段。
- Modify `entry/src/main/ets/services/ExtensionLoader.ets`: 补充诊断 fallback。
- Modify `rustdesk_ffi/src/connector.rs`: 提取可测的 key/text protobuf 构造函数并补顺序测试。

---

### Task 1: 建立可测试的影子 IME 会话策略

**Files:**
- Create: `entry/src/main/ets/services/RemoteImeSessionPolicy.ets`
- Create: `entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Consumes: API 23 `TextDeleteDirection.BACKWARD/FORWARD` 的数值 `0/1`、UTF-16 string length、collapsed selection。
- Produces: `createRemoteImeShadow()`、`resolveRemoteImeSelection()`、`splitRemoteImeCaretMovement()`、`resolveRemoteImeDelete()`、`shouldRecenterRemoteImeShadow()`。

- [ ] **Step 1: 写策略失败测试并注册套件**

创建 `RemoteImeSessionPolicy.test.ets`：

```ts
import { describe, it, expect } from '@ohos/hypium';
import {
  REMOTE_IME_CENTER,
  RemoteImeSelectionAction,
  createRemoteImeShadow,
  resolveRemoteImeDelete,
  resolveRemoteImeSelection,
  shouldRecenterRemoteImeShadow,
  splitRemoteImeCaretMovement
} from '../../../main/ets/services/RemoteImeSessionPolicy';

export default function remoteImeSessionPolicyTest(): void {
  describe('RemoteImeSessionPolicy', (): void => {
    it('creates_bounded_shadow_around_center', 0, (): void => {
      const shadow = createRemoteImeShadow();
      expect(shadow.caret).assertEqual(REMOTE_IME_CENTER);
      expect(shadow.text.length).assertEqual(REMOTE_IME_CENTER * 2);
    });

    it('ignores_expected_and_programmatic_selection', 0, (): void => {
      const expected = resolveRemoteImeSelection({
        active: true, programmatic: false, expectedStart: 2050, expectedEnd: 2050,
        syncedCaret: 2048, selectionStart: 2050, selectionEnd: 2050
      });
      expect(expected.action).assertEqual(RemoteImeSelectionAction.IGNORE_EXPECTED);
      const programmatic = resolveRemoteImeSelection({
        active: true, programmatic: true, expectedStart: -1, expectedEnd: -1,
        syncedCaret: 2048, selectionStart: 2048, selectionEnd: 2048
      });
      expect(programmatic.action).assertEqual(RemoteImeSelectionAction.IGNORE_PROGRAMMATIC);
    });

    it('converts_collapsed_selection_to_relative_movement', 0, (): void => {
      const left = resolveRemoteImeSelection({
        active: true, programmatic: false, expectedStart: -1, expectedEnd: -1,
        syncedCaret: 2048, selectionStart: 2035, selectionEnd: 2035
      });
      expect(left.action).assertEqual(RemoteImeSelectionAction.MOVE_LEFT);
      expect(left.count).assertEqual(13);
      const right = resolveRemoteImeSelection({
        active: true, programmatic: false, expectedStart: -1, expectedEnd: -1,
        syncedCaret: 2035, selectionStart: 2042, selectionEnd: 2042
      });
      expect(right.action).assertEqual(RemoteImeSelectionAction.MOVE_RIGHT);
      expect(right.count).assertEqual(7);
    });

    it('does_not_translate_expanded_selection', 0, (): void => {
      const result = resolveRemoteImeSelection({
        active: true, programmatic: false, expectedStart: -1, expectedEnd: -1,
        syncedCaret: 2048, selectionStart: 2038, selectionEnd: 2048
      });
      expect(result.action).assertEqual(RemoteImeSelectionAction.COLLAPSE_LOCAL);
      expect(result.count).assertEqual(0);
    });

    it('chunks_large_movement_without_losing_count', 0, (): void => {
      const chunks: number[] = splitRemoteImeCaretMovement(700, 256);
      expect(chunks.length).assertEqual(3);
      expect(chunks[0]).assertEqual(256);
      expect(chunks[1]).assertEqual(256);
      expect(chunks[2]).assertEqual(188);
    });

    it('maps_delete_direction_and_recenter_threshold', 0, (): void => {
      expect(resolveRemoteImeDelete(0, 'abc'.length).backwardCount).assertEqual(3);
      expect(resolveRemoteImeDelete(1, 'x'.length).forwardCount).assertEqual(1);
      expect(shouldRecenterRemoteImeShadow(255, 4096)).assertTrue();
      expect(shouldRecenterRemoteImeShadow(2048, 4096)).assertFalse();
    });
  });
}
```

在 `List.test.ets` 导入并调用 `remoteImeSessionPolicyTest()`。

- [ ] **Step 2: 运行 RED 验证**

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME=$env:DEVECO_SDK_HOME
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS --analyze=normal --parallel --incremental --daemon
```

预期：缺少 `RemoteImeSessionPolicy` 导出而失败；若先命中已知 SourceMap 错误，保存完整错误，并通过 `rg` 确认测试注册存在。

- [ ] **Step 3: 实现最小纯策略 API**

实现以下公开类型和函数；内部不得导入 ArkUI 或协议 loader：

```ts
export const REMOTE_IME_CENTER: number = 2048;
export const REMOTE_IME_EDGE_THRESHOLD: number = 256;

export enum RemoteImeSelectionAction {
  IGNORE_INACTIVE = 0,
  IGNORE_PROGRAMMATIC = 1,
  IGNORE_EXPECTED = 2,
  MOVE_LEFT = 3,
  MOVE_RIGHT = 4,
  COLLAPSE_LOCAL = 5
}

export interface RemoteImeSelectionInput {
  active: boolean;
  programmatic: boolean;
  expectedStart: number;
  expectedEnd: number;
  syncedCaret: number;
  selectionStart: number;
  selectionEnd: number;
}

export interface RemoteImeSelectionResult {
  action: RemoteImeSelectionAction;
  count: number;
  nextSyncedCaret: number;
  consumeExpected: boolean;
}

export interface RemoteImeShadow { text: string; caret: number; }
export interface RemoteImeDeleteResult { backwardCount: number; forwardCount: number; }

export function createRemoteImeShadow(): RemoteImeShadow {
  let text: string = '';
  for (let i: number = 0; i < REMOTE_IME_CENTER * 2; i++) { text += ' '; }
  return { text: text, caret: REMOTE_IME_CENTER };
}

export function resolveRemoteImeSelection(input: RemoteImeSelectionInput): RemoteImeSelectionResult {
  if (!input.active) return result(RemoteImeSelectionAction.IGNORE_INACTIVE, 0, input.syncedCaret, false);
  if (input.programmatic) return result(RemoteImeSelectionAction.IGNORE_PROGRAMMATIC, 0, input.syncedCaret, false);
  if (input.selectionStart === input.expectedStart && input.selectionEnd === input.expectedEnd) {
    return result(RemoteImeSelectionAction.IGNORE_EXPECTED, 0, input.selectionEnd, true);
  }
  if (input.selectionStart !== input.selectionEnd) {
    return result(RemoteImeSelectionAction.COLLAPSE_LOCAL, 0, input.syncedCaret, false);
  }
  const delta: number = input.selectionEnd - input.syncedCaret;
  if (delta < 0) return result(RemoteImeSelectionAction.MOVE_LEFT, -delta, input.selectionEnd, false);
  if (delta > 0) return result(RemoteImeSelectionAction.MOVE_RIGHT, delta, input.selectionEnd, false);
  return result(RemoteImeSelectionAction.IGNORE_EXPECTED, 0, input.syncedCaret, false);
}
```

在同一文件加入以下完整辅助函数；删除方向 `0` 是 backward，`1` 是 forward：

```ts
function result(action: RemoteImeSelectionAction, count: number,
  nextSyncedCaret: number, consumeExpected: boolean): RemoteImeSelectionResult {
  return { action: action, count: count, nextSyncedCaret: nextSyncedCaret,
    consumeExpected: consumeExpected };
}

export function splitRemoteImeCaretMovement(count: number, maxChunk: number = 256): number[] {
  const chunks: number[] = [];
  let remaining: number = Math.max(0, count);
  const limit: number = Math.max(1, maxChunk);
  while (remaining > 0) {
    const chunk: number = Math.min(limit, remaining);
    chunks.push(chunk);
    remaining -= chunk;
  }
  return chunks;
}

export function resolveRemoteImeDelete(direction: number,
  deleteValueLength: number): RemoteImeDeleteResult {
  const count: number = Math.max(1, deleteValueLength);
  return direction === 1 ? { backwardCount: 0, forwardCount: count } :
    { backwardCount: count, forwardCount: 0 };
}

export function shouldRecenterRemoteImeShadow(caret: number, textLength: number): boolean {
  return caret < REMOTE_IME_EDGE_THRESHOLD ||
    caret > textLength - REMOTE_IME_EDGE_THRESHOLD;
}
```

- [ ] **Step 4: 运行 GREEN、生产构建和差异检查**

再次运行 ohosTest 构建，然后运行：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git diff --check -- entry/src/main/ets/services/RemoteImeSessionPolicy.ets entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets entry/src/ohosTest/ets/test/List.test.ets
```

预期：生产构建成功；无 ArkTS 源码错误或空白错误。SourceMap 工具错误若存在，记录但不得归因于新策略。

- [ ] **Step 5: 提交策略**

```powershell
git add entry/src/main/ets/services/RemoteImeSessionPolicy.ets entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets entry/src/ohosTest/ets/test/List.test.ets
git commit -m "test(remote): define ime cursor session policy"
```

### Task 2: 建立严格有序的 ArkTS IME 命令队列

**Files:**
- Create: `entry/src/main/ets/services/RemoteImeCommandQueue.ets`
- Create: `entry/src/ohosTest/ets/test/RemoteImeCommandQueue.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Consumes: 已提交文本、Harmony key code、tap 次数、session generation。
- Produces: `RemoteImeCommandQueue.enqueueText/enqueueKeyTaps/shift/pushFront/clear/size`。

- [ ] **Step 1: 写 FIFO 与剩余移动优先测试**

```ts
import { describe, it, expect } from '@ohos/hypium';
import { RemoteImeCommandKind, RemoteImeCommandQueue } from '../../../main/ets/services/RemoteImeCommandQueue';

export default function remoteImeCommandQueueTest(): void {
  describe('RemoteImeCommandQueue', (): void => {
    it('keeps_text_cursor_text_order', 0, (): void => {
      const queue = new RemoteImeCommandQueue();
      queue.enqueueText('alpha', 4, 'didInsert');
      queue.enqueueKeyTaps(2014, 300, 4, 'selection');
      queue.enqueueText('omega', 4, 'didInsert');
      expect(queue.shift()!.kind).assertEqual(RemoteImeCommandKind.TEXT);
      const movement = queue.shift()!;
      expect(movement.tapCount).assertEqual(300);
      movement.tapCount = 268;
      queue.pushFront(movement);
      expect(queue.shift()!.tapCount).assertEqual(268);
      expect(queue.shift()!.text).assertEqual('omega');
    });

    it('clear_discards_old_generation_commands', 0, (): void => {
      const queue = new RemoteImeCommandQueue();
      queue.enqueueKeyTaps(2015, 10, 2, 'selection');
      queue.clear();
      expect(queue.size()).assertEqual(0);
    });
  });
}
```

注册 `remoteImeCommandQueueTest()`。

- [ ] **Step 2: 运行 RED 验证**

运行 Task 1 的 ohosTest 构建命令。预期：缺少队列模块或导出而失败；已知 SourceMap 错误单独记录。

- [ ] **Step 3: 实现显式严格类型队列**

```ts
export enum RemoteImeCommandKind { TEXT = 0, KEY_TAPS = 1 }

export interface RemoteImeCommand {
  kind: RemoteImeCommandKind;
  text: string;
  keyCode: number;
  tapCount: number;
  generation: number;
  source: string;
}

export class RemoteImeCommandQueue {
  private commands: RemoteImeCommand[] = [];

  enqueueText(text: string, generation: number, source: string): void {
    if (text.length === 0) return;
    this.commands.push({ kind: RemoteImeCommandKind.TEXT, text: text, keyCode: 0,
      tapCount: 0, generation: generation, source: source });
  }

  enqueueKeyTaps(keyCode: number, count: number, generation: number, source: string): void {
    if (count <= 0) return;
    this.commands.push({ kind: RemoteImeCommandKind.KEY_TAPS, text: '', keyCode: keyCode,
      tapCount: count, generation: generation, source: source });
  }

  shift(): RemoteImeCommand | null { return this.commands.length > 0 ? this.commands.shift()! : null; }
  pushFront(command: RemoteImeCommand): void { this.commands.unshift(command); }
  clear(): void { this.commands = []; }
  size(): number { return this.commands.length; }
}
```

队列不合并不同 source/generation；不得写入日志，也不得暴露读取全部文本的调试 API。

- [ ] **Step 4: 运行 GREEN、生产构建和提交**

运行 ohosTest、`assembleHap` 和 scoped `git diff --check`。成功后：

```powershell
git add entry/src/main/ets/services/RemoteImeCommandQueue.ets entry/src/ohosTest/ets/test/RemoteImeCommandQueue.test.ets entry/src/ohosTest/ets/test/List.test.ets
git commit -m "feat(remote): queue ime commands in order"
```

### Task 3: 接入持久 TextArea、selection 手势和生命周期重置

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets:19-83,295-330,611-623,2102-2118,2620-2730,3510-3638,3834-3858,3889-4075,4335-4370,4727-4773`
- Test: `entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets`
- Test: `entry/src/ohosTest/ets/test/RemoteImeCommandQueue.test.ets`

**Interfaces:**
- Consumes: Task 1 策略与 Task 2 FIFO、`ExtensionLoader.sendText/sendKey()`、现有 `canForwardInput()`。
- Produces: 一个系统 IME 会话、一个 generation 受控命令泵、RDP/RustDesk 共用的相对 caret 行为。

- [ ] **Step 1: 先扩展策略测试覆盖 lifecycle 与隐私元数据**

在策略测试增加：inactive selection 不产生移动、recenter 回调被标记为 programmatic、诊断对象只含 `source/units/oldCaret/newCaret/delta/result`。运行 ohosTest，预期缺少对应 `createRemoteImeDiagnostic()` 导出而失败，然后按以下接口实现；函数不得接收输入字符串：

```ts
export interface RemoteImeDiagnostic {
  source: string;
  units: number;
  oldCaret: number;
  newCaret: number;
  delta: number;
  result: string;
}

export function createRemoteImeDiagnostic(source: string, units: number,
  oldCaret: number, newCaret: number, resultValue: string): RemoteImeDiagnostic {
  return { source: source, units: units, oldCaret: oldCaret, newCaret: newCaret,
    delta: newCaret - oldCaret, result: resultValue };
}
```

- [ ] **Step 2: 替换页面键盘状态和打开/关闭流程**

导入 Task 1/2 类型，将 `TextInputController` 替换为 `TextAreaController`，新增显式字段：

```ts
private keyboardController: TextAreaController = new TextAreaController();
private keyboardImeActive: boolean = false;
private keyboardImeGeneration: number = 0;
private keyboardSyncedCaret: number = REMOTE_IME_CENTER;
private keyboardExpectedStart: number = -1;
private keyboardExpectedEnd: number = -1;
private keyboardProgrammaticSelection: boolean = false;
private keyboardCommandQueue: RemoteImeCommandQueue = new RemoteImeCommandQueue();
private keyboardCommandPumpTimer: number = -1;
```

`openKeyboard()` 调用 `startRemoteImeSession()`：创建 shadow、递增 generation、设置 `keyboardImeActive=true`，下一事件循环调用 `setTextSelection(center, center, { menuPolicy: MenuPolicy.HIDE })`。`markKeyboardClosed()` 调用 `resetRemoteImeSession(source)`：取消 timer、清空命令、清空 shadow、失效 generation 和 expected selection。

- [ ] **Step 3: 使用完成态回调实现 exactly-once**

删除 `handleKeyboardSoftInsert()`、`handleKeyboardSoftDelete()` 和会发送文本的 `handleKeyboardChangeGuard()`，替换为：

```ts
private handleKeyboardWillInsert(info: InsertValue): boolean {
  this.keyboardExpectedStart = info.insertOffset + info.insertValue.length;
  this.keyboardExpectedEnd = this.keyboardExpectedStart;
  return this.keyboardImeActive;
}

private handleKeyboardDidInsert(info: InsertValue): void {
  if (!this.keyboardImeActive || info.insertValue.length === 0) return;
  this.keyboardSyncedCaret = info.insertOffset + info.insertValue.length;
  this.keyboardCommandQueue.enqueueText(info.insertValue, this.keyboardImeGeneration, 'didInsert');
  this.scheduleRemoteImeCommandPump();
}

private handleKeyboardWillDelete(info: DeleteValue): boolean {
  this.keyboardExpectedStart = info.deleteOffset;
  this.keyboardExpectedEnd = info.deleteOffset;
  return this.keyboardImeActive;
}

private handleKeyboardDidDelete(info: DeleteValue): void {
  if (!this.keyboardImeActive) return;
  const deletion = resolveRemoteImeDelete(info.direction as number, info.deleteValue.length);
  this.keyboardSyncedCaret = info.deleteOffset;
  this.enqueueRemoteImeDelete(deletion.backwardCount, deletion.forwardCount);
}
```

`onChange` 只能执行 `this.keyboardText = value`。`onSubmit` 把 Enter tap 入同一 FIFO，不再直接 `loader.sendKey()`。

- [ ] **Step 4: 接入 selection 分类和命令泵**

`handleKeyboardSelectionChange(start,end)` 调用 `resolveRemoteImeSelection()`。`MOVE_LEFT/RIGHT` 分别入队 2014/2015；expected 命中后清除 expected；`COLLAPSE_LOCAL` 使用 programmatic guard 将 selection 折叠回 `keyboardSyncedCaret`。

命令泵每个事件循环最多发送 32 个 tap：

```ts
private pumpRemoteImeCommands(): void {
  this.keyboardCommandPumpTimer = -1;
  const command: RemoteImeCommand | null = this.keyboardCommandQueue.shift();
  if (command === null || command.generation !== this.keyboardImeGeneration ||
    !this.keyboardImeActive || !this.canForwardInput('key')) {
    if (command !== null) this.resetRemoteImeSession('input-unavailable');
    return;
  }
  if (command.kind === RemoteImeCommandKind.TEXT) {
    this.loader.sendText(this.sessionId, command.text);
  } else {
    const sendCount: number = Math.min(32, command.tapCount);
    for (let i: number = 0; i < sendCount; i++) {
      this.loader.sendKey(this.sessionId, command.keyCode, true);
      this.loader.sendKey(this.sessionId, command.keyCode, false);
    }
    command.tapCount -= sendCount;
    if (command.tapCount > 0) this.keyboardCommandQueue.pushFront(command);
  }
  if (this.keyboardCommandQueue.size() > 0) this.scheduleRemoteImeCommandPump();
}
```

日志只记录 generation、kind、tapCount、UTF-16 units 和队列 size，不记录 `command.text`。

- [ ] **Step 5: 将隐藏输入组件改为 TextArea**

```ts
TextArea({ text: this.keyboardText, controller: this.keyboardController })
  .id('RemoteDesktopKeyboard')
  .width(1).height(1).opacity(0.01).position({ x: 0, y: 0 })
  .defaultFocus(false).focusOnTouch(true).enableKeyboardOnFocus(true)
  .selectionMenuHidden(true)
  .onWillInsert((info: InsertValue): boolean => this.handleKeyboardWillInsert(info))
  .onDidInsert((info: InsertValue): void => this.handleKeyboardDidInsert(info))
  .onWillDelete((info: DeleteValue): boolean => this.handleKeyboardWillDelete(info))
  .onDidDelete((info: DeleteValue): void => this.handleKeyboardDidDelete(info))
  .onTextSelectionChange((start: number, end: number): void => {
    this.handleKeyboardSelectionChange(start, end);
  })
  .onChange((value: string): void => { this.keyboardText = value; })
```

保留现有 `onEditChange` 与 `onSubmit` 的键盘持续编辑语义，但远端发送必须走命令 FIFO。

- [ ] **Step 6: 接入 reset/recenter 生命周期**

在以下边界调用 `resetRemoteImeSession()` 或 `recenterRemoteImeAnchor()`：

- `TouchType.Down` 的第一根手指；
- `MouseAction.Press`；
- `detachForBackground()` 入口；
- `disconnectAndCleanup()` 入口；
- session id/host 切换；
- `markKeyboardClosed()` 与异常失焦。

只在 Down/Press 重置，不在 mouse move 或 touch move 重复重置。接近 shadow 两端时，等待命令 FIFO 清空后 recenter；programmatic selection 必须被策略忽略。

- [ ] **Step 7: 构建、静态契约检查和提交**

```powershell
rg -n "sendKeyboardText|handleKeyboardChangeGuard|resetKeyboardBuffer|TextInput\(\{ text: this.keyboardText" entry/src/main/ets/pages/RemoteDesktop.ets
rg -n "onDidInsert|onDidDelete|onTextSelectionChange|RemoteImeCommandQueue" entry/src/main/ets/pages/RemoteDesktop.ets
git diff --check -- entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/services/RemoteImeSessionPolicy.ets entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets
```

第一条不得再显示旧发送/每字清空路径；第二条必须显示新单一路径。运行 ohosTest 与生产 `assembleHap`，成功后：

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/services/RemoteImeSessionPolicy.ets entry/src/ohosTest/ets/test/RemoteImeSessionPolicy.test.ets
git commit -m "fix(remote): synchronize system ime cursor gestures"
```

### Task 4: 以 TDD 建立不可丢的 RDP 原子输入队列

**Files:**
- Create: `entry/src/main/cpp/rdp/rdp_input_queue.h`
- Create: `entry/src/main/cpp/test/rdp_input_queue_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt:124-154`
- Modify: `entry/src/main/cpp/rdp/rdp_render_policy.h:70-84`
- Modify: `entry/src/main/cpp/test/rdp_render_policy_test.cpp:74-81`

**Interfaces:**
- Consumes: neutral `uint16_t` flags/codes/coordinates and `std::u16string` batches。
- Produces: `RdpQueuedInputEvent`、`RdpInputQueue::enqueue/pop/clear/depth/maxDepth/textUnitDepth/droppedMouseMoves`、`DispatchTextBatch()`。

- [ ] **Step 1: 写 native RED 测试并加入 CMake**

创建测试覆盖 8,000 UTF-16 units、Text->Left->Text 顺序、超过 256 个 priority 事件不丢、mouse move 合并/丢弃、surrogate pair 相邻和每单元 down/release：

```cpp
#include "test_runner.h"
#include "rdp/rdp_input_queue.h"

RDP_TEST_CASE(rdp_input_queue_keeps_large_text_batch_atomic) {
    RdpInputQueue queue;
    std::u16string text(8000, u'中');
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(text)) == RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT_EQ(queue.depth(), 1);
    RDP_ASSERT_EQ(queue.textUnitDepth(), 8000);
    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.text.size(), 8000);
}

RDP_TEST_CASE(rdp_input_queue_never_evicts_priority_input) {
    RdpInputQueue queue;
    for (int i = 0; i < 300; ++i) queue.enqueue(RdpQueuedInputEvent::Key(0, static_cast<uint16_t>(i)));
    RDP_ASSERT_EQ(queue.depth(), 300);
    RDP_ASSERT_EQ(queue.droppedNonDisposable(), 0);
}

RDP_TEST_CASE(rdp_text_dispatch_keeps_down_release_pairs) {
    std::u16string text = { static_cast<char16_t>(0xD83D), static_cast<char16_t>(0xDE00) };
    std::vector<RdpUnicodeDispatch> calls;
    DispatchTextBatch(text, 0x8000, [&calls](uint16_t flags, uint16_t code) {
        calls.push_back({ flags, code });
    });
    RDP_ASSERT_EQ(calls.size(), 4);
    RDP_ASSERT_EQ(calls[0].flags, 0);
    RDP_ASSERT_EQ(calls[1].flags, 0x8000);
    RDP_ASSERT_EQ(calls[2].code, 0xDE00);
}
```

将 `test/rdp_input_queue_test.cpp` 加入 `rdp_native_tests`。从 `rdp_render_policy_test.cpp` 移除旧输入测试。

- [ ] **Step 2: 运行 native RED**

```powershell
cmake -S entry\src\main\cpp -B build\rdp-native-tests -DRDP_BUILD_TESTS=ON
cmake --build build\rdp-native-tests --target rdp_native_tests --config Release
```

预期：缺少 `rdp_input_queue.h` 或类型定义而编译失败。

- [ ] **Step 3: 实现纯队列**

在 header 中定义 `RdpInputEventType { Key, TextBatch, Mouse, MouseWheel }` 和工厂函数。`enqueue()` 规则必须是：末尾连续 mouse move 替换；priority 入队前清除旧 mouse move；队列达到 256 时新 mouse move 返回 `DroppedMouseMove`；priority 允许超过软上限并累计 `nonDisposableOverflow`，不得 `pop_front()`。

`DispatchTextBatch()` 使用模板 callback 对每个 `char16_t` 依次发 down 与 release。`clear()` 同时清零当前 depth/text units，但保留 lifetime drop/max metrics 直到 worker restart 明确调用 `resetMetrics()`。

- [ ] **Step 4: 运行 native GREEN 与全量生产构建**

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests --config Release
.\build\rdp-native-tests\rdp_native_tests.exe
git diff --check -- entry/src/main/cpp/rdp/rdp_input_queue.h entry/src/main/cpp/test/rdp_input_queue_test.cpp entry/src/main/cpp/CMakeLists.txt entry/src/main/cpp/rdp/rdp_render_policy.h entry/src/main/cpp/test/rdp_render_policy_test.cpp
```

预期：全部 native 测试通过，输出 `0 failed`。随后运行生产 `assembleHap`。

- [ ] **Step 5: 提交纯队列**

```powershell
git add entry/src/main/cpp/rdp/rdp_input_queue.h entry/src/main/cpp/test/rdp_input_queue_test.cpp entry/src/main/cpp/CMakeLists.txt entry/src/main/cpp/rdp/rdp_render_policy.h entry/src/main/cpp/test/rdp_render_policy_test.cpp
git commit -m "test(rdp): define lossless input queue"
```

### Task 5: 将 FreeRDP adapter 接到 TextBatch 并导出队列诊断

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp:45-60,534-728,2097-2100,2138-2219`
- Modify: `entry/src/main/cpp/extensions/protocol_adapter.h:149-175`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp:278-296`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts:136-153`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets:115-137`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets:2203-2214`

**Interfaces:**
- Consumes: Task 4 `RdpInputQueue` 与现有 `utf8ToUtf16()`。
- Produces: 原子 `FreeRdpAdapter::sendText()`、严格 FIFO worker、`inputTextUnits/inputDroppedMouseMoves/inputNonDisposableOverflow` 诊断。

- [ ] **Step 1: 先让 adapter 使用新事件类型并确认编译失败**

在 `freerdp_adapter.cpp` include `rdp_input_queue.h`，将内部 `QueuedInputEvent`/`std::deque` 替换为 `RdpInputQueue inputQueue`，但暂不改旧 aggregate 初始化。运行生产构建，预期旧初始化与新工厂 API 不匹配而失败，证明真实 adapter 已进入修改范围。

- [ ] **Step 2: 改造 worker 与所有输入生产者**

- `sendKey()` 使用 `RdpQueuedInputEvent::Key(flags, code)`。
- mouse move/button/wheel 使用对应工厂；点击的 move+button 在同一 mutex 临界区依次入队。
- `sendText()` 把 `utf8ToUtf16()` 结果转换为 `std::u16string`，只 enqueue 一个 `TextBatch`。
- worker pop 到 `TextBatch` 后调用 `DispatchTextBatch(text, KBD_FLAGS_RELEASE, callback)`；callback 内调用 `freerdp_input_send_unicode_keyboard_event()`。
- 其他事件继续调用原 FreeRDP API。
- stop/restart 清空队列并递增 worker generation；断连后不得发送残留 batch。

不得保留 `inputQueue.pop_front()` 或逐字符 `enqueueInputEvent()` 文本循环。

- [ ] **Step 3: 导出诊断字段**

在 `RdpRenderStats`、NAPI object、TypeScript interface 和 ExtensionLoader fallback 中一致增加：

```text
inputTextUnits: number
inputDroppedMouseMoves: number
inputNonDisposableOverflow: number
```

`getRdpRenderStats()` 在持有 `inputQueueMutex` 时读取队列指标。`RemoteDesktop` watchdog 只记录数值：

```ts
' inputTextUnits=' + stats.inputTextUnits.toString() +
' inputMouseDrops=' + stats.inputDroppedMouseMoves.toString() +
' inputPriorityOverflow=' + stats.inputNonDisposableOverflow.toString()
```

- [ ] **Step 4: native、生产与源码约束验证**

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests --config Release
.\build\rdp-native-tests\rdp_native_tests.exe
rg -n "inputQueue\.pop_front|for \(UINT16 cu.*enqueueInputEvent" entry/src/main/cpp/rdp/freerdp_adapter.cpp
rg -n "inputTextUnits|inputDroppedMouseMoves|inputNonDisposableOverflow" entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets
```

第一条源码检索不得匹配旧丢弃/逐字入队路径；诊断字段必须四层一致。运行 `git diff --check` 和生产 `assembleHap`。

- [ ] **Step 5: 提交 adapter 集成**

```powershell
git add entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "fix(rdp): preserve atomic text input order"
```

### Task 6: 用 Rust 单测固定 RustDesk 文本与光标顺序

**Files:**
- Modify: `rustdesk_ffi/src/connector.rs:1182-1239,1701-1838,1973-2010`

**Interfaces:**
- Consumes: `ControlMsg::Text/KeyEvent`、RustDesk protobuf `Message/KeyEvent`。
- Produces: `build_key_message()`、`build_text_message()` 和 FIFO/order tests；wire 发送语义不变。

- [ ] **Step 1: 写 RED 测试**

在 connector tests 中导入两个 builder，断言：CJK/emoji 仍为单一 `seq`；Left down 生成 `ControlKey::LeftArrow`；Left release 返回 `None`；mpsc 中 `Text -> Left down/up -> Text` 接收顺序不变。

```rust
#[test]
fn ime_text_cursor_text_keeps_fifo_order() {
    let (tx, rx) = std::sync::mpsc::channel();
    tx.send(crate::ControlMsg::Text { text: "中文😀".to_string() }).unwrap();
    tx.send(crate::ControlMsg::KeyEvent { scancode: 2014, pressed: true }).unwrap();
    tx.send(crate::ControlMsg::KeyEvent { scancode: 2014, pressed: false }).unwrap();
    tx.send(crate::ControlMsg::Text { text: "X".to_string() }).unwrap();
    assert_eq!(RustDeskConnector::control_msg_kind(&rx.recv().unwrap()), "text");
    assert_eq!(RustDeskConnector::control_msg_kind(&rx.recv().unwrap()), "key");
    assert_eq!(RustDeskConnector::control_msg_kind(&rx.recv().unwrap()), "key");
    assert_eq!(RustDeskConnector::control_msg_kind(&rx.recv().unwrap()), "text");
}
```

在 test module 的 `use` 列表加入 `RustDeskConnector`；不得创建第二套生产控制通道。

- [ ] **Step 2: 运行 RED**

```powershell
Set-Location rustdesk_ffi
cargo test --lib --no-default-features ime_text_cursor_text_keeps_fifo_order
Set-Location ..
```

预期：缺少 message builder 或测试导入而失败。

- [ ] **Step 3: 提取 protobuf builder 并保持发送函数薄封装**

```rust
fn build_text_message(text: &str) -> Option<Message> {
    if text.is_empty() { return None; }
    let mut key = KeyEvent::new();
    key.set_press(true);
    key.set_mode(KeyboardMode::Legacy);
    key.union = Some(KeyEvent_oneof_union::seq(text.to_string()));
    let mut msg = Message::new();
    msg.union = Some(Message_oneof_union::key_event(key));
    Some(msg)
}
```

`build_key_message(scancode, pressed)` 复用现有 Harmony mapping；非 modifier release 返回 `None`。`send_text_event_encrypted()` 与 `send_key_event_encrypted()` 只负责 build 后调用 `send_message_encrypted()`。日志继续只输出 len/scancode/control key，不输出 seq。

- [ ] **Step 4: 运行 Rust 全量与双 ABI 构建**

```powershell
Set-Location rustdesk_ffi
cargo test --lib --no-default-features
Set-Location ..
bash scripts/build_rustdesk_ffi_ohos.sh
```

预期：Rust tests 全部通过；脚本成功更新 arm64-v8a 与 x86_64 静态库。随后运行生产 `assembleHap`，确认真实 HAP 重新链接 Rust 产物。

- [ ] **Step 5: 检查与提交 Rust 变更和生成库**

```powershell
git diff --check -- rustdesk_ffi/src/connector.rs
git status --short -- rustdesk_ffi entry/src/main/cpp/libs libs
```

只 stage 当前脚本实际更新且仓库跟踪的 RustDesk 静态库，不纳入无关产物。生产构建成功后提交：

```powershell
git add rustdesk_ffi/src/connector.rs
git add -u -- rustdesk_ffi/target entry/src/main/cpp/libs libs
git commit -m "test(rustdesk): verify ordered ime input"
```

### Task 7: 完整回归、真机矩阵与交接

**Files:**
- Create: `docs/test-results/remote-ime-cursor-sync-2026-07-12.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify when architecture rules are confirmed: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`

**Interfaces:**
- Consumes: Tasks 1-6 的最终代码和设计规格验收标准。
- Produces: 可复核测试证据、设备结论、交接信息；不再改变输入实现。

- [ ] **Step 1: 运行完整本地验证**

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests --config Release
.\build\rdp-native-tests\rdp_native_tests.exe
Set-Location rustdesk_ffi
cargo test --lib --no-default-features
Set-Location ..
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME=$env:DEVECO_SDK_HOME
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS --analyze=normal --parallel --incremental --daemon
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git diff --check
```

在结果文档记录精确 passed/failed 数和构建耗时。ohosTest 若仍只失败于已知 SourceMap `share`，粘贴首个相关错误；若出现新 ArkTS 源码错误，停止设备测试并修复。

- [ ] **Step 2: 安装 HAP 并执行 RDP 矩阵**

在 Windows Notepad 使用系统键盘执行：

1. 输入 500 英文字符，空格滑动左移，插入 `[L]`，右移后插入 `[R]`。
2. 拼音输入、候选切换、提交中文；确认未完成拼音未远端上屏。
3. 输入 BMP 与 surrogate-pair emoji，滑动后插入标记。
4. 输入 20 行，执行 Backspace、Forward Delete、Enter 与滑动混合操作。
5. 分别提交 500、2,000、8,000 UTF-16 units，立即滑动并插入标记。
6. 验证日志 `inputDroppedMouseMoves` 可增长但文本完整，`inputNonDisposableOverflow` 不伴随丢字。

保存最终远端文本截图和 privacy-safe hilog；不得保存密码或真实敏感输入。

- [ ] **Step 3: 执行 RustDesk 和生命周期矩阵**

在 RustDesk 远端纯文本编辑器重复 Step 2 的文本/滑动组合，并测试：触摸远端画面、鼠标点击、关闭重开键盘、Home/后台/前台、断连重连、从 RDP 切换到 RustDesk。每次边界后第一次滑动不得重放旧 generation 的命令。

- [ ] **Step 4: 验证失败分支和回滚门禁**

如果某 HarmonyOS 系统键盘不产生 `onTextSelectionChange`：记录设备型号、系统版本、IME 版本和 privacy-safe callback trace；仅关闭 gesture translation，保留 exactly-once 完成态输入与 RDP TextBatch。不得恢复每字清空 + `caretPosition(0)` 或旧 `pop_front()` 行为。

- [ ] **Step 5: 更新知识与最终提交**

仅在 RDP/RustDesk 真机矩阵都通过后，将“shadow TextArea + selection delta + ordered TextBatch”写入 CODEWALK 永久规则。HANDOFF/TASKS/记忆记录：提交列表、构建结果、设备结果、已知限制和下一步。

```powershell
git add docs/test-results/remote-ime-cursor-sync-2026-07-12.md
git commit -m "docs: record remote ime cursor validation"
```

外部交换站文件按项目协议单独更新；不要将工作区无关改动混入最终提交。

## Plan Self-Review

- **Spec coverage:** Task 1 覆盖 shadow/selection/delete/recenter；Task 2-3 覆盖系统 IME、exactly-once、严格 ArkTS 顺序和生命周期；Task 4-5 覆盖 RDP TextBatch/no-drop/diagnostics；Task 6 覆盖 RustDesk FIFO 和 protobuf；Task 7 覆盖完整构建、设备矩阵、隐私与回滚。
- **Scope:** 没有 SSH、VNC、剪贴板、远端 helper、绝对 caret、选区扩展或自定义键盘工作。
- **Type consistency:** `RemoteImeCommand.generation`、`RemoteImeSelectionResult.nextSyncedCaret`、三个新增 RDP stats 字段在生产者、NAPI、d.ts、fallback 和日志中名称一致。
- **Order proof:** ArkTS FIFO 防止分块位移被后续文本超越；RDP TextBatch 防止 Unicode 单元与后续 key 交错；Rust mpsc 和 protobuf builder 测试固定 RustDesk 顺序。
- **Privacy proof:** 测试和日志只检查长度、类型、selection、generation 和队列指标，不输出命令 text。
