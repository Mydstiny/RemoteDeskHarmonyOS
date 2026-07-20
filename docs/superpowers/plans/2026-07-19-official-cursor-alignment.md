# Phone/Pad 触控板模式官方远端鼠标对齐修复计划

- 日期：2026-07-19
- 状态：仅完成排查与计划，当前轮次不修改功能代码
- 目标设备：`38451`（`192.168.3.235:38451`）
- 适用范围：Phone/Pad 的虚拟触控板模式
- 保留范围：PC 的物理键鼠模式、现有圆环指示器、现有 `virtualMouseStyle` 持久化字段

## 1. 目标与验收定义

本任务的目标不是再增加一个装饰性的箭头，而是让 Phone/Pad 触控板模式具备与电脑远端桌面一致的远端鼠标表现：

1. “官方远端鼠标”模式显示远端协议提供的真实光标位图、hotspot、当前位置和可见性。
2. RDP 和 RustDesk 均支持箭头、白手套、等待、横向调整、纵向调整等服务端光标形状，形状切换不跳回上一种残留形状。
3. 光标位图保持原始宽高比，hotspot 与位图使用同一缩放比例，不再出现竖向或横向拉伸。
4. 控制端触控板移动、被控端自行移动、远端协议回传的位置更新，最终都进入同一套位置状态和坐标变换。
5. 触控板低速移动可以稳定停在小按钮上；快速移动仍能覆盖大范围，但不会因重复缩放或加速度突变而跳跃。
6. 圆环和官方远端鼠标是互斥显示；设置变更只影响 Phone/Pad 触控板模式，不改变 PC 物理鼠标模式。

验收时以“光标 hotspot 实际落点”作为位置标准，而不是以位图左上角或圆环中心作为标准。

## 2. 已完成的代码与官方实现排查

### 2.1 当前代码的关键问题

| 现象 | 当前实现证据 | 根因 | 修复方向 |
| --- | --- | --- | --- |
| 等待、白手套、横/纵向调整光标被拉伸 | `RemoteDesktop.ets` 的 `remoteCursorLocalScaleX()`、`remoteCursorLocalScaleY()` 分别计算宽高，并在光标 `Image` 上使用 `ImageFit.Fill` | X/Y 使用了两个独立比例，ArkUI 被要求强制填满矩形 | 计算一个统一光标比例，hotspot 使用同一比例，禁止 `Fill` |
| 控制端和被控端位置不一致 | `remoteToLocalPoint()`、`mapInputPoint()`、`remoteDeltaFromLocal()`、`toSourceSpace()` 各自重算坐标 | 远端逻辑桌面、视频 source、renderer viewport、surface 像素和 ArkUI vp 被混用 | 建立单一 `RemoteSurfaceTransform`，所有正向、逆向和增量映射共用 |
| RDP 被控端移动后控制端不跟随 | 本地已有 `cbPointerSetPosition()`，但连接设置没有显式设置 `FreeRDP_GrabMouse` | FreeRDP 官方 `pointer.c` 在 `GrabMouse == false` 时直接跳过 `SetPosition` | 连接时显式打开 `FreeRDP_GrabMouse`，并记录实际回调 |
| 默认箭头恢复后仍显示等待/调整大小形状 | `cbPointerSetDefault()` 当前只调用 `setVisible(true)` | FreeRDP 的 `SetDefault` 语义是恢复默认系统指针，不是显示上一张位图 | 存储并显示明确的默认箭头形状和 hotspot |
| 本地预测会覆盖远端真实位置 | 触控移动和 native polling 都调用 `rememberRemoteCursor()`，同时维护整数和浮点两组位置 | prediction 与 authoritative position 没有来源、代际或时间顺序 | 远端位置权威；本地移动只生成短暂 prediction，收到远端位置后替换并清除 prediction |
| RDP 尺寸可能被视频尺寸覆盖 | `startRdpNativeStateMonitor()` 将 renderer 的 `sourceWidth/sourceHeight` 传给 `updateRemoteSize()` | 视频帧尺寸不等于协议远端逻辑桌面尺寸，尤其在缩放、旋转、编码和重建时 | 分离 `remoteLogicalSize` 与 `rendererSourceSize`，禁止 source 反写逻辑桌面 |

