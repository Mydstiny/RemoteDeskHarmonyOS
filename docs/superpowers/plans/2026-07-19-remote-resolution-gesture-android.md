# 远程分辨率、画布双指缩放与 RustDesk 安卓竖屏修复计划

> 状态：已合并。本文是对 `docs/REMOTE_RESOLUTION_SCALE_PLAN.md` 的审查留档；审批通过后，内容已并入总计划 v2.1。后续执行以总计划为准。
>
> 目标：完成双指“整个画布缩放”与滚动/平移的设计审查，单独评估“远端应用内部缩放”，并定位 RustDesk 控制安卓端不能正常竖屏显示的原因与修复路径。

## 1. 结论先行

本次新增需求必须拆成四个互不替代的能力：

| 能力 | 作用对象 | 是否改变远端窗口/分辨率 | 当前结论 |
| --- | --- | --- | --- |
| 远端分辨率 | RDP/RustDesk 远端桌面输出 | 会改变远端输出尺寸或显示器模式 | 继续沿用上一份计划；RDP 当前四档链路正常，RustDesk 尚未真正接通 |
| 设置中的缩放 | 本地客户端的持久化显示比例 | 不改变远端 | 当前只有状态/提示，渲染器仍固定 `contain/letterbox`，尚未真正生效 |
| 双指画布缩放 | 本地远端画布的运行时变换 | 不改变远端窗口或远端应用 | 当前不存在；现有双指手势被右键/滚轮/直接触控逻辑占用 |
| 远端应用内部缩放 | 远端 Android 应用收到的多指触控 | 远端窗口大小与采集分辨率保持不变 | 当前不可用；RustDesk 协议、FFI、安卓服务端和注入端均有缺口 |

结论如下：

1. “被控端窗口溢出屏幕需要滚动”属于本地画布的 `zoom + pan`，不能用 ArkUI 外层滚动容器简单替代，否则容易破坏 XComponent/native surface 和坐标映射。
2. “被控端内的可缩放软件窗口缩放、被控端窗口大小不变”不是本地画布缩放。它必须向远端发送真实的 pinch/touch-scale 事件；本地画布应保持原变换。RustDesk Android 当前没有完整接收链路，不能把现有 `send_touch_scale` 当作已经支持。
3. RDP 当前适配器只抽象了键盘、鼠标和滚轮输入，没有通用多点触控/触摸缩放入口。RDP 第一阶段应保证本地画布缩放；远端应用缩放需另行验证 FreeRDP 触控扩展或明确的应用级 `Ctrl+wheel` 兼容策略，不能承诺对所有 Windows 软件通用。
4. RustDesk 安卓竖屏问题最可疑的链路是：FFI 在连接开始时只读取一次 `PeerInfo` 显示尺寸，并把这一对宽高盖到所有后续视频帧；同时安卓采集端根据 orientation 重排宽高、只比较 width 是否变化，且没有旋转元数据。控制端强制横屏会放大症状，但不是远端屏幕旋转的修复机制。

## 2. 现状审查依据

### 2.1 画布与手势

- `entry/src/main/ets/pages/RemoteDesktop.ets:269` 保存 `rustdeskViewScaleMode`，`setRustDeskViewScaleMode()` 只接受 `original/custom/fit`，持久化字符串并显示 Toast；没有 renderer viewport、纹理变换或 pan 状态消费它。
- `entry/src/main/ets/pages/RemoteDesktop.ets:4998–5334` 当前将双指用于 RustDesk touchpad 的右键/滚轮，直接触控模式也有双指右键逻辑，三指用于控制面板。新增 pinch 必须先解决手势仲裁，否则会同时发远端输入和改变画布。
- `entry/src/main/ets/pages/RemoteDesktop.ets:5535–5628` 同时存在 XComponent `onTouch` 与透明 ArkTS overlay 兜底。双指识别必须确定唯一事件所有者，避免 native 与 ArkTS 双重转发。
- `entry/src/main/ets/pages/RemoteDesktop.ets:2061–2158` 的 `mapInputPoint()`/`remoteToLocalPoint()`只根据当前 `contain/letterbox` viewport 做正反映射，没有 pan/运行时 zoom。
- `entry/src/main/cpp/render/gl_renderer.cpp:745–752`、`:839–846` 只计算等比 contain viewport；没有裁剪、滚动、聚焦点缩放或运行时变换接口。

