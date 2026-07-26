# 双指缩放、虚拟触控板与缩放后输入一致性修复计划

> 状态：仅完成调查和计划落盘，尚未实施代码修改。
>
> 日期：2026-07-24
>
> 仓库：`RemoteDeskHarmonyOS`
>
> 调查基线：`main` 当前 `fde2c50f8`。前一轮缩放性能和 RDP redraw 生命周期修复已在基线中；本计划只处理本轮复核发现的输入 ownership、双指平移、坐标契约和 viewport 世代一致性问题。

## 0. 执行边界

本文件是给后续实施 session 使用的实体计划。本轮只读审计和写入本计划，不修改 ArkTS、C++、Rust、构建配置或现有功能代码，不提交修复代码。

实施时必须：

- 从最新 `main` 创建独立分支，例如 `codex/pinch-double-check-hardening`。
- 每个独立问题先补失败测试，再做最小实现；一个步骤只产生一个主题明确的 commit。
- 保留当前工作区中与本任务无关的未跟踪文档：`docs/SSH_MODULE_UPGRADE_PLAN.md` 和 `docs/superpowers/plans/2026-07-24-vnc-isolated-settings-cloud-upgrade.md`。
- 不使用 `git reset --hard`、`git checkout --` 或覆盖其他 session 的工作。
- 完成后逐个复审 commit，执行完整验证，再将修复分支合并回 `main`，确认合并结果后删除修复分支。

## 1. 用户问题和验收目标

### 1.1 必须复现和关闭的问题

| 场景 | 用户现象 | 需要证明的结果 |
| --- | --- | --- |
| RustDesk -> Windows | 双指缩放一帧一帧、不顺滑 | UI 不等待 EGL、GL 或网络；缩放和画布移动连续，视频帧不会因缩放被阻塞 |
| RustDesk -> macOS | 双指一开始缩放，视频流停滞 | 本地缩放不依赖新视频帧；静止远端画面也能立即重绘；新帧仍持续接收和呈现 |
| RDP -> Windows | 双指缩放后鼠标、键盘不可用，连接像卡死 | pinch 只消费手指触摸流；物理鼠标、键盘和 RDP 输入 worker 仍可用 |
| 触控板模式 | pinch 与双指滚轮/右键互相触发 | pinch 一旦获得 ownership，整段双指序列不再发送远端鼠标、滚轮或右键 |
| 缩放后画布 | 无法移动缩放后的画布 | 缩放后双指拖动可继续平移本地画布并受边界约束；单指仍保留远端虚拟鼠标语义 |
| 缩放后虚拟鼠标 | 虚拟鼠标不动、漂移或落在画布外 | 输入使用当前同一份 transform；坐标映射不依赖坐标数值猜测；RDP/RustDesk 均收到正确的远端逻辑坐标 |

### 1.2 明确的产品语义

本计划采用以下默认语义，避免把“本地画布缩放”和“远端应用触控缩放”混成一种行为：

1. 本地画布缩放是显示层行为，不进入 RDP 或 RustDesk 的可靠控制消息队列。
2. 两指 pinch/drag 获得画布 ownership 后，只更新本地 `CanvasTransform`；两指移动承担画布 pan，不发送远端鼠标和滚轮。
3. 一指在缩放后的画布上仍是远端虚拟鼠标/直接触摸输入，不默认改成画布 pan，否则会破坏移动远端按钮的核心操作。
4. RustDesk “远端应用触控缩放”是显式开关下的协议行为。开启时，pinch 发送 RustDesk `TouchScale`/`TouchPan`；关闭时，只做本地画布变换。两条路径必须分别可观测、可测试。
5. 物理鼠标、物理触控板 AxisEvent 和键盘事件不属于 pinch 的 finger ownership，不能因为 canvas pinch 而被 `stopPropagation` 或状态机清掉。

## 2. 当前代码审计结论

### 2.1 已完成的基线能力

main 已包含上一轮针对“视频停滞/同步重绘/输入队列”的修复，实施本计划时不要重复改写：