当前 RustDesk FFI 已经具备 `cursor_position`、`cursor_data`、`cursor_id` 到 `RemoteCursorStore` 的链路，不需要重新设计 RustDesk 协议。现有 `RemoteCursorStore` 也已经把 shape revision 和 position revision 分开，后续应在其基础上补齐默认形状、权威状态合并和坐标契约。

### 2.2 官方 RustDesk 对照结论

已核对临时官方源码 `C:\tmp\rustdesk-official`，commit `0f3a03aab7358357ac7979a9460a35e32dfff97f`：

- `flutter/lib/models/model.dart` 的 `CursorModel.updateCursorPosition()` 收到 `cursor_position` 后直接替换 `_x/_y` 并通知界面；当前位置不是由光标位图的 hotspot 推导出来的。
- `cursor_data`、`cursor_id`、`cursor_position` 是独立事件，形状缓存和当前位置更新不能合并成一条“收到形状才更新位置”的链路。
- `CursorData` 注册系统自定义鼠标时，位图宽高使用同一个 scale，hotspot 也用该 scale 缩放。
- `flutter/lib/native/custom_cursor.dart` 注册自定义 cursor 时传递真实宽高和 hotspot，不把任意位图拉伸到一个固定矩形。
- `src/flutter.rs` 将 host 的 `cursor_position` 作为独立事件发送给 UI。

### 2.3 官方 FreeRDP 对照结论

已核对子模块 `freerdp`，commit `dae8276ac7361b8d14f7b87d41163fe03dbb944e`：

- `include/freerdp/graphics.h` 中 `rdpPointer.xPos/yPos` 是光标 hotspot；`POINTER_POSITION_UPDATE.xPos/yPos` 是当前远端光标位置，二者不是同一个字段。
- `libfreerdp/cache/pointer.c` 的 `update_pointer_position()` 先检查 `FreeRDP_GrabMouse`，关闭时不会调用客户端的 `SetPosition`。
- `pointer.c` 将系统指针分成 `SetNull`、`SetDefault` 和自定义 `Set` 三种语义，不能用 `SetDefault` 仅切换可见性代替。
- `libfreerdp/core/update.c` 解析远端 position、system pointer 和 pointer shape 时，位置、形状、hotspot 都是独立数据。

## 3. 总体设计

### 3.1 统一坐标空间

建立一个会随 renderer viewport 变化而更新的只读变换快照，建议命名为 `RemoteSurfaceTransform`，至少包含：

```text
remoteLogicalWidth / remoteLogicalHeight   远端协议的逻辑桌面或当前显示器坐标
rendererSourceWidth / rendererSourceHeight  视频帧或 renderer source 尺寸，仅用于渲染几何
viewportPxX / viewportPxY / viewportPxW / viewportPxH  contain 后的实际内容视口
surfacePxWidth / surfacePxHeight            XComponent surface 像素尺寸
surfaceVpWidth / surfaceVpHeight            ArkUI 输入事件使用的 vp 尺寸
revision                                    变换代际
```

唯一变换链为：

```text
远端逻辑坐标
  → renderer 内容 viewport 像素
  → XComponent surface 像素
  → ArkUI vp
```

所有下列操作必须调用同一套变换函数，不再各自重算比例：

- 远端位置 → 光标 hotspot 的 ArkUI 位置；
- 触控点 → 远端绝对坐标；
- 触控 delta → 远端逻辑 delta；
- 光标形状尺寸和 hotspot → 屏幕显示尺寸；
- 点击、拖拽、滚轮发送前的坐标编码。

实现要求：