### 2.2 RustDesk 远端应用缩放

- 上游协议在 `rustdesk_vendor/libs/hbb_common/protos/message.proto:155–184` 定义 `TouchScaleUpdate`、`TouchPanStart/Update/End`。缩放字段是相对上一帧的增量，`scale * 1000`，`0` 表示结束。
- 上游客户端在 `rustdesk_vendor/flutter/lib/common/widgets/remote_input.dart:460–500` 已区分平台：桌面 peer 发送远端 scale 事件，移动 peer 做本地 canvas scale。这正好证明两个需求不能共用一个状态。
- `rustdesk_vendor/src/ui_session_interface.rs:1146–1155` 和 `rustdesk_vendor/src/flutter.rs:1870–1926` 有发送 scale 的 RustDesk 内部接口，但 `rustdesk_ffi/src/lib.rs:284–310` 的 `ControlMsg`、`rustdesk_ffi/src/connector.rs:1253–1314` 的序列化、`entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp:25–48` 的 C FFI 均未接入 scale。
- RustDesk 服务端对 Android 的处理在 `rustdesk_vendor/src/server/connection.rs:2741–2765` 只转发 pan 事件；`ScaleUpdate` 落入忽略分支。`rustdesk_vendor/src/server/input_service.rs:1022–1027` 只在 Windows 下执行 `handle_scale()`。
- 安卓端 `rustdesk_vendor/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/InputService.kt:52–57` 虽然声明了 `TOUCH_SCALE_START/TOUCH_SCALE/TOUCH_SCALE_END`，但 `onTouchInput():215–235` 只实现了 pan。当前链路即使补齐 HarmonyOS FFI，也不能让 Android 应用真正收到 pinch。

### 2.3 RustDesk 安卓竖屏

- 控制端 `entry/src/main/ets/pages/RemoteDesktop.ets:1456`、`:3067`、`:3140–3158` 将**本地控制窗口**设置为 `LANDSCAPE`；这不等于远端 Android 屏幕应当横向渲染。
- `rustdesk_ffi/src/lib.rs:214–224` 的 `FfiVideoFrame` 虽带 width/height，但没有 display、rotation、scale、geometry epoch 等字段。
- `rustdesk_ffi/src/lib.rs:820–845` 在 `run_streaming()` 启动前只调用一次 `peer_display_size()`；`:385–394`、`:401–424` 把同一对宽高盖到所有编码帧。它不能表达安卓旋转后的实际帧尺寸，也不能处理 PeerInfo 延迟更新。
- `rustdesk_ffi/src/connector.rs:2004–2059` 只读取 `PeerInfo.displays[current_display].width/height`，协议 `DisplayInfo` 没有 rotation 字段；`VideoFrame` 只有 display index，没有帧宽高/旋转字段。
- 安卓 `rustdesk_vendor/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt:258–310` 从 `maximumWindowMetrics`/`DisplayMetrics` 取尺寸后，用 `resources.configuration.orientation` 再按 max/min 重排；所有非 landscape 值都按 portrait 处理，并且只在 `SCREEN_INFO.width` 改变时刷新采集。
- 安卓 `MainService.kt:350–379` 的 raw `ImageReader` 只转发 `planes[0].buffer`，没有携带 pixel stride/row stride。若设备存在行填充，可能造成裁剪、错位等看似旋转错误的画面。

## 3. 功能边界与验收语义

### 3.1 设置缩放与双指缩放的分离

设置缩放是持久化的显示基线，例如 `Fit`、100%、125%、150%、175%、200% 或自定义比例；双指缩放是会话内的临时交互变换。推荐的合成关系为：

```text
最终画布比例 = 设置基线比例 × 双指手势比例
最终画布平移 = 会话内 panX / panY
```

双指手势结束后是否保留当前比例应作为独立策略，推荐默认保留到当前连接结束，重新连接或点击“适应窗口”时清零；不写回设置中的自定义比例，避免一次手势污染全局偏好。

### 3.2 场景一：远端画布溢出客户端屏幕