- `GLRenderer::SetCanvasTransform()` 使用 pending transform 和版本发布，UI 侧不直接持有 EGL 生命周期锁。
- renderer 通过 `RequestRedraw()` 唤醒 retained frame；RDP 通过 frame pump/redraw notifier 处理静止帧重绘和 session 生命周期。
- ArkTS pinch 使用单次 `CanvasViewport`/`RemoteSurfaceTransform` 快照，避免每个 pinch update 重新读取几何。
- RustDesk control inbox 已有 touch update 合并和可靠边界设计；实施时仍需以压力测试验证键盘、鼠标按钮和视频接收没有被 touch update 饥饿。

这些修复解释了为什么不能只把问题归因于 FreeRDP 或视频解码。当前剩余问题主要在“谁拥有触摸序列”和“显示几何何时算生效”。

### 2.2 P0：pinch 结束后仍可能把尾部 TouchEvent 交给远端输入状态机

当前链路：

```text
PinchGesture.onActionEnd/onActionCancel
  -> releaseCanvasPinchInput()
  -> finishCanvasPinch()
  -> canvasPinchInputConsumed = false
  -> resetTouchGesture()
```

`RemoteDesktop.ets` 当前重点位置：

- `startCanvasPinch()`、`updateCanvasPinch()`、`finishCanvasPinch()`：约 `1635-1707` 行。
- `releaseCanvasPinchInput()`：约 `1709-1721` 行。
- `consumeCanvasPinchTouch()`：约 `1723-1736` 行。
- `handleConfiguredTouchInput()`：约 `7895-7934` 行。
- `handleTouchPadInput()` 和 `handleXComponentTouch()`：约 `7553-7893` 行。

ArkUI 手势回调和 `onTouch` 的最后一个 `Up`/`Cancel` 不应被当作同一个同步点。当前 `onActionEnd` 立即清掉消费标志，尾部 finger `Up` 可能重新进入：

- 触控板双指无移动右键判断；
- 触控板单指 click/drag 收尾；
- 直接触摸模式的 `touchLeftDown` release；
- `touchFingerCount`、`touchGestureDone` 和拖拽状态重置。

结果可能是缩放后误右键、重复释放左键、虚拟鼠标按钮粘住或下一次手势被错误识别。

当前 `remainingTouchCountAfterLift()` 已尝试根据 `touches` 和 `changedTouches` 计算剩余手指数，但它只被远端输入状态机使用；pinch ownership 在 `onActionEnd` 已经丢失，所以不能防止尾事件泄漏。

### 2.3 P0：局部坐标仍通过数值启发式猜测 vp/px

`mapInputPointWithTransform()` 当前包含：

```text
localX <= surfaceWidthVp + 1 ? localX : localX * surfaceWidthVp / surfaceWidthPx
localY <= surfaceHeightVp + 1 ? localY : localY * surfaceHeightVp / surfaceHeightPx
```

这把输入单位交给坐标大小猜测。高密度设备上，合法的 vp 坐标可能小于或大于对应像素范围；窗口缩放、XComponent surface 像素尺寸和 ArkUI 事件组件尺寸也可能暂时不同。错误分支会造成：

- 缩放后鼠标漂移或反向偏移；
- 触点被判断为不在 viewport 内而丢弃；
- 虚拟光标投影与真实输入点不重合；
- RDP 得到错误的绝对坐标，表现为“鼠标不动”。

### 2.4 P0：native viewport 快照没有变换世代，可能覆盖刚提交的本地变换

当前 native 结构：

- `GLRenderer` 有 `canvasTransformVersion_` 和 `appliedCanvasTransformVersion_`，但只在 native owner 消费 pending transform 时使用。
- `PublishViewportSnapshot()` 发布 source、surface 和 viewport 数值，但没有把“该 viewport 对应的 transform version”返回给 ArkTS。
- `NapiGetRendererViewport()` 返回的 `RendererViewport` 没有 generation/version 字段。
- `RemoteDesktop.applyCanvasTransform()` 先提交 native transform，再立即写入 JS 计算的 viewport cache。
- `readRendererViewport()` cache 过期后又读取 native 旧快照，可能把尚未应用新 transform 的旧 viewport 写回 JS cache。