1. `remoteToLocalPoint()` 和 `mapInputPoint()` 互为逆变换；在非整数缩放下保留浮点中间值，最后一步才按协议要求取整。
2. letterbox 黑边不属于远端桌面。触控点落在黑边时不发新的移动；释放事件仍按现有按钮清理规则处理。
3. `remoteDeltaFromLocal()` 不再重复执行 surface/source/remote 比例乘法，而是使用同一变换的局部逆导数；不可从 `remoteToLocalPoint()` 之外再维护第二套缩放公式。
4. `toSourceSpace()` 不再作为所有协议通用的输入转换。它要么删除，要么拆成明确的协议边界编码函数：RDP 使用 RDP 当前桌面输入坐标，RustDesk 使用 RustDesk 当前显示器/远端输入坐标；renderer source 只在确实是协议输入坐标时才参与一次映射。
5. RDP native state monitor 只能更新 renderer source 或独立的 graphics metrics，不能用 `sourceWidth/sourceHeight` 覆盖 `remoteLogicalWidth/remoteLogicalHeight`。
6. 每次连接、远端 resize、横竖屏切换、surface 重建和 viewport 变化都递增 `revision`；光标保留远端逻辑位置，再通过新变换重新投影。

### 3.2 统一光标渲染状态

在 ArkTS 侧将分散的 `remoteCursorX/Y`、`remoteCursorPreciseX/Y`、shape 字段和可见性字段收敛为一个明确的 `RemoteCursorRenderState`。建议字段如下：

```text
sessionId
protocol                         rdp / rustdesk
authoritativePosition            远端协议最近一次确认的 x/y
prediction                       可选的本地短暂预测 x/y、序号、创建时间
shapeId / pixelMap / width / height / hotX / hotY
visible
shapeRevision / positionRevision
transformRevision
generation                       连接代际，防止旧连接事件污染新连接
```

状态规则：

- 远端协议 position 是权威状态；收到 native position 时直接替换 `authoritativePosition`，清除旧 prediction，并触发一次 UI 更新。
- 触控板移动只更新 prediction 和待发送事件，不把 prediction 写成不可区分的“远端已确认位置”。如果当前网络没有回传位置，则 prediction 作为短时显示兜底，但必须带代际和超时。
- native polling 一次读取同一份 snapshot，并按 shape/position/visibility revision 原子应用，不能用旧 shape snapshot 覆盖新 position。
- 连接初始化时只在没有远端 position 的情况下把光标放在远端桌面中心；收到第一个远端 position 后不再被初始化中心覆盖。
- disconnect、重连、sessionId 变化时清除 prediction、PixelMap、shape 和可见性，旧回调必须被 generation 丢弃。
- 取消使用 `remoteCursorViewRevision * 0` 触发刷新；改为让 `RemoteCursorRenderState` 或明确的 revision 字段成为 ArkUI 的响应式输入。

数据流固定为：

```text
RDP/RustDesk 回调
  → RemoteCursorStore（shape / position / visibility）
  → session snapshot
  → authoritative RemoteCursorRenderState
  → RemoteSurfaceTransform
  → 光标 hotspot 和位图渲染

触控 delta
  → RemoteSurfaceTransform 逆变换
  → 触控板加速度曲线
  → prediction + protocol input
  → 远端 position 回调再次成为权威状态
```

## 4. RDP 光标生命周期修复

修改范围主要是 `entry/src/main/cpp/rdp/freerdp_adapter.cpp`、对应头文件、`entry/src/main/cpp/input/remote_cursor_snapshot.*` 和 native 测试。

### 4.1 连接设置

在创建 RDP session、设置桌面尺寸的同一处显式设置：

```cpp
freerdp_settings_set_bool(settings, FreeRDP_GrabMouse, TRUE);
```

并在连接诊断中记录最终值。启用该设置的目的，是允许 FreeRDP 按官方路径将 `POINTER_POSITION_UPDATE` 送到 `cbPointerSetPosition()`；是否显示由 Phone/Pad 的样式和控制模式决定，PC 物理键鼠模式仍不叠加虚拟光标。

### 4.2 回调语义