当远端源尺寸乘以最终画布比例大于 viewport：

- 保持远端画面的宽高比，不拉伸、不改变远端分辨率。
- 以双指中心点为锚点调整比例，使锚点下的远端内容尽量保持不跳动。
- 以双指中心移动作为 pan；必要时可追加鼠标中键拖动、触控板拖动或滚动条，但首版优先采用渲染器级 pan。
- 将 pan 限制在内容边界，除已有 letterbox 外不产生不可控空白；viewport 变窄/变宽时重新 clamp。
- 所有远端输入、远端光标、光标形状和覆盖层必须使用同一个 `RemoteVideoGeometry + CanvasTransform` 正逆变换。

推荐的坐标关系是：本地触点先减去 viewport/origin 与 pan，再除以最终比例，得到远端源坐标；远端光标则按相反顺序投影回本地。远端源旋转时先做旋转逆变换，再进入输入坐标空间。

### 3.3 场景二：远端应用内部缩放

该模式的验收条件是：

- 远端应用内容发生缩放，例如 Android 上的浏览器、图片、地图或文档内容变化。
- 远端系统窗口边界、远端显示分辨率、采集帧的几何尺寸保持不变；控制端画布比例不跟着改变。
- 缩放中心、缩放开始/更新/结束顺序以及输入坐标都可追踪。
- 远端不支持时必须明确降级为“只缩放本地画布”，不能静默吞掉手势后让用户误以为远端应用已缩放。

推荐在会话控制条提供明确的“双指目标”：

- `画布`：默认，双指只改变本地 `CanvasTransform`。
- `远端应用`：只在检测到 RustDesk Android touch-scale 能力后显示；双指只发送远端触控事件，本地画布保持不变。

不推荐根据每次手指移动自动猜测目标。因为“放大远端画布”和“放大远端应用”视觉上相似，但协议副作用完全不同。

## 4. 目标数据模型与状态机

### 4.1 统一几何模型

后续实现应建立协议无关的远端视频几何对象，至少包含：

```text
RemoteVideoGeometry
  displayIndex
  pixelWidth / pixelHeight       // 当前实际渲染帧或解码输出尺寸
  logicalWidth / logicalHeight   // 远端输入坐标空间
  rotation                       // 0/90/180/270 或明确的 unknown
  inputScale                     // Android half-scale 等逻辑到物理换算
  geometryEpoch                  // 每次显示/旋转/采集几何变化递增
  sourceKind                     // RDP / RustDesk / raw / decoded

CanvasTransform
  baseScaleMode                  // Fit / Original / Preset / Custom
  baseScale
  gestureScale
  panX / panY
  focalPoint
  viewportX / viewportY / viewportW / viewportH

PinchTarget
  Canvas
  RemoteApplication
```

`pixelWidth/height` 不能继续无条件使用连接建立时读取的一次性 PeerInfo 尺寸；输入坐标空间与实际像素空间可以不同，但必须显式记录，不允许用隐式的宽高交换代替 rotation。

### 4.2 双指手势状态机

建议状态为：

1. `Idle`：单指/鼠标继续走既有远端输入。
2. `TwoFingerCandidate`：第二根手指落下，暂不发送右键、滚轮或远端 touch-scale，等待最小移动/距离变化阈值。
3. `CanvasTransform`：按距离变化更新 `gestureScale`，按中心点变化更新 pan；本状态不向远端发送鼠标/触控。
4. `RemoteTouchScale`：目标为远端应用且能力已确认，发送 start/update/end；本地画布 transform 不变。
5. `Cancel`：手指抬起、三指控制面板接管、surface 销毁、连接断开或方向 epoch 变化时清理未完成状态。

现有 touchpad 双指右键/滚轮与新功能冲突，必须有明确策略。推荐在移动触控场景中将双指保留给画布/远端应用目标；原双指右键/滚轮移到显式控制模式或桌面触控板模式。三指控制面板保留，但第二根手指已进入 pinch 后不得误触发三指面板。

XComponent 与 overlay 只能有一个手势 owner；若 ArkTS 事件和 native 事件都可能到达，必须用 session gesture id、消费标记和测试日志证明不会重复发送。

## 5. RustDesk 安卓竖屏的诊断与修复方案