因此 pinch 后的输入映射可能短暂使用旧 viewport。静止 macOS 画面尤其容易暴露这个问题，因为 native owner 只有在 retained redraw 真正执行后才发布新 viewport。

### 2.5 P1：缩放后的画布没有独立的 post-pinch pan 协议

`pinchCanvasTransform()` 支持同一次 pinch 内的 focal-point scale 和 center delta pan，但手势结束后没有独立的“画布平移状态”。结束后的一指仍然进入远端鼠标状态机，双指移动则可能落入：

- 触控板双指滚轮；
- 触控板双指右键候选；
- 直接模式的多指状态清理；
- 没有任何本地 pan。

这正是“缩放后无法移动画布”的结构性缺口，不应通过把所有一指拖动改成画布 pan 来修复，因为那会破坏虚拟鼠标。

### 2.6 P1：两套输入层同时挂在 XComponent 和 overlay

当前 build 同时存在：

- XComponent `.onTouch(this.handleConfiguredTouchInput)`、`.onMouse(this.handleXComponentMouse)`；
- `remoteInputSurface` overlay `.onTouch(this.handleConfiguredTouchInput)`、`PinchGesture`、`.onMouse`、`.onAxisEvent`。

overlay 使用 `HitTestMode.Block`，gesture 事件又具有独立的竞争/传播规则。必须把 gesture recognition、finger touch consumption、physical mouse/axis/key routing 视为一个 ownership coordinator，不能只依赖两个组件上的 `stopPropagation()`。

## 3. 官方依据和设计约束

### 3.1 HarmonyOS TouchEvent/MouseEvent/gesture

实施时以当前官方文档为准：