- `cbPointerNew()`：只负责校验、解码和准备形状数据；保留远端提供的宽高和 hotspot。
- `cbPointerSet()`：更新 shape、hotspot 和 shape revision，并显示该形状；不能写入当前远端 position。
- `cbPointerSetPosition()`：只更新当前远端 position 和 position revision；不能修改 shape 或 hotspot。
- `cbPointerSetNull()`：只设置不可见；不能清掉上一张合法 shape，便于后续恢复。
- `cbPointerSetDefault()`：恢复一个稳定的默认箭头形状和默认 hotspot，再设置可见；不能只调用 `setVisible(true)` 继续显示等待或调整大小位图。
- 连接结束和清理时隐藏并重置 session generation。

默认箭头应使用稳定的内置 RGBA 资源或明确生成的默认形状，尺寸、hotspot 和 PixelMap 生命周期要覆盖多次 `SetDefault`，不能每次回调泄漏或与上一张 PixelMap 竞争释放。

### 4.3 诊断日志

增加低频、可关闭的光标诊断，至少记录：

```text
session / generation / callback kind / shapeId
shape width×height / hotX,hotY / position x,y / visible
remoteLogicalSize / rendererSourceSize / viewport
```

日志要能区分“服务端没有发送 position”“FreeRDP 被 GrabMouse 门控”“回调已到达但 ArkTS 未应用”“应用了错误坐标空间”四种情况。

## 5. RustDesk 光标生命周期修复

修改范围主要是 `rustdesk_ffi/src/cursor_state.rs`、`rustdesk_ffi/src/connector.rs`、`rustdesk_ffi/src/lib.rs`、`entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp` 及 `remote_cursor_snapshot.*`。

现有链路保留：

```text
cursor_position / cursor_data / cursor_id
  → CursorState
  → CursorStreamUpdate
  → FfiCursorUpdate
  → onFfiCursor
  → RemoteCursorStore
  → ArkTS 16ms polling
```

需要补强的规则：

1. `cursor_position` 无论当前是否已有 shape，都必须更新 position；不能等待 `cursor_data` 或 `cursor_id`。
2. `cursor_data` 只更新位图、尺寸和原始 hotspot；`cursor_id` 只选择缓存 shape；两者都不能重置当前位置。
3. 事件顺序反转、重复事件和 position 先到时，revision 仍要单调且状态可恢复。
4. `Visibility(false)` 只影响可见性，不破坏最后一张合法 shape；重新收到 shape/id/default 后按协议重新显示。
5. FFI callback 中的 RGBA 生命周期继续只在 callback 内有效，native store 必须复制；ArkTS PixelMap 只在替换和 session 清理时释放。
6. 不为消除跳变而把 RustDesk 光标固定成箭头，必须保留远端真实 shape。

## 6. 官方光标的等比显示与 hotspot 对齐

修改范围主要是 `entry/src/main/ets/pages/RemoteDesktop.ets`，必要时新增光标几何 policy 文件。

### 6.1 尺寸算法

1. 从同一份 `RemoteSurfaceTransform` 得到远端单位到 ArkUI 的显示比例。
2. 使用单一 `cursorScale`；在正常 contain 视口中 X/Y 应相等。若由于异常 source/remote 宽高比出现两个比例，记录诊断并使用较小比例作为安全 fallback，绝不把 shape 拉伸到两个独立尺寸。
3. `displayWidth = sourceWidth * cursorScale`、`displayHeight = sourceHeight * cursorScale`，尺寸计算保持原始宽高比。
4. `displayHotX = hotX * cursorScale`、`displayHotY = hotY * cursorScale`，hotspot 与位图不可使用不同 scale。
5. `Image` 禁止 `ImageFit.Fill`；使用保持原始比例的 fit 策略或按等比后的实际尺寸渲染，并确保 Image 容器不再二次拉伸。
6. 光标位图左上角为 `hotspotLocal - displayHotspot`，hotspot 正好落在远端逻辑 position 的投影点。

### 6.2 形状切换

形状切换必须遵循：

```text
shape event → 更新 PixelMap/尺寸/hotspot → 保持当前位置 → 同一 transform 重绘
position event → 只移动 hotspot → 保持当前 shape
default/null/visibility event → 只按生命周期规则切换形状或可见性
```