### 5.1 根因优先级

| 优先级 | 候选根因 | 判断 |
| --- | --- | --- |
| 高 | FFI 一次性 `peer_display_size()` 覆盖所有帧，没有实际帧几何/rotation | 最强的控制端缺陷候选；尤其影响连接后旋转和 PeerInfo 延迟更新 |
| 高 | Android 端 max/min 重排与系统 orientation 重复或错误应用 | 可能导致 portrait/landscape 宽高反转；所有非 landscape 都被当作 portrait |
| 高 | `SCREEN_INFO.width` 单字段判断 | height、half-scale、dpi 变化时不重建采集，方向切换可能留下旧几何 |
| 中 | 控制端强制本地窗口横屏 | 不一定改变帧，但会掩盖远端 portrait 的正确比例和用户预期 |
| 中 | ImageReader 行步长未传递 | 可能造成裁剪、错位、条纹，需用 pixelStride/rowStride 实测确认 |
| 待验证 | Android 服务是否在所有设备/版本收到 `onConfigurationChanged` | 若没有，采集几何不会及时更新 |

### 5.2 必做诊断探针

在实现修复前，先建立同一时间轴的日志和截图：

- Android endpoint：系统 configuration orientation、display rotation、原始 WindowMetrics bounds、归一化前后宽高、half-scale、dpi、`SCREEN_INFO`、VirtualDisplay 尺寸、ImageReader width/height/pixelStride/rowStride、每次 stop/start 原因。
- RustDesk FFI：PeerInfo displays/current_display、连接时采集的 remote width/height、每个 geometry epoch、FfiVideoFrame width/height/display/rotation（新增字段前先记录现有可得值）。
- native decoder/renderer：编码帧输入尺寸、解码输出尺寸、纹理尺寸、surface 尺寸、contain viewport、最终 source width/height。
- ArkTS：`remoteWidth/remoteHeight`、renderer viewport、当前 `CanvasTransform`、输入点映射前后坐标、方向变化时序。

最小复现矩阵：

1. 连接前安卓竖屏、连接前横屏各一次。
2. 连接后从 portrait 转 landscape，再转 reverse portrait；观察是否收到新 geometry epoch。
3. raw capture 与实际使用的编码路径各一次。
4. half-scale 开关变化一次；验证 width、height、scale、dpi 都变化时是否重建。
5. 对照截图：若 PeerInfo、FFI、decoder 都是 portrait 而画面仍横向，转向 renderer/surface；若 FFI 已横向而 PeerInfo 仍 portrait，先修几何合同；若方向切换无新帧尺寸，先修 endpoint/FFI 更新。

### 5.3 修复顺序

1. **统一帧几何合同**：将实际编码/解码尺寸作为渲染像素尺寸；PeerInfo 只作为逻辑显示和输入坐标的初始来源。为显示切换增加 display/rotation/epoch 传播；在没有 wire rotation 字段前，不用“强行交换宽高”代替 rotation。
2. **修复 FFI 更新时机**：不要在 `run_streaming()` 外捕获一对固定宽高并盖到所有帧。优先使用解码器实际输出尺寸或每个显示/帧的几何事件；几何变化时更新 ArkTS、renderer、输入和远端光标。
3. **重写 Android 屏幕几何归一化**：优先依据同一套 WindowMetrics 与 Display rotation 得到当前物理方向；configuration orientation 仅作受控 fallback。明确处理 `ORIENTATION_UNDEFINED`，避免先取 max/min 再二次交换。
4. **完整比较采集状态**：比较 width、height、scale、dpi、rotation，而不是只比较 width；任何变化都要按顺序停止旧采集、重建 ImageReader/VirtualDisplay/encoder、刷新远端显示并发出新 geometry epoch。
5. **修复 raw stride 合同**：要么在 Android 端复制成紧密 RGBA，要么把 pixel stride/row stride 随帧传到 native；禁止默认用 `buffer.length / height` 推断行宽。
6. **解除错误的本地方向耦合**：控制窗口可以继续使用独立的本地横屏策略，但不能根据本地横屏去旋转远端帧；renderer 应按远端 geometry 正确 contain portrait。若产品确实需要控制窗口跟随远端方向，作为独立可选策略，并且由 geometry epoch 驱动。
7. **同步输入和光标**：同一 `RemoteVideoGeometry` 用于远端输入、远端光标、画布渲染和光标形状；增加 portrait/landscape/180° 的 round-trip 映射测试。