- [TouchEvent / TouchObject](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/ts-universal-events-touch-V14)
- [MouseEvent and mouse/key events](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/ts-universal-mouse-key-V14)
- [PinchGesture](https://developer.huawei.com/consumer/en/doc/harmonyos-references/ts-basic-gestures-pinchgesture)
- [Gesture settings and competition](https://developer.huawei.com/consumer/en/doc/harmonyos-references/ts-gesture-settings)
- [XComponent native/surface lifecycle](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/napi-xcomponent-guidelines)

已确认并必须编码成测试假设的约束：

1. TouchEvent/MouseEvent 的 `x/y` 是相对于事件组件左上角的局部坐标，单位是 `vp`。
2. `touches` 表示当前触摸集合，`changedTouches` 表示本次变化的触点；`changedTouches` 可能按显示刷新率重采样，不能把一次回调当作一次完整手指生命周期。
3. `TouchType.Cancel` 是正式终止路径，不能只依赖 `Up`。
4. `PinchGesture` 的 scale/focal center 只能更新本地状态；手势回调不能阻塞 EGL、网络或 RDP 输入。
5. `gesture`、`priorityGesture`、`parallelGesture` 等关系决定 gesture 与普通 touch 的竞争，实施前必须在 API 23 真机记录实际回调顺序。

坐标契约固定为：

```text
ArkUI Touch/Mouse/Axis/Pinch center: 局部 vp
    -> RemoteSurfaceTransform: vp -> surface px -> renderer viewport
    -> remote logical/display coordinate
    -> RDP UINT16 absolute x/y 或 RustDesk mouse coordinate
```

不能再通过“数值看起来像 vp 还是 px”选择分支。只有 renderer 几何计算和 GL viewport 使用 px；输入事件入口统一视为 vp。

### 3.2 RustDesk 官方源码

参考：

- [`flutter/lib/common/widgets/remote_input.dart`](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/common/widgets/remote_input.dart)
- [`flutter/lib/mobile/pages/remote_page.dart`](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/mobile/pages/remote_page.dart)

官方实现给出的可迁移原则：

- touch mode 与 mouse mode 分开；不能让 touch gesture 直接复用物理 mouse listener 的生命周期。
- 一指 pan、长按拖拽、双指 scale 和双指平移有明确优先级。
- gesture 被识别后，缓存并阻断可能误触发的 tap，直到本次手指序列结束。
- 双指 scale update 使用相对 scale 和 focal point；双指移动可在同一画布状态中承担 pan。
- mouse/pointer listener 独立投递鼠标事件，不因 pinch 的本地画布状态而停发。

本项目应移植的是 ownership、tap 抑制、focal-point 变换和输入隔离，不是直接移植 Flutter widget。

### 3.3 FreeRDP 官方源码

参考：

- [`freerdp/libfreerdp/core/input.c`](https://github.com/FreeRDP/FreeRDP/blob/master/libfreerdp/core/input.c)

FreeRDP 的输入边界：

- `freerdp_input_send_mouse_event()` 发送远端桌面绝对坐标 `UINT16 x/y`。
- `PTR_FLAGS_MOVE` 是绝对移动标志。
- 相对移动使用独立的 `freerdp_input_send_rel_mouse_event()`，不能把本地 renderer 像素坐标直接塞进绝对事件。

所以 RDP 的验收必须检查“缩放后的 ArkUI vp -> remote logical desktop -> UINT16”这一条链，而不是只看鼠标是否产生了事件。

## 4. 目标架构和不变量

### 4.1 Ownership 状态机

引入一个可单测的纯策略状态，至少包含：

```text
Idle
  -> Candidate：两指尚未被 pinch 识别，普通 touch 暂时保留候选状态
  -> CanvasGesture：pinch/pan 已获得本地画布 ownership
  -> DrainTouches：gesture end/cancel 已发生，但等待最后 finger Up/Cancel
  -> Idle：最后一个 finger Up/Cancel 到达
```

状态规则：

1. `CanvasGesture` 和 `DrainTouches` 只消费 `SourceTool.FINGER`。
2. `DrainTouches` 必须消费所有尾部 finger `Move/Up/Cancel`，不得进入触控板右键、滚轮、直接鼠标 release 或 click 分支。
3. `Cancel` 直接终止，并保证本地左键/远端 touch stream 最多释放一次。
4. 如果手指序列在 gesture callback 之前已经完整结束，下一次新的 `Down` 必须能够正常创建新手势，不能被旧 ownership 吞掉。
5. 物理 Mouse、Axis 和 Key 事件在任何 canvas state 下都保持独立通道。
6. 生命周期终止（断连、surface destroy、PIP transfer、页面消失）可以强制清理，不等待不存在的后续 TouchEvent。

### 4.2 本地画布 transform

画布变换保持现有 `CanvasTransform { scale, panX, panY }`，但规定：

- `scale` 是相对 contain scale 的乘数。
- `panX/panY` 是 surface px 的 top-left 坐标系。
- pinch update 先按 relative scale 更新 focal-point，再应用两指中心移动 delta，最后 clamp。
- 变换提交仍是 latest-value-wins、非阻塞；不得回退到每次 update 读取 native viewport 或发送可靠协议消息。
- 缩放后双指 pan 复用同一 transform；内容未超出 surface 时 pan 应归零/被 clamp。

### 4.3 几何快照和 viewport 世代

将以下几何视为一个不可拆分 snapshot：

```text
remote logical size
renderer source size
renderer surface px size
renderer viewport px rect
surface vp size
canvas transform
geometry/transform revision
```

native `RendererViewport` 必须返回至少一个 `appliedTransformVersion` 或等价 generation。ArkTS 需要区分：

- `nativeApplied`：renderer 已经绘制并发布的 viewport；
- `localPending`：ArkTS 已提交但 native 尚未消费的最新 transform；
- `staleNative`：native 返回的 version 小于当前 pending version，不能覆盖本地 cache。

输入事件只能读取一个稳定 snapshot；不得在同一事件中分别读取 viewport、surface size 和 transform 造成混合代际。

## 5. 分步实施计划和 commit 边界

以下是后续 session 的执行顺序。每一步完成后先跑对应测试，再提交一次；不要把多个步骤合并成一个“大修复”。

### Step 1：pinch 尾部 TouchEvent drain

目标：修复 gesture end/cancel 后尾部 TouchEvent 进入远端触控板或直接鼠标状态机。

预计文件：

- `entry/src/main/ets/services/RemoteCanvasPinchInputPolicy.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/test/RemoteCanvasPinchInputPolicy.test.ets`
- 必要时 `entry/src/ohosTest/ets/test/RemoteCanvasPinchInputPolicy.test.ets` 和对应 `List.test.ets`

实现要点：

1. 将当前单一 boolean 扩展为可表达 `CanvasGesture/DrainTouches/Idle` 的状态，记录本次序列的 finger count。
2. `onActionEnd`/`onActionCancel` 先结束 scale/pan 计算，但保留 finger ownership；最后一个 `Up` 或 `Cancel` 到达后才清消费状态。
3. drain 期间不调用 `handleTouchPadInput()`、`handleXComponentTouch()`，不触发右键、滚轮、click 和重复左键 release。
4. 对断连、surface destroy、页面消失等没有可靠尾事件的路径提供强制清理。
5. 确认 `resetTouchGesture()` 不会在 pinch end 产生重复的远端按钮状态转换。

测试：

- `Up` 的 `touches` 包含 changed finger；
- `Up` 的 `touches` 不包含 changed finger；
- 两个 finger 分两次 Up；
- 单次 Cancel；
- mouse/pen/axis/key 不被 drain；
- 新序列 Down 不被旧序列 ownership 吞掉；
- touchpad 和 direct mode 都不产生尾部 click/right-click。

建议 commit：`fix(arkts): drain pinch touch stream after gesture end`

### Step 2：双指画布平移与虚拟触控板 ownership

目标：缩放后的双指拖动可以移动画布，同时保留一指远端鼠标。

预计文件：

- `entry/src/main/ets/services/RemoteCanvasPinchInputPolicy.ets` 或新增 `RemoteCanvasGesturePolicy.ets`
- `entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- 对应 ArkTS 单元测试

实现要点：

1. 明确 `PinchGesture` 与 two-finger pan 的竞争关系；优先选择一个统一的 two-finger canvas owner，避免 PinchGesture 和 touchpad handler 各自消费同一序列。
2. 如果 API 23 的 PinchGesture 在纯平移时不能稳定触发，增加两指 PanGesture 或明确的 parallel/priority 组合，并让两者进入同一个 policy 状态机；不能用两个独立 handler 同时发送行为。
3. 双指中心移动即使 relative scale 接近 1，也必须更新 `panX/panY`；持续按内容边界 clamp。
4. 一指仍走 touchpad 相对移动或 direct absolute mouse，不因为画布已 zoom 就变成画布 pan。
5. pinch 获得 ownership 时取消尚未完成的远端左键/长按/右键候选；结束时只清理本地 gesture，不发送远端鼠标。
6. RustDesk 远端应用 TouchScale 开启时保持独立语义：远端 TouchPan 的 delta 发送到协议，不能同时再移动本地 canvas；关闭时只更新本地 canvas。

测试：

- Fit 状态双指平移不产生无意义空白；
- 200%/custom zoom 后横向、纵向、双向 pan；
- 内容小于 viewport、恰好相等、横向溢出、纵向溢出和双向溢出；
- 两指纯平移、先缩放后平移、缩放方向反转；
- touchpad mode 不发 mouse move/wheel/right-click；
- direct mode 不留下 `touchLeftDown`；
- RustDesk remote-app touch scale on/off 两种模式互斥且可恢复。

建议 commit：`fix(arkts): prioritize two-finger canvas pan over remote touchpad`

### Step 3：统一 ArkUI vp 输入坐标契约

目标：移除 vp/px 启发式，解决高密度设备和缩放后虚拟鼠标映射不准。

预计文件：

- `entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/test/RemoteSurfaceTransformPolicy.test.ets`
- `entry/src/main/ets/types/rdpnapi.d.ts` 仅在类型补充需要时修改

实现要点：

1. `mapInputPointWithTransform(localX, localY, transform)` 直接把输入视为局部 vp，删除 `localX <= surfaceWidthVp` 等猜测。
2. `surfacePointToRemote()` 统一完成 vp -> surface px -> content viewport -> remote logical 的逆变换。
3. `remotePointToSurface()` 统一完成反向投影，虚拟鼠标/箭头和触点使用同一 transform。
4. `PinchGesture.pinchCenterX/Y` 在确认官方类型契约后按同一局部 vp 处理；只有传给 canvas geometry policy 时调用 `vpToPx()`。
5. `MouseEvent`、`TouchEvent`、`AxisEvent` 的局部坐标都走同一入口；AxisEvent 的 wheel delta 仍是独立的轴值，不把轴值当坐标。
6. 协议边界输出 remote logical/display coordinates；RDP 进入 FreeRDP 前再做 UINT16 clamp，RustDesk 进入其 mouse API 前不使用 renderer pixels。

测试：

- 1x、2x、3x density 下同一 vp 触点映射到同一远端逻辑点；
- letterbox 左/右和上/下边界；
- zoom + pan 后中心、四角、viewport 外触点；
- remote cursor 正向投影与 input 逆向映射互相一致；
- 远端尺寸和 renderer source 尺寸不同；
- RDP 坐标不溢出 `UINT16`，RustDesk 坐标不使用 surface px；
- 输入事件在 surface resize/orientation 前后只读取同一代 snapshot。

建议 commit：`fix(arkts): honor HarmonyOS vp input coordinates`

### Step 4：native viewport transform generation

目标：避免旧 native viewport 覆盖刚提交的 ArkTS transform，保证静止帧和缩放后输入一致。

预计文件：

- `entry/src/main/cpp/render/gl_renderer.h`
- `entry/src/main/cpp/render/gl_renderer.cpp`
- `entry/src/main/cpp/types/librdpnapi/index.d.ts`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- `entry/src/main/ets/services/ExtensionLoader.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/cpp/test/` 下 renderer viewport/version 测试
- ArkTS viewport policy 测试

实现要点：

1. 把 `canvasTransformVersion_` 的 requested/applied 语义公开到 `RendererViewport`，或让 `setRendererCanvasTransform()` 返回可比较的 requested version。
2. `PublishViewportSnapshot()` 同时发布 `appliedTransformVersion`；seqlock 读取必须保证几何字段和版本来自同一快照。
3. ArkTS 在本地 cache 中记录 pending version；native 返回 version 小于 pending 时，只能保留本地计算的 viewport，不能覆盖它。
4. renderer handle、surface generation、source size 变化时清空旧 version，防止新 renderer 与旧 renderer 的 version 数字碰撞。
5. resize、SetSourceSize、RenderFrame、RenderRetainedFrame 都要发布同一变换语义；静止远端没有新视频帧时，transform wake 必须触发 retained redraw。
6. 加入诊断字段：requested version、applied version、last present time、viewport source、surface generation。日志采样，不能每个 pinch update 无限刷屏。

测试：

- transform 连续提交时 native 只消费最新稳定值；
- native 旧 version 返回时 JS cache 不回退；
- retained frame 在无新视频帧时使用最新 transform present；
- resize/source change 后 version 重置且输入不读旧 viewport；
- renderer destroy/recreate 后旧 wake、旧 snapshot、旧 handle 都被丢弃；
- RDP、RustDesk 硬解、RustDesk retained frame 三条渲染路径都覆盖。

建议 commit：`fix(renderer): reject stale viewport snapshots after canvas transform`

### Step 5：协议输入和视频连续性专项回归

这一阶段只有在前四个修复分别通过后才实施；如审计证明已有实现足够，则只补测试和诊断，不为了“有一个 commit”重复改协议。

核对内容：

- RDP：`handleXComponentMouse()` 映射到远端 logical x/y 后进入 RDP input queue；键盘 `onKeyEvent` 不受 finger drain 影响；FreeRDP `PTR_FLAGS_MOVE` 仍使用绝对坐标，未误切换为 relative API。
- RustDesk：本地 canvas pinch 不进入 `TouchScale`/`TouchPan`；remote-app 模式的 start/update/end 顺序正确，update 有界合并，键盘和 mouse button 是可靠边界。
- 视频：transform update 不触碰 decoder/network receive lock；静止 macOS 画面可以通过 retained redraw 更新；持续 Windows 帧不因每次 pinch update 争用 UI/EGL 锁。
- 失败路径：消息发送失败、surface detach、PIP transfer、后台恢复、断连和 session generation 变化都能释放 ownership 和按钮状态。

建议 commit（仅有实际代码缺口时）：`test(input): verify remote input survives canvas gestures`

## 6. 验证计划

### 6.1 自动化验证

每个实施步骤先运行最小相关测试；合并前完整运行：

```text
default@OhosTestCompileArkTS
ohosTest@OhosTestCompileArkTS
entry/src/main/cpp/test/ native tests
cargo test --manifest-path rustdesk_ffi/Cargo.toml
assembleHap
git diff --check
```

具体命令以仓库当前 `build-profile.json5`、Gradle task 和本地 OHOS SDK 为准；如果 SDK/网络不可用，记录失败原因和已完成的替代测试，不把未执行的真机验证写成通过。

### 6.2 真机矩阵

| 维度 | 最少覆盖 |
| --- | --- |
| RustDesk peer | Windows、macOS；静止桌面和持续动画/视频 |
| RDP peer | Windows 10/11；普通桌面和高 DPI/多分辨率 |
| local mode | touchpad、direct touch、keyboard/mouse |
| RustDesk option | remote-app TouchScale off/on |
| surface | 手机 portrait/landscape、Pad、窗口 resize、PIP、后台恢复 |
| density | 至少一个高 density 设备和一个接近 1x 的设备 |
| gesture | pure pinch、pinch+pan、zoom 后双指 pan、zoom 后一指 mouse、取消/来电/旋转中断 |

每个会话至少记录：session generation、protocol、remote logical size、renderer source size、surface vp/px、viewport、canvas transform、requested/applied transform version、last present、输入映射前后坐标、touch ownership 状态和 control queue depth。

### 6.3 通过标准

- pinch update 不发生 ArkUI 卡顿或明显丢帧；UI 线程不执行阻塞 N-API、EGL、GL、socket 或协议发送。
- macOS 静止帧在本地缩放后立即更新，视频接收/呈现统计不出现持续断流；若开启 remote-app touch scale，远端协议行为单独显示且队列有界。
- RDP 缩放前后鼠标可点击、可拖拽、可滚轮；键盘可输入组合键；没有粘住的左/右键。
- 缩放后两指 pan 能移动画布，且不能把内容拖出允许边界；一指仍能移动虚拟鼠标。
- 同一局部 vp 触点在不同 density 下映射到同一 remote logical 坐标；viewport 外不产生误发的远端点击。
- gesture end/cancel 后不会出现额外 click、right-click、wheel 或鼠标 release；下一次手势从 Idle 正常开始。

## 7. 复审、合并和回滚

实施完成后按以下顺序复审：

1. `git show --check` 和逐 commit diff：确认每个 commit 只覆盖一个步骤，未混入无关文档或格式化。
2. 代码复审：检查 ownership 是否只消费 finger，物理 mouse/axis/key 是否独立，RDP 坐标是否为 remote logical，RustDesk local canvas 是否没有误发 touch control。
3. 并发复审：确认 UI 不等待 registry/lifecycle/EGL，native viewport 版本和几何字段原子一致，surface generation 能丢弃旧事件。
4. 构建、native/Rust 测试、真机矩阵和 `git diff --check` 全通过或明确记录未完成项。
5. 从修复分支切回 `main`，执行非 squash merge；在 `main` 上复跑关键测试和 `git log --graph`，确认目标 commit 已进入 main。
6. 只有确认合并结果和工作树安全后删除修复分支；保留用户已有未跟踪文档。

若真机仍复现：

- 先按 `appliedTransformVersion`、`lastPresent`、`input mapping` 和 `control queue` 四类指标定位，区分 ArkUI gesture、renderer redraw、坐标映射和协议输入问题。
- 临时回滚优先关闭 remote-app TouchScale 或 canvas gesture zoom 作为诊断开关，不回退鼠标/键盘基础通道。
- 不用“降低 pinch 采样率”掩盖 viewport 世代、ownership 或 EGL 生命周期问题。