这样可以避免箭头、白手套、等待、横向调整、纵向调整之间因为旧状态残留而来回跳变。

## 7. Phone/Pad 虚拟触控板映射曲线

### 7.1 先校正几何，再调加速度

当前 `TouchpadPointerCurvePolicy.ets` 已有速度平滑和 gain，但移动路径还会叠加 `remoteDeltaFromLocal()` 的坐标换算，且不同入口可能使用不同的状态。实现顺序必须是：

1. 先关闭加速度进行 1:1 几何验证：同一个触控 delta 经过 transform 逆变换后，远端逻辑坐标增量与正向投影可逆。
2. 确认没有重复乘 surface、render、source、remote 比例后，再启用速度曲线。
3. 最终有效 gain 只能有一个组合点：坐标比例 × 曲线 gain × 用户速度倍率，不能在多个 helper 中隐式重复相乘。

### 7.2 建议的初始曲线与调参原则

保留“低速精度、快速覆盖”的目标，但将以下作为可测量的初始候选，不直接把当前常量视为最终答案：

- 低速精度区：gain 约 `0.65–0.80`，不设置会吞掉小移动的 deadzone；保留浮点累计，避免每个事件都 round 后失去 1 像素以内的移动。
- 正常速度区：gain 约 `1.0`，保证手指移动与远端位置变化具有可预测关系。
- 快速区：gain 逐渐提升到约 `1.5–1.8`，使用平滑曲线，不允许一次事件突然跳变。
- 用户速度倍率继续沿用已有设置，但与曲线合并后必须有上限，避免极快滑动直接越过目标。
- 用速度（远端无关的本地 vp delta / 时间）计算曲线，不用已经乘过远端比例的 delta 再次计算速度。

### 7.3 手势和权威位置规则

- `Down`、`Up`、`Cancel`、连接/重连和横竖屏切换时重置曲线状态。
- 手势开始时以最近一次 authoritative position 为基准；若暂时没有位置回传，才使用带序号的 prediction。
- 每个 move 先将本地 vp delta 通过统一 transform 转成远端逻辑 delta，再应用曲线，再更新浮点 prediction，最后按协议要求取整发送。
- 收到远端 position 时停止旧 prediction；不能让晚到的本地 timer 或 queue flush 把光标写回旧位置。
- 触控板移动、虚拟鼠标按钮、虚拟摇杆若共用指针位置，必须共用同一 position/transform helper；按钮按下和释放只使用当前权威/预测合并位置，不重新用浮动控件位置映射。

## 8. 设置与模式边界

当前 `HostListPage.ets` 已存在“个性化 → 虚拟鼠标样式”，字段为 `virtualMouseStyle`，值为 `circle` / `arrow`，不重复新增设置字段。

计划调整：

1. 保留旧值和持久化兼容；未知值继续归一化为 `arrow`。
2. 将 `arrow` 文案明确为“官方远端鼠标（RustDesk / FreeRDP）”，副文案明确“仅 Phone/Pad 触控板模式”。
3. `circle` 继续显示触控环；`arrow` 只显示远端 native cursor。两者不可同时渲染。
4. `RemotePointerModePolicy` 的系统鼠标行为保持不变：物理键鼠模式仍交给系统 pointer，不受这个设置干扰。
5. 设置切换时立即刷新渲染状态，不重置远端 position、shape 或触控板曲线；断开连接后不遗留 PixelMap。

## 9. 计划修改的文件范围

实现阶段只修改与本任务直接相关的文件，其他 session 当前未提交的文件保持原样。

### ArkTS/UI/policy

- `entry/src/main/ets/pages/RemoteDesktop.ets`
  - 统一 transform、cursor render state、prediction 合并、光标 overlay、触控板输入和 RDP source 尺寸处理。
- `entry/src/main/ets/services/TouchpadPointerCurvePolicy.ets`
  - 校正曲线输入、低速精度、速度倍率合并和边界。
- `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`
  - 保留 `circle`/`arrow` 兼容逻辑，补充互斥和模式边界测试。
- `entry/src/main/ets/pages/HostListPage.ets`
  - 只更新已有设置文案和必要的刷新行为。