## 6. 分阶段实施计划

以下阶段在审批后执行；本轮只落盘计划。

### 阶段 0：基线、诊断和构建门禁

- [ ] 固化当前 RDP 四档与 RustDesk初始化尺寸的基线，不把“请求尺寸”误报成“已改变远端分辨率”。
- [ ] 完成 Android portrait 诊断探针和最小设备矩阵，保存 PeerInfo、FFI、decoder、renderer、surface 的同时间轴证据。
- [ ] 明确协议/依赖/生成代码边界；若修改 vendor proto 或 RustDesk Android 代码，提前评估 SBOM、NOTICE、provenance 和许可证影响。
- [ ] 确认真实 FreeRDP 构建门禁仍使用 `entry/build-profile.json5` 的 `USE_REAL_FREERDP=ON`，避免用 fallback skeleton 验收尺寸能力。

**完成标准**：能够用日志和截图确定至少一个真实 portrait 失败路径；没有证据时不进入“修复已完成”的验收。

### 阶段 1：统一预设、显示基线与几何模型

- [ ] 将上一份计划中的远端分辨率预设模型与本计划的 `RemoteVideoGeometry`、`CanvasTransform` 接口对齐。
- [ ] 保留设置缩放与双指缩放的独立持久化/生命周期；设置值是 base，gesture 值是当前会话 transient state。
- [ ] 扩展 `entry/src/main/ets/types/rdpnapi.d.ts` 的 renderer viewport/geometry 类型，避免在 ArkTS 中继续依赖无类型的 Record 字段。
- [ ] 为 RDP 的 desktop resize、RustDesk 的 display/geometry 更新和本地 surface resize 定义统一事件语义。

**预计涉及文件**：`entry/src/main/ets/types/rdpnapi.d.ts`、`entry/src/main/ets/services/ExtensionLoader.ets`、`entry/src/main/cpp/extensions/*`、上一份计划列出的预设策略文件。

### 阶段 2：本地画布双指缩放、滚动与输入映射

- [ ] 在 `RemoteDesktop.ets` 接入 `TwoFingerCandidate → CanvasTransform` 状态机，并处理 native XComponent/ArkTS overlay 的唯一 owner。
- [ ] 在 `gl_renderer.h/.cpp` 增加运行时 transform/viewport 合同：等比缩放、焦点保持、裁剪、pan clamp、surface resize 重算。
- [ ] 将 `mapInputPoint()`、`remoteToLocalPoint()`、远端光标、光标形状、触摸指示器统一到同一个 transform。
- [ ] 首版使用渲染器级 pan，不把 XComponent 包进会改变生命周期或事件分发的通用滚动容器；后续再评估滚动条/边缘自动平移。
- [ ] 明确 touchpad 双指右键/滚轮的替代入口或模式开关，保留三指控制面板且不与 pinch 串扰。

**预计新增测试**：`entry/src/test/RemoteCanvasTransformPolicy.test.ets`、`entry/src/test/RemoteGesturePolicy.test.ets`，以及 `entry/src/main/cpp/test/` 下的纯几何/渲染 viewport 测试。

**完成标准**：在 RDP、RustDesk、VNC 等已有视频协议上，双指只改变本地画布；远端窗口尺寸和远端应用状态不变；超出 viewport 的内容可完整 pan 到四边，输入和光标无固定比例偏移。

### 阶段 3：RustDesk 远端应用缩放能力

- [ ] 在 `rustdesk_ffi/src/lib.rs`、`control_inbox.rs`、`connector.rs` 增加 scale control；高频 update 需要合并，start/end 必须可靠有序。
- [ ] 在 `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h` 增加明确的 FFI 入口，并在 ArkTS capability 未确认时拒绝发送或降级，不静默吞事件。
- [ ] 复用现有 `TouchScaleUpdate` 只覆盖协议已经证明的 peer；它只有增量 scale，没有 focal point，不能直接宣称可以精确复刻 Android pinch。
- [ ] 为 Android peer 设计版本化能力：服务端 `connection.rs` 转发 scale start/update/end；安卓 `MainService.kt`/`InputService.kt` 实现真实多点手势注入。若现有 scalar 协议无法表达焦点和双指轨迹，则增加向后兼容的 touch-scale 扩展字段/消息，而不是用隐式宽高或固定中心猜测。
- [ ] 仅当 Android 端完成能力协商和真实应用验收后，才在控制条显示“远端应用”目标；不支持的旧 RustDesk peer 只提供本地画布目标。
- [ ] RDP 单独评估 FreeRDP 的 touch/gesture channel；在确认之前只提供本地画布缩放，`Ctrl+wheel` 只能作为显式、应用相关的兼容动作，不能当成通用远端 pinch。

**预计涉及文件**：`rustdesk_ffi/src/lib.rs`、`rustdesk_ffi/src/control_inbox.rs`、`rustdesk_ffi/src/connector.rs`、`rustdesk_ffi/src/protocol/session.rs`、`entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`、`rustdesk_vendor/src/server/connection.rs`、`rustdesk_vendor/src/server/input_service.rs`、安卓 `MainService.kt`/`InputService.kt` 及必要的协议生成/合规文件。

**完成标准**：在明确支持的 RustDesk Android 版本上，浏览器/图片/地图等应用内容缩放而远端窗口和采集尺寸不变；一次手势不会同时改变本地画布；旧 peer 能力不足时有可见降级。

### 阶段 4：RustDesk 安卓 portrait 几何修复

- [ ] 先修 `peer_display_size()`/FFI 的固定宽高传播，建立实际 frame/decoder 尺寸与逻辑输入尺寸的分离。
- [ ] 再修 Android `updateScreenInfo()` 的 rotation/WindowMetrics 归一化、全字段变化检测和 capture 重建时序。
- [ ] 修复 ImageReader stride 或明确 raw frame 的紧密布局合同。
- [ ] 将 geometry epoch 传播至 renderer viewport、ArkTS remote size、input mapping、cursor overlay；方向切换中丢弃旧 epoch 的帧和触摸。
- [ ] 方向跟随控制端窗口作为独立产品策略评估，不与远端 portrait 正确渲染绑定。

**完成标准**：连接前/后 portrait、landscape、reverse portrait 均显示正确比例；方向切换后不使用旧尺寸；无旋转、镜像、裁剪和输入坐标错位；远端窗口不会因为本地画布缩放而改变尺寸。

### 阶段 5：集成、性能和发布验收

- [ ] 完成 ArkTS、Rust FFI、C++ renderer、RustDesk vendor/Android 的定向测试和构建。
- [ ] 完成 RDP 真实 FreeRDP、RustDesk direct/relay、Android raw/codec、VNC 回归。
- [ ] 在设备矩阵中验证 surface 重建、后台恢复、连接重连、窗口 resize、half-scale、三指控制面板和外接鼠标/触控板。
- [ ] 记录 pinch 的帧率、延迟、丢帧、GPU/内存峰值；旋转切换不得产生持续旧帧或明显输入滞后。
- [ ] 通过 Light 合规门；vendor/proto/ABI 变化同步发布材料。

## 7. 测试矩阵

### 7.1 纯逻辑与单元测试

- [ ] 焦点保持：任意 focal point 缩放后，该点对应的远端源坐标误差在浮点容差内。
- [ ] pan 边界：内容小于 viewport、恰好等于 viewport、横向溢出、纵向溢出、双向溢出。
- [ ] viewport resize：横竖窗口、导航栏变化、surface 重建、远端尺寸变化后 pan 正确 clamp。
- [ ] rotation：0/90/180/270 的本地到远端、远端到本地 round-trip。
- [ ] 手势仲裁：双指轻点、双指平移、双指 pinch、三指面板、单指点击/拖拽、取消和重复事件。
- [ ] FFI scale queue：高频 update 合并、start/end 不丢、连接断开后不发送旧 session 事件。

### 7.2 端到端功能