- `entry/src/main/ets/types/rdpnapi.d.ts`
  - 如实现需要，补充 transform/source/display 元数据；字段必须与 NAPI 结构同步。
- 建议新增 `entry/src/main/ets/services/RemoteCursorTransformPolicy.ets`，把纯坐标函数从页面中抽出，便于单元测试。

### Native/RDP/RustDesk

- `entry/src/main/cpp/rdp/freerdp_adapter.cpp/.h`
  - 显式 `FreeRDP_GrabMouse`、pointer callbacks、默认箭头、诊断日志和协议坐标契约。
- `entry/src/main/cpp/input/remote_cursor_snapshot.cpp/.h`
  - 必要时补充 default shape、generation 或 visibility 语义；保持 shape/position revision 分离。
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
  - 只有在需要向 ArkTS 暴露新的统一 transform/cursor 元数据时才修改。
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`
  - FFI cursor callback、session generation、shape/position/visibility 合并。
- `rustdesk_ffi/src/cursor_state.rs`
  - RustDesk cursor event 顺序、缓存、hotspot 和 revision 语义。
- `rustdesk_ffi/src/connector.rs`、`rustdesk_ffi/src/lib.rs`
  - 只在需要修正现有 cursor event 派发或测试时修改，不重写已有协议链路。

### 测试

- `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`
- 新增/扩展 `RemoteCursorTransformPolicy.test.ets`、`TouchpadPointerCurvePolicy.test.ets`、`RemoteCursorStylePolicy.test.ets`
- Rust cursor state 的现有测试位置及必要的 connector/FFI 回调测试

## 10. 测试与验证计划

### 10.1 纯函数和状态测试

必须覆盖：

1. transform identity、contain、横屏、竖屏、letterbox、边界和逆变换 round-trip。
2. `remoteToLocalPoint(mapInputPoint(p))` 在有效内容区域内误差不超过一个最终取整单位。
3. source 尺寸变化不会改变 remote logical position；viewport 变化只改变投影。
4. 光标所有 shape 的原始宽高比保持不变；X/Y scale 不再独立；hotspot 和位图使用同一 scale。
5. shape → position、position → shape、null → default、default → custom、disconnect → reset 的状态转移。
6. 重复 shape/position 不产生无意义 revision；旧 session/generation 事件不污染新 session。
7. prediction 在本地移动时可用，收到 authoritative position 后被清除且不会被旧 timer 恢复。
8. 触控板曲线对速度单调、连续、有上下限；低速小 delta 不被 deadzone 吞掉；快速移动不瞬移。
9. RDP `GrabMouse` 设置值可读；`SetPosition`、`SetNull`、`SetDefault` 的行为分别只影响对应字段。
10. RustDesk `cursor_position` 在没有 shape、shape 先到、position 先到、重复事件和 visibility 变化下都能恢复。

### 10.2 工程验证

按项目规则执行：

1. native 定向测试（包含 `remote_cursor_snapshot_test` 和 RDP input 相关测试）。
2. RustDesk FFI 定向测试，覆盖 `cursor_state` 和 connector cursor event。
3. `default@OhosTestCompileArkTS`。
4. 生产 `assembleHap`。
5. `git diff --check`。
6. Light 开源合规门。

本任务不计划修改依赖、proto、gitlink 或许可证文件；若实现过程中确实发生依赖或协议变更，必须同步 SBOM、NOTICE、provenance 和哈希，不能只提交功能代码。

### 10.3 38451 真机验收矩阵

在同一设备、同一显示比例下分别验证 RDP 和 RustDesk：

| 场景 | 验收内容 |
| --- | --- |
| 设置 | 圆环/官方远端鼠标切换立即生效，重启后值保持，未知旧值兼容 |
| 普通箭头 | hotspot 对准箭尖，位置和点击目标一致 |
| 白手套 | 位图不横向或纵向拉伸，hotspot 落在手指尖/服务端定义点 |
| 等待 | 位图保持圆形/原始比例，形状切换不残留上一种光标 |
| 横向调整 | 横向指示不被压成竖向，hotspot 对齐边界中心 |
| 纵向调整 | 纵向指示不被拉成横向，hotspot 对齐边界中心 |
| 其他系统形状 | 服务器切换到默认、禁止、文本或自定义光标时生命周期正确 |
| 被控端自行移动 | 被控端物理鼠标移动后，控制端官方光标在一个 polling 周期/可接受网络延迟内跟随 |
| 小按钮 | 慢速靠近、停留、微调和点击不抖动、不越过目标；重复测试同一轨迹结果稳定 |
| 速度曲线 | 慢速可控、常速可预测、快速可覆盖大范围；没有突然跳跃或边界溢出 |
| 输入闭环 | 控制端移动后被控端位置变化；被控端移动后控制端指示变化；两者不互相写回旧位置 |
| letterbox | 黑边不被当作远端桌面，内容区四角映射正确 |
| 横竖屏/resize | 光标保持远端逻辑位置，投影随新 viewport 更新，不拉伸、不跳到中心 |
| 断开/重连 | 旧光标隐藏，旧 PixelMap 和 position 不污染新会话 |
| 圆环互斥 | 圆环模式不出现位图，官方模式不出现圆环/等待输入装饰替代物 |
| PC 模式回归 | 物理键鼠仍使用系统 pointer，Phone/Pad 设置不产生额外 overlay |

截图和日志至少记录：设备尺寸、remote logical size、source size、viewport、cursor shape size/hotspot、authoritative position、prediction 是否存在、transform revision 和协议类型。验收时重点对比 38451 上的“白手套、正常鼠标、竖向指示框、横向拉伸指示框”四类用户已观察到的跳变场景。

## 11. 实施顺序与阶段退出条件

### 阶段 A：坐标契约和纯函数

- 抽出 transform policy，补齐 transform/curve 单元测试。
- 暂不改变默认设置文案。
- 退出条件：1:1、contain、letterbox、resize 和逆变换测试通过。

### 阶段 B：native 光标生命周期

- 打通 RDP `GrabMouse`、RDP default/null/position 语义。
- 固化 RustDesk shape/position/visibility/generation 合并。
- 退出条件：native/Rust FFI 测试通过，日志能区分 shape、position、visibility 三类事件。

### 阶段 C：ArkTS 权威状态和等比渲染

- 替换页面中的双重缩放、`ImageFit.Fill` 和混合状态。
- 接入统一 transform 和 hotspot 定位。
- 退出条件：本地渲染测试和 HAP 构建通过，四类拉伸光标截图不再变形。

### 阶段 D：触控板曲线与闭环

- 先以 1:1 几何验证，再启用候选加速度曲线。
- 接入 prediction/authoritative reconcile，清理旧 timer/queue 覆盖。
- 退出条件：小按钮轨迹、远端自行移动回传、点击/拖拽/滚轮测试通过。

### 阶段 E：设置文案和真机回归

- 更新已有设置的官方命名与范围说明。
- 完成 38451 的 RDP/RustDesk、横竖屏、letterbox、断线重连和 PC 模式回归。
- 退出条件：工程验证全部通过，真机矩阵无阻塞项后再进入 commit/PR 流程。

## 12. 风险与明确不做的事情

- 不把 RustDesk/RDP 的远端光标强制固定成一个箭头；官方模式必须尊重服务端真实形状。
- 不把 hotspot 当成当前位置，也不把远端当前位置写入光标位图偏移。
- 不把 renderer source 尺寸当成所有协议的远端逻辑桌面尺寸。
- 不在当前轮次直接修改功能代码、现有 session 未提交文件或截图临时文件。
- 不修改 PC 物理鼠标交互，不借助系统 pointer 去伪装 Phone/Pad 的远端协议光标。
- 不通过继续叠加速度常量掩盖坐标变换错误；曲线调参必须建立在几何变换测试通过之后。
- 如果 FreeRDP 服务端不发送位置更新，日志和验收必须明确标记为服务端/协议能力问题，不能用本地 prediction 永久冒充双向同步。