- [ ] RDP：画布 pinch/pan；远端窗口分辨率不变；明确验证远端应用缩放暂不承诺或仅走已验证兼容动作。
- [ ] RustDesk Windows：本地画布目标；远端应用目标只在 peer 能力确认后验证。
- [ ] RustDesk Android：portrait/landscape；浏览器、图片、地图、PDF 等可缩放内容；窗口边界和采集帧尺寸不变；缩放结束后状态稳定。
- [ ] RustDesk Android 旧版本/无 Accessibility 权限/relay/direct：都显示正确能力降级。
- [ ] VNC：只验证本地画布变换不破坏原有输入映射。

### 7.3 设备与方向

- [ ] Android 小屏、大屏、高 DPI、half-scale 开关。
- [ ] 连接前 portrait、连接前 landscape、连接后旋转、reverse portrait、屏幕锁定/解锁。
- [ ] Android 分屏/浮窗或 WindowMetrics 非全屏场景。
- [ ] raw ImageReader 与实际使用的编码路径；验证 stride、帧尺寸和 surface 尺寸一致。
- [ ] HarmonyOS 客户端窗口 resize、横竖布局切换、后台恢复、重连。

## 8. 风险、开关和回滚

建议采用三个独立开关，互不影响：

- `canvas_gesture_zoom_enabled`：关闭时恢复现有双指输入语义。
- `remote_touch_scale_enabled`：默认关闭，只有 capability 和设备验收通过后开启。
- `rustdesk_android_geometry_v2`：启用新 geometry/rotation/stride 合同；异常时回退到 Fit/旧渲染路径并记录诊断，不回退到错误的宽高交换。

主要风险：

- 双指手势与现有右键/滚轮语义冲突；通过显式目标/控制模式解决，不让事件同时进入两个系统。
- Android `AccessibilityService` 的多点手势能力、权限和厂商差异；没有真实设备验证前不得宣称通用支持。
- `TouchScaleUpdate` 只有增量 scale、没有焦点/双指轨迹；必要时需要协议扩展和版本兼容。
- frame 几何修复可能影响硬解、软解、远端光标和 RDP desktop resize；必须使用 geometry epoch 防止旧帧覆盖新方向。
- vendor/proto/Android 代码变化会触发合规、ABI 和发布材料更新。

回滚策略：先关闭远端 touch-scale，再关闭画布 gesture zoom；若 Android geometry v2 异常，回退到只显示 contain 的旧路径，同时保留诊断日志。回滚不能恢复到“本地横屏强行旋转远端 portrait”的隐式行为。

## 9. 与上一份计划的合并边界

本文件的内容已并入总计划，保留本文件用于追溯审查依据：

- 总计划路径：`docs/REMOTE_RESOLUTION_SCALE_PLAN.md`。
- 合并内容包括：双指画布 zoom/pan、远端应用 touch-scale、RustDesk Android portrait 几何修复、测试矩阵、灰度和回滚。
- 后续补充内容包括：设置中心“显示与交互 / Windows RDP / RustDesk”信息架构、PC/Pad/Phone 响应式布局、默认值/主机偏好/会话覆盖边界和能力禁用文案。
- 本次合并只修改计划文档，没有修改 RDP、RustDesk、renderer、ArkTS 或 vendor 功能代码。

合并后的总计划采用以下顺序：

1. 上一份计划的 RDP/RustDesk 分辨率预设与设置缩放基线。
2. 本文件的 `RemoteVideoGeometry` 与本地 `CanvasTransform`，作为共享渲染/输入基础。
3. 本文件的 RustDesk Android touch-scale 能力，明确与本地画布目标分开。
4. 本文件的 Android portrait geometry 修复与设备验收矩阵。
5. 统一 feature flag、回滚、合规和发布门禁。

## 10. 审批点

合并前需要确认的三项产品决策已纳入总计划第 9 节：

- 双指默认目标是否确定为“画布”，远端应用缩放是否通过控制条显式切换。
- RustDesk Android 远端应用缩放是否接受新增协议/安卓注入链路，而不是只做本地画布缩放。
- 控制端窗口是否继续默认横屏；无论选择何种本地窗口策略，远端 portrait 均必须由远端 geometry 正确渲染。

当前执行和后续审批均以 `docs/REMOTE_RESOLUTION_SCALE_PLAN.md` v2.1 为准；本文件不再作为独立执行计划。
