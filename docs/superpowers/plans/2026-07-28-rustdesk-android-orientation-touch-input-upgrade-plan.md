# RustDesk Android 方向、远端几何与触控输入统一升级计划

> 状态：只完成诊断与计划落盘，尚未实施代码修改。
>
> 日期：2026-07-28
>
> 仓库：RemoteDeskHarmonyOS
>
> 适用范围：HarmonyOS NEXT 控制端，项目 API 23 兼容上限；RustDesk Android 被控端互操作
>
> 本计划不包含主机列表、RDP、VNC、SSH 功能迁移。它只处理 RustDesk 会话的窗口方向、远端显示几何、画布变换、虚拟鼠标/触控板和触控手势归属。

本轮增补：双指画布缩放改为默认关闭；开启后，双指捏合负责缩放，双指保持静止约 0.4 秒再拖动才取得画布平移 ownership；未完成长按且未识别为 pinch 的双指移动继续保留触控板滚轮语义。该规则用于消除画布平移和双指滚轮的竞争，后续与方向、几何和输入 ownership 一起实施。

## 0. 执行边界

本文件是后续实施的实体计划，不代表功能已经修复。本轮只补充本计划文件，不修改 ArkTS、Rust、C/C++、协议、测试、构建配置或现有 session 文件。

后续执行必须遵守以下规则：

- 保留当前工作树中其他 session 的修改、暂存内容和未跟踪计划，不使用 reset、checkout、自动 stash 或覆盖式恢复。
- 当前工作树未清理前，不把本任务代码混入其他任务。实施时从同步后的 main 创建唯一的 codex/<task> 分支；若已有活动任务分支，继续原分支，不另开分支。
- 方向策略、远端几何、输入映射和触控 ownership 必须分层实现，不能用一次性修改 RemoteDesktop.ets 的条件分支把四个问题混在一起。
- 不把控制端 Window 方向称为“让远端 Android 旋转”；远端系统旋转必须有被控端 RustDesk Android 服务的能力、协议和真实设备证据。
- 所有 HarmonyOS API 先查本地 API 23 文档并通过 API 23 ArkTS 编译；网页最新文档不能替代本地 SDK 可用性证明。
- 如修改 RustDesk 协议、vendor 快照或第三方依赖，必须同步更新 provenance、哈希、SBOM、NOTICE、许可证和 AGPL 发布边界。
- 代码、单元测试、ArkTS 编译、HAP 构建、控制端真机、远端 Android 端和性能验收是独立证据层，不能互相替代。

## 1. 问题定义与完成标准

### 1.1 必须解决的问题

1. 控制端鸿蒙手机进入 RustDesk 会话后不能正常随设备旋转，导致竖屏 Android 远端无法充分利用屏幕。
2. RustDesk 远端 Android 的竖屏、横屏或连接后方向变化，在本地显示、Surface、光标和输入映射之间可能不一致。
3. 初始竖屏 Surface 被交换为横屏请求，可能造成远端 Android 初始比例、黑边、裁剪或输入坐标异常。
4. “触控板”“触控”“键鼠”“双指画布缩放”“远端应用双指缩放”之间没有统一的输入 ownership。
5. 当前“直接触控”并非原始多点触摸透传，不能据此承诺 Android 原生多指手势或系统旋转。
6. 双指 pinch、双指滚轮、双指右键、三指控制面板和虚拟鼠标在同一个触摸表面上竞争事件。
7. 方向变化、Surface 重建、PIP 转移、断线和设置动态切换时，必须释放或重锚定所有临时输入状态。
8. 当前移动端首次加载及旧默认迁移会把 `canvasGestureZoomEnabled` 设为开启；这与“用户明确开启后才改变双指语义”的产品要求相反。
9. 当前双指平移没有长按门槛：并行 `PanGesture` 达到距离阈值即调用 `startCanvasPan`，而触控板 handler 仍可对同一触摸序列发送滚轮，造成画布移动、滚轮、右键候选和输入消费互相抢占。

### 1.2 非目标

- 不复制或内嵌完整 RustDesk Android 被控端源码。
- 不在没有被控端支持证据时新增一个“远端旋转”按钮并宣称可用。
- 不把本地画布缩放冒充 Android 应用内部缩放。
- 不默认修改 RDP、VNC、SSH 的窗口方向或触控语义。
- 不在 RustDesk 协议没有对应 endpoint 实现时擅自扩展 rotation 命令。
- 不通过交换 width/height 猜测 90 度和 270 度方向。

### 1.3 完成定义

只有同时满足以下条件，才能把功能标记为完成：

- 移动控制端不再被 RustDesk 页面无条件锁横屏；方向策略在窗口、分屏、PIP 和失败回退场景可解释。
- 远端几何、实际帧尺寸、画布、光标和输入坐标使用同一份带 epoch 的变换数据。
- 本地画布 pinch、远端应用 TouchScale/TouchPan、触控板滚轮/右键和直接触控每个触摸序列只有一个 owner。
- Up、Cancel、Surface 销毁、方向 epoch 变化、断线和设置关闭都能幂等释放鼠标按钮和远端 TouchEvent。
- 真实 RustDesk Android 被控端的能力矩阵已记录；没有能力的 endpoint 会清晰降级。
- API 23 编译、HAP、受影响的 Rust/FFI 测试、控制端真机和真实 Android endpoint 互操作证据全部独立通过。

## 2. 当前代码基线

### 2.1 控制端方向锁定

核心文件：entry/src/main/ets/pages/RemoteDesktop.ets。

- aboutToAppear 在 3014 无条件调用 setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE')。
- 连接成功在 5926 再次调用同一横屏策略。
- RDP 错误路径 4664、4706 也会强制横屏，说明当前逻辑是页面级策略，不是 RustDesk Android 专属策略。
- setPreferredOrientation 在 6011-6023 只调用 Window.setPreferredOrientation 并更新 isLandscape；没有策略来源、设备类型判断、远端几何判断、异步 generation 或方向失败回退。
- 当前 isLandscape 主要是状态记录，不构成本地窗口方向决策。
- BreakpointUtil.ets 只通过 windowSizeChange 更新断点，不负责方向控制。

结论：本地控制端无法在连接期间自由旋转是已确认问题；后续必须把 RustDesk 方向策略从通用页面生命周期中拆开，并保证其他协议不被误伤。

### 2.2 初始尺寸和远端几何

核心文件：entry/src/main/ets/pages/RemoteDesktop.ets、rustdesk_ffi/src/connector.rs。

- adaptiveSurfaceSize 在 2852 附近读取 Surface/Display 尺寸。
- 当 width < height 时，它会交换宽高，注释明确说是为了把 RustDesk 请求保持成“电脑屏幕”的横向形态。
- desktopSize 在 3259 附近把该尺寸用于 RustDesk 初始桌面尺寸。
- FFI 已处理 PeerInfo 和 SwitchDisplay，并保存当前显示器宽高、原始尺寸、分辨率、scale 和 geometry_epoch。
- connector.rs 已有横屏到竖屏宽高变化的单元测试，但这只证明状态更新，不证明真实 Android 采集、编码、解码、渲染和输入端到端正确。
- 当前协议和 FFI 主要有 width/height，没有独立可信的 rotation 字段。

结论：不能继续无条件交换初始宽高。必须区分本地 Surface 尺寸、远端逻辑输入空间、实际视频帧尺寸和远端系统方向；没有 rotation 时显式保持 unknown。

### 2.3 触控和手势入口

核心文件：entry/src/main/ets/pages/RemoteDesktop.ets。

- touchpad handler 在 8374 附近处理相对鼠标、点击、长按拖拽、双指右键、双指滚轮和三指控制面板。
- direct touch handler 在 8589 附近处理 TouchEvent，但注释仍明确为占位的多点透传；单指 Down 会先建立鼠标左键语义。
- configured touch handler 在 8716 附近先调用 consumeCanvasPinchTouch，再按 controlMode 分派。
- 透明 overlay 在 9571 使用 HitTestMode.Block，在 9584 使用并行 PinchGesture 和 PanGesture，同时保留 onTouch 兼容路径。当前 `PanGesture({ fingers: 2, distance: 5 })` 一旦达到阈值便启动画布平移，没有双指静止长按阶段。
- Pinch/ Pan 获得 ownership 后会 stopPropagation，但当前架构仍有 XComponent、overlay 和 gesture recognizer 多入口。
- 方向或 Surface area 变化时已有释放 pinch、重置触控板 anchor、刷新 renderer 和重同步指针的逻辑；后续应复用并统一入口，不重复造清理路径。

当前冲突链路已经可以从代码直接确认：`startCanvasPan` 会在本地缩放开启且内容可平移时立即设置 `canvasPanActive` 并调用 `claimCanvasPinchInput`；与此同时，`handleTouchPadInput` 在双指 Move 中只要 `stepDy` 达到 0.5 就调用 `sendTouchPadWheel`。因此不能靠调整单个阈值解决，必须让一个序列先经过统一候选态，再由唯一 owner 决定是 CanvasPan 还是 TouchpadScroll。

### 2.4 设置现状

核心文件：entry/src/main/ets/pages/HostListPage.ets、RemoteDesktop.ets。

- rustdeskControlMode 在 421 附近定义为全局 0=触控板、1=直接触控、2=键鼠；RDP 另有 rdpControlMode。
- rustdeskRemoteAppTouchScaleEnabled 在 414/495 附近定义，默认关闭。
- canvasGestureZoomEnabled 在 426/499 附近定义；RemoteDesktop 的 StorageLink 默认值虽为 false，但 HostListPage 的 Preferences 初始化在 `canvasGestureZoomDefaultVersion < 1` 时按 `!isDesktopDevice` 写入，因此移动端首次加载及旧默认迁移实际为开启。
- saveRustDeskRemoteAppTouchScaleEnabled 在 3795 附近打开远端缩放时关闭本地画布缩放。
- saveCanvasGestureZoomEnabled 在 3829 附近打开本地缩放时关闭远端缩放。
- 设置是全局 Preferences/AppStorage 语义，不按 RustDesk 主机、远端平台或能力缓存。
- 当前“ 双指画布缩放”文案只说明捏合后缩放和平移，没有说明平移与双指滚轮的 ownership 规则；升级后必须明确“双指长按约 0.4 秒，再拖动移动已放大的画布”。
- “远端应用双指缩放”文案说明它发送 TouchScale/TouchPan；它不是系统方向控制。该开关与本地 Canvas 开关仍需保持互斥，不能让远端 TouchPan 旁路新的本地触控板 ownership。

### 2.5 当前仓库边界

当前仓库没有 RustDesk Android 被控端完整 Flutter、Android service 或 src/server 源码，只有本地维护的 RustDesk FFI/协议输入和 hbb_common protobuf 快照。控制端 FFI 返回 true 只代表消息进入本地发送链路，不能证明远端 Android 应用接受或执行了 TouchEvent。

## 3. 官方资料基线

### 3.1 RustDesk 协议快照

仓库内 rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml 记录：

- RustDesk commit：93d064a9b0eb58ab94db88ff727a877ef773c0d8。
- hbb_common commit：387603f47cbb15c0d3dc3d67ae3396d3eb707daf。
- 快照获取日期：2026-07-13。

message.proto 中与本任务相关的字段：

- PeerInfo：远端 peer 和 display 的初始信息。
- SwitchDisplay：display、x、y、width、height、cursor_embedded、resolutions。
- DisplayResolution/change_display_resolution：请求显示分辨率。
- TouchEvent：TouchScaleUpdate、TouchPanStart、TouchPanUpdate、TouchPanEnd。

这些字段支持“显示几何变化”和“远端应用触控事件”两个方向，但没有通用的远端 Android 系统 rotation 命令。除非真实 endpoint 和协议版本另有约定，不能把 change_display_resolution 当成 rotate。

### 3.2 RustDesk 官方源码对照

本次通过 GitHub 只读接口核对的官方源码 ref 为：

https://github.com/rustdesk/rustdesk/tree/dabdbf73bb80f1718879fe879619d83c72103041

官方 Android 客户端说明：

- [RustDesk Android 客户端文档](https://rustdesk.com/docs/en/client/android/)：用于核对 Android 被控端的 Screen Capture、Input Control 权限和官方移动控制模式边界。该文档不能替代具体版本的 endpoint 源码和真实设备验证。

关键对照：

- [官方移动 remote_page.dart](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/flutter/lib/mobile/pages/remote_page.dart)：移动页面使用 OrientationBuilder 观察本地方向变化，在方向变化后刷新移动 action overlay 和 canvas view style；它不是远端 Android 系统旋转命令。
- [官方 remote_input.dart](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/flutter/lib/common/widgets/remote_input.dart)：官方把 touch mode 与 mouse mode 分开；touch mode 的单指 pan 产生左键按下/移动/释放，mouse mode 的双指点击为右键、hold-drag 为左键拖动；移动端两指 scale 默认改变本地 CanvasModel 的 scale/pan，桌面端才把 scale 作为 PointerDeviceEvent 发给远端。官方实现中也存在通过 hold-drag 标记覆盖普通 scale/pan 的分支，说明“同一双指序列必须先明确意图，再决定缩放/平移/滚轮”是可复用原则；本项目将其实现为可测试的长按候选状态，而不是让并行 `PanGesture` 直接抢占。
- [官方 model.dart](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/flutter/lib/models/model.dart)：官方在识别到 peer 为 Android 时默认启用 touch mode，并把本地 touch mode 与 peer option 分开处理。
- [官方 ui_session_interface.rs](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/src/ui_session_interface.rs)：switch_display 构造的是 display/width/height；send_touch_scale 和 send_touch_pan_event 构造的是 TouchEvent；change_resolution 构造的是 Resolution/DisplayResolution。
- [官方 io_loop.rs](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/src/client/io_loop.rs)：收到 SwitchDisplay 后重置视频线程并更新 display 几何，没有改变本地 Window orientation。
- [官方 video_service.rs](https://github.com/rustdesk/rustdesk/blob/dabdbf73bb80f1718879fe879619d83c72103041/src/server/video_service.rs)：被控端广播的是 display 几何、光标嵌入和支持分辨率；是否能随 Android 系统方向重建采集链路，需要 Android endpoint 自己证明。

官方源码给出的可复用原则是：方向监听、画布更新、触控模式和远端 TouchEvent 是不同职责；本项目不应把它们压缩成一个“横屏 + 双指缩放”开关。

### 3.3 HarmonyOS 官方文档

已确认的华为官方文档入口：

- [Window 接口：@ohos.window](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window)
- [Window 模块说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window)
- [Window 枚举入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-e)
- [Window Manager API 入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/window-manager-api)
- [ArkUI 多级手势](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-gesture-events-multi-level-gesture)
- [ArkUI API 入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkui-api)

方向、尺寸和手势实现必须以本地 API 23 reference 为最终依据。实施前必须查阅：

- Window.setPreferredOrientation、Orientation 枚举、WindowSizeChange 回调；
- ArkUI PanGesture、PinchGesture、GestureGroup、HitTestMode、TouchEvent 的 API 23 签名和回调顺序；
- XComponent Surface/area change、窗口可见性、PIP/分屏和方向请求失败约束。

当前网页文档的 Window 模块入口可以访问并显示 2026-03-09 更新信息，但方法详情页在本次环境中发生超时。因此计划只采纳入口和当前代码已使用的 API 名称，具体签名在实施阶段必须以本地 API 23 文档和编译结果为准。

## 4. 先冻结的产品和协议决策

### 4.1 本地控制端方向策略

推荐默认策略：

| 控制端环境 | 默认方向策略 | 远端竖屏时 |
| --- | --- | --- |
| 手机/平板普通全屏 | auto | 远端几何稳定后允许本地窗口跟随，失败则保持窗口并 contain |
| PC/大屏/自由多窗 | keep-local | 不旋转窗口，只保持远端真实比例和留白 |
| PIP/分屏受限窗口 | keep-local | 禁止方向请求，画布适配并记录降级原因 |
| 用户手动锁定 | explicit lock | 只按用户锁定显示，远端不强行改变本地窗口 |

方向状态应至少有：

- auto；
- lock-landscape；
- lock-portrait；
- keep-local/unsupported fallback。

方向策略必须是 RustDesk 会话策略，不能再由页面进入时的无条件 LANDSCAPE 决定。其他协议默认保持既有行为，除非另有明确计划。

### 4.2 远端 Android 能力分级

能力必须独立记录：

- remote_geometry_reporting：能报告 display、width、height、scale；
- remote_rotation_reporting：能报告明确的 0/90/180/270；
- remote_rotation_control：控制端能请求被控端改变系统方向；
- remote_touch_injection：被控端能消费远端 TouchEvent；
- remote_touch_scale：被控端应用能消费 TouchScale/TouchPan。

只有 geometry reporting 时，只能承诺正确显示和映射；没有 rotation_control 时，UI 不得承诺“旋转远端手机”。

### 4.3 双指目标

双指目标不根据单次移动自动猜测，必须由设置、模式和能力共同决定：

| 目标 | 作用 | 默认 |
| --- | --- | --- |
| Canvas | 本地画布缩放/平移，不改变远端应用 | 关闭，用户显式开启后可用 |
| RemoteApplication | 发送 RustDesk TouchScale/TouchPan | 关闭，能力确认后可选 |
| Touchpad | 双指滚轮/右键 | 触控板模式 |

本地 Canvas 的双指语义固定为以下状态机，常量初版为 `HOLD_MS = 400`、`HOLD_SLOP = 12dp`，最终以 API 23 真机手感和测试结果校准：

~~~text
TwoFingerCandidate
  -> scale/两指距离先超过 pinch threshold
       -> CanvasPinch（或已选择 RemoteApplication 时的 RemoteTouchScale）
  -> 在 HOLD_SLOP 内保持 HOLD_MS
       -> CanvasPanArmed（仅当当前画布确实存在可平移溢出）
  -> 未达到长按就发生明显位移且未达到 pinch
       -> TouchpadScroll（保持现有双指滚轮）
  -> 未移动即抬起
       -> TouchpadRightClick
  -> CanvasPanArmed 后发生质心位移
       -> CanvasPan；取消滚轮/右键候选
  -> Up / Cancel / 几何 epoch 变化 / 设置关闭
       -> 统一 cleanup
~~~

具体产品语义：

- `canvasGestureZoomEnabled = false` 时，Canvas 不得取得任何双指 ownership；双指滚轮和双指轻点右键保持原有触控板行为。
- 开关为 true 时，捏合仍可立即进入 CanvasPinch；两指未捏合而快速移动时仍判为 TouchpadScroll，不能自动变成画布平移。
- 只有两指在长按时限内保持在 slop 内，且缩放后的画布存在可移动边界，之后的拖动才进入 CanvasPan。长按后不移动再抬起，仍保留双指右键，不因计时器到期吞掉点击。
- 画布没有溢出、处于不可平移边界或长按被取消时，不能为了“看起来响应”而抢走触控板滚轮。
- RemoteApplication 是独立目标；默认仍关闭。若后续能力门允许远端 TouchPan，必须复用同一个候选/唯一 owner 机制，不能让远端 TouchPan 与本地 TouchpadScroll 并行发送；本轮 UI 文案的“拖动画布”特指本地 Canvas。

设置互斥只能防止两个开关同时为 true，不能替代运行时 ownership。运行中关闭本地或远端缩放时，必须取消长按 timer、结束当前本地 CanvasPan/Pinch 或远端 TouchEvent 序列，并恢复触控板的下一序列语义。

### 4.4 触控模式语义

- 触控板：虚拟鼠标，单指移动指针，单指抬起点击，双指滚轮/右键，三指控制面板。
- 直接触控：在 endpoint 支持前，明确是兼容鼠标的单指触控，不宣称原始多点透传。
- 键鼠：触摸不承担普通远端操作，键盘和物理/虚拟鼠标独立工作。
- RustDesk Android peer：参考官方 Android peer 默认 touch mode，但本项目的本地模式仍需显示其实际语义，不能因 Android peer 自动把单指鼠标模拟误称为原生触控。

## 5. 目标架构

### 5.1 RemoteGeometry 合同

建立协议无关、可单元测试的几何对象，建议字段：

~~~text
RemoteGeometry
  protocol
  sessionId
  displayIndex
  logicalWidth / logicalHeight
  frameWidth / frameHeight
  originalWidth / originalHeight
  scale
  rotation: 0 | 90 | 180 | 270 | unknown
  geometryEpoch
  source: peer-info | switch-display | frame | surface

LocalSurface
  widthPx / heightPx
  windowOrientation
  windowMode: fullscreen | split | pip | free-multiwindow

CanvasTransform
  baseScaleMode
  gestureScale
  panX / panY
  focalPoint
  viewport
~~~

规则：

- PeerInfo 只提供初始 logical geometry，实际 frame geometry 可以覆盖它。
- SwitchDisplay 增加 geometry epoch；旧事件和旧帧不能覆盖新 epoch。
- 没有 rotation 字段时保持 unknown；不能通过交换宽高伪造方向。
- renderer、canvas、cursor、touchpad、direct touch 使用同一个远端到本地变换。
- 远端视频比例和本地窗口方向是两个状态，不能相互覆盖。
- Surface 重建只更新 LocalSurface，不改变远端 logical geometry。

### 5.2 OrientationCoordinator

在 RemoteDesktop.ets 之外增加可测试的方向策略层，建议命名为 RemoteOrientationPolicy.ets 或同等职责文件。它只返回策略决策，不直接持有 Window。

输入：

- RustDesk session 是否已连接；
- isDesktopDevice/breakpoint；
- 当前 LocalSurface/window mode；
- RemoteGeometry 的 width/height/rotation/epoch；
- 用户方向偏好；
- 当前请求 generation；
- PIP/分屏/自由多窗能力；
- Window API 调用是否成功。

输出：

- requested orientation；
- 是否允许改变本地 Window；
- 是否只更新 canvas；
- 失败/降级原因；
- 需要清理的 input epoch。

Window 调用层必须：

- 只由当前 session owner 发起；
- 使用 orientation request generation，旧异步响应不能覆盖新策略；
- 对连续几次几何抖动 debounce；
- 方向变化前统一清理触控序列、鼠标按钮、TouchScale 和触控板 anchor；
- 方向变化后等待 windowSizeChange 和 Surface area change，再刷新 renderer/transform；
- 离开页面只恢复当前 session 实际拥有的方向状态，不能让旧 session 的延迟回调恢复错误方向。

### 5.3 GestureOwnershipCoordinator

建立协议无关的触摸序列状态机，所有 XComponent onTouch、透明 overlay Gesture 和控制模式都通过它决定 owner：

~~~text
Idle
  -> OneFingerCandidate
       -> TouchpadPointer
       -> DirectTouch
       -> Click / LongPressDrag
  -> TwoFingerCandidate
       -> CanvasTransform
       -> RemoteTouchScale
       -> TouchpadScroll / RightClick
  -> ThreeFingerPanel
  -> Cancel / End
~~~

规则：

- 第二指落下时只进入 TwoFingerCandidate，不立即发送右键、滚轮或释放一个尚未确认的 direct-touch 左键。
- Pinch 达到阈值并获得 owner 后，整段序列只能进入 CanvasTransform 或 RemoteTouchScale。
- Touchpad 双指没有达到 pinch 条件时，才可以进入滚轮或右键。
- DirectTouch 在 click/drag/long-press 语义确定前不发送不可逆的鼠标 Down；若兼容 endpoint 必须提前 Down，则必须有幂等补偿和取消路径。
- 只有一个 finger touch owner；物理 mouse、keyboard、axis 保持独立通道。
- 双指候选必须有显式阶段和唯一 owner：`Candidate`、`CanvasPinch`、`CanvasPanArmed`、`CanvasPan`、`TouchpadScroll`、`TouchpadRightClick`、`RemoteTouchScale`，同一序列不得跨 owner 泄漏事件。
- 本地 CanvasPan 不得在第二指移动达到普通 Pan 阈值时立即启动。优先由 pinch 阈值和 `HOLD_MS`/`HOLD_SLOP` 判定；在长按前的明显位移应取消 pan timer，并交给 TouchpadScroll。
- 长按 timer 只能在一次双指序列创建一个，携带 `gestureId`、`sessionId` 和 `geometryEpoch`；Up、Cancel、Pinch winner、Surface/方向变化、设置变化、断线和控制模式变化都必须取消它。不得在每个 Move 中创建 timer。
- 当 CanvasPan owner 已建立时，`handleTouchPadInput` 不得再调用 `sendTouchPadWheel`；当 TouchpadScroll owner 已建立时，CanvasPan 不得调用 `claimCanvasPinchInput` 或修改画布变换。
- timer 到期只将候选置为 `CanvasPanArmed`，不立即消费触摸；只有其后的有效质心位移才真正 claim CanvasPan。这样可以保留“长按后不移动仍是双指右键”。
- Up、Cancel、Surface 销毁、方向 epoch 变化、断线和设置关闭都调用同一幂等 cleanup。
- 每个序列携带 gestureId、geometryEpoch、sessionId，旧事件被拒绝。

### 5.4 输入变换

统一提供：

- localToRemote(point, RemoteGeometry, LocalSurface, CanvasTransform)；
- remoteToLocal(point, RemoteGeometry, LocalSurface, CanvasTransform)；
- clampToRemoteRect；
- viewport/letterbox 判断；
- rotation unknown 时的可解释 fallback。

方向或几何 epoch 变化时：

1. 结束或取消旧触摸序列；
2. 释放远端鼠标按钮和 TouchPan/TouchScale；
3. 发布新 RemoteGeometry；
4. resize renderer；
5. 重建 contain viewport；
6. 重置触控板 anchor 和 virtual mouse position；
7. 第一条新触摸只建立 anchor，不产生跳变；
8. 再允许普通输入。

## 6. 分阶段实施步骤

每个阶段只修改自己的文件范围；每阶段完成一次独立 commit，并在 commit 前执行该阶段定向测试和项目强制 Hvigor 门禁。

### 阶段 0：基线、资料和能力矩阵

目标：不改变行为，先冻结事实和可用 API。

工作：

1. 保存当前 main、HEAD、工作树和其他 session 文件清单。
2. 查本地 API 23 Window、Orientation、windowSizeChange、TouchEvent、PanGesture、PinchGesture、GestureGroup、HitTestMode、XComponent 文档。
3. 固定产品方向策略和三个双指目标。
4. 固定双指画布交互：Canvas 开关默认关闭；开启后捏合缩放，双指在 `HOLD_SLOP` 内保持约 0.4 秒后再拖动平移；未长按的双指移动仍是触控板滚轮，静止抬起仍是右键。
5. 记录真实 RustDesk Android 被控端版本、Android API、厂商、权限状态、是否有源码和日志。
6. 建立 capability matrix，分开记录 geometry、rotation reporting/control、touch injection、touch scale。
7. 定义 endpoint、FFI/bridge、decoder/renderer、ArkTS 四层日志事件名。
8. 查 API 23 下 `setTimeout`/LongPressGesture 与 PinchGesture、PanGesture 并行回调的可用性；优先采用“纯策略 + 单次 timer + 统一 TouchEvent 归一化”，不把未验证的高阶手势 API 当成唯一实现基础。

交付：

- API 23 可用性记录；
- RustDesk official ref 和本地 vendor ref；
- endpoint 能力矩阵；
- 方向/触控基线复现步骤；
- 不含地址、密码、token 和用户数据的测试样本。

退出条件：任何核心语义未冻结时不进入代码阶段。

建议 commit：docs(rustdesk): freeze orientation and touch baseline

### 阶段 1：RustDesk 几何合同和诊断

目标：先正确表达几何，再修窗口方向。

预计文件：

- entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets；
- 新增 RemoteGeometryPolicy.ets 或同等纯策略文件；
- entry/src/main/ets/pages/RemoteDesktop.ets；
- rustdesk_ffi/src/connector.rs；
- rustdesk_ffi/src/lib.rs（仅在 FFI 合同需要时）；
- 相关 ArkTS/Rust 单元测试。

工作：

1. 新增 RemoteGeometry 数据合同和来源/epoch。
2. 分离 local surface size、remote logical size、actual frame size、scale、rotation。
3. 删除或隔离 adaptiveSurfaceSize 的无条件 portrait-to-landscape swap；如果协议只需要上限尺寸，保持原始长短边语义并记录请求策略。
4. PeerInfo、SwitchDisplay、frame metadata 和 renderer viewport 更新都经过同一策略层。
5. 旧 epoch 的 FFI/ArkTS 回调不能覆盖新几何。
6. 增加 geometry source、epoch、frame size、surface size、viewport 的诊断日志。
7. 修复或补齐 remote-to-local、local-to-remote、cursor 和 touchpad 共同使用的变换。

退出条件：

- 竖屏 geometry 在状态和日志中保持竖屏，不再靠交换宽高伪造横屏；
- 旧事件不能覆盖新 epoch；
- RustDesk 远端画面在本地 contain 显示，输入 mapping 的纯策略测试通过；
- 不改变 RDP/VNC/SSH 几何路径。

建议 commit：feat(rustdesk): establish remote geometry contract

### 阶段 2：本地 Window 方向策略

目标：解除 RustDesk 页面级无条件横屏，并加入可解释的自动适配和回退。

预计文件：

- 新增 RemoteOrientationPolicy.ets；
- entry/src/main/ets/pages/RemoteDesktop.ets；
- entry/src/main/ets/utils/BreakpointUtil.ets（仅在需要暴露方向/尺寸事件时）；
- 方向策略测试。

工作：

1. 删除 RustDesk 会话生命周期中无条件 LANDSCAPE 的调用点；RDP 错误路径不得继续覆盖 RustDesk 策略。
2. 页面进入时只初始化方向 owner，不在窗口不可见/Surface 未稳定时用冷启动尺寸决定方向。
3. 连接成功后等待可信 RemoteGeometry 和 LocalSurface 再请求方向。
4. 手机/平板普通全屏按 auto 策略；PC、大屏、PIP、分屏和自由多窗按 keep-local。
5. 支持用户显式 lock-landscape/lock-portrait；设置必须与 RustDesk session 或 RustDesk 专属设置隔离，不能污染 RDP。
6. 使用 API 23 支持的 Window orientation 枚举；不直接采用网页最新 API 中未经本地编译确认的枚举。
7. 记录 request generation、旧方向、新方向、触发 geometry epoch、Window 返回值和降级原因。
8. 窗口方向改变时先清理输入，再等待 windowSizeChange/onAreaChange，最后刷新 renderer 和变换。
9. disconnect、页面离开、PIP transfer 和异步失败都使用 owner-safe restore。

退出条件：

- 控制端手机能在 portrait/landscape 会话间稳定切换；
- PIP/分屏被系统拒绝方向请求时不死锁、不遮挡、不改变远端比例；
- 其他协议原有方向行为没有回归；
- 方向策略单元测试覆盖 generation、抖动、失败回退和旧回调。

建议 commit：feat(rustdesk): add session-owned orientation policy

### 阶段 3：几何 epoch 与输入/光标同步

目标：修复远端旋转或画面尺寸变化后的画布、虚拟鼠标和输入映射。

预计文件：

- entry/src/main/ets/pages/RemoteDesktop.ets；
- entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets；
- entry/src/main/ets/services/RemoteGeometryPolicy.ets；
- rustdesk_ffi/src/connector.rs；
- renderer/native bridge 受影响的尺寸接口；
- 相关测试。

工作：

1. 将 geometry epoch 从 FFI 发布到 ArkTS、renderer viewport、cursor 和 input mapping。
2. 处理 SwitchDisplay 到 video reset、frame arrival、Surface resize 的时序，不能让旧帧恢复旧 viewport。
3. 统一 contain/letterbox、canvas transform、remote cursor 和 virtual mouse 的坐标源。
4. 方向变化时清空或重锚定 touchpadAnchor、virtual mouse hover、direct touch cursor 和 active pointer。
5. 第一条新 epoch 触摸只建立 anchor，不产生跨坐标空间跳跃。
6. 画布已缩放且远端 geometry 变化时，保持用户缩放意图，但重新计算合法 pan 边界。
7. 远端几何为 portrait 时不能在 local-to-remote 中再次隐式交换 width/height。
8. 统计 frame geometry 与 display geometry 不一致的次数，并在诊断面板显示来源。

退出条件：

- remote Android 从横屏转竖屏、竖屏转横屏后画面、光标、触控板和直接触控都不跳变；
- 旧帧、旧光标和旧输入不会覆盖新 epoch；
- 缩放后的画布仍可平移，虚拟鼠标仍可使用；
- Surface 重建和 PIP 转移后所有状态可恢复。

建议 commit：fix(rustdesk): synchronize geometry epochs with input mapping

### 阶段 4：统一触控 ownership 和模式语义

目标：解决 Pinch、触控板、直接触控、键鼠和三指控制面板冲突。

预计文件：

- 新增 RemoteGesturePolicy.ets 或 RemoteGestureOwnershipPolicy.ets；
- entry/src/main/ets/pages/RemoteDesktop.ets；
- entry/src/main/ets/pages/HostListPage.ets（仅设置归属和文案）；
- entry/src/ohosTest/ets/test/RemoteGesturePolicy.test.ets；
- 现有 TouchpadPointerCurvePolicy 相关测试只在必要时扩展，不覆盖其他 session 修改。

工作：

1. 把 onTouch、PinchGesture、PanGesture 和 overlay 的输入先归一化为 GestureEvent。
2. 由 coordinator 选择唯一 owner；handler 不再自行决定是否 stopPropagation。
3. 改造 DirectTouch，避免在双指候选期已经产生不可逆的左键 Down；兼容旧 endpoint 时提供幂等补偿。
4. 明确双指阈值、候选超时、右键/滚轮判定和 pinch 取得 ownership 的优先级。
5. 实现双指候选状态机和一次性长按 timer：第二指 Down 只进入候选；pinch threshold 先到则取消 timer 并进入缩放；长按到期只进入 `CanvasPanArmed`；之后质心位移才进入 `CanvasPan`；长按前位移则锁定 `TouchpadScroll`。
6. 将现有并行 `PanGesture` 改为只报告候选/位移，不得在 `onActionStart` 直接调用 `startCanvasPan`；在 API 23 兼容路径中保证 overlay 与 XComponent `onTouch` 最终只向 coordinator 提交一次事件。
7. 当 owner 为 CanvasPan 时屏蔽 `sendTouchPadWheel`，当 owner 为 TouchpadScroll 时禁止画布变换；右键候选只有在整个序列没有 pinch、没有有效滚动、没有 CanvasPan 位移时才提交。
8. 三指控制面板只能在没有其他 owner 或显式取消后触发。
9. 所有 cleanup 统一释放 left/right button、touchpad drag、TouchPan、TouchScale、virtual pointer lock，并取消长按 timer。
10. keyboard/mouse 模式不应被普通 finger gesture 意外切换为远端鼠标操作。
11. gestureId/sessionId/geometryEpoch 过期事件直接丢弃并记录原因。

长按实现约束：

- 计时起点是第二指被确认加入同一触摸序列的时刻；两指质心离开 `HOLD_SLOP`、pinch 识别、任一手指 Up/Cancel、Surface/方向变化、设置关闭或模式切换时立即取消。
- timer 到期不得发送鼠标、滚轮、TouchScale 或 TouchPan；它只改变纯策略状态。真正的 CanvasPan/RemoteTouchPan 必须在下一次有效位移时 claim。
- 触控板滚轮的累计量、右键 pending、直接触控的左键状态必须由 coordinator 读取/提交，不能让旧 handler 在 owner 已确定后继续发事件。
- 画布平移沿用当前 `canvasTransformCanPan` 和 viewport 边界约束；长按不应把缩放比例强行改回默认，也不应改变远端坐标映射。

退出条件：

- 每个触摸序列只产生一种远端语义；
- 没有重复 click、误右键、滚轮泄漏、卡住鼠标按钮或未结束 TouchEvent；
- 方向变化、Surface cancel、断线、后台恢复和模式切换测试通过；
- 双指缩放后的画布仍可独立平移，不被虚拟鼠标状态锁死。

建议 commit：fix(rustdesk): centralize touch gesture ownership

### 阶段 5：设置隔离和远端 touch-scale 能力门

目标：让设置名称、默认值、持久化范围和实际能力一致。

预计文件：

- entry/src/main/ets/pages/HostListPage.ets；
- entry/src/main/ets/pages/RemoteDesktop.ets；
- 新增 RustDesk touch/orientation settings policy；
- Preferences/CloudStore 相关 RustDesk 专属 key；
- 设置策略测试。

工作：

1. 将 RustDesk 控制模式、画布缩放、远端应用缩放和方向策略定义为 RustDesk 专属设置；不能与 RDP 复用。
2. 评估从全局设置迁移为按 RustDesk 主机或远端 capability profile 保存；迁移必须保留旧用户值并可回滚。
3. 将 `canvasGestureZoomEnabled` 的默认回退值改为 false，并将 `canvasGestureZoomDefaultVersion` 升级到下一迁移版本；新安装、无 key 和旧自动默认值都必须最终关闭。
4. 对当前版本无法区分“旧移动端自动开启”和“用户明确开启”的历史记录，本计划采用一次性明确迁移：`canvasGestureZoomDefaultVersion < 2` 时统一关闭并写入版本 2；这会让历史用户需要重新显式开启一次，但不会凭当前 boolean 伪造其历史意图。新增 `canvasGestureZoomUserConfigured`（或同等字段），从本次迁移后记录用户显式操作，后续默认策略升级不得再覆盖已配置用户。
5. 重写文案，明确“直接触控”为当前 endpoint 支持范围，避免暗示原始多点透传；“双指画布缩放”说明为：`捏合缩放画面；缩放后双指长按约 0.4 秒，再拖动可移动画布。关闭后恢复双指右键和滚轮。`。
6. 远端应用 TouchScale 默认关闭；只有能力确认后才显示或启用。
7. 没有 remote_touch_scale 时自动降级到 Canvas 或 Touchpad，并显示可诊断原因。
8. 开关在会话中变化时主动调用统一 cleanup；不能等下一次 Up 才结束旧流。关闭 Canvas 时还必须取消长按 timer、清理 `CanvasPanArmed`/`CanvasPan`，并恢复默认画布变换。
9. 设置变化必须记录 effective target、mode、capability 和 fallback，不把入队成功写成 peer accepted。
10. 如果未来增加远端旋转入口，必须只在 remote_rotation_control 能力存在时出现，并将请求结果与 geometry epoch 关联。

退出条件：

- 设置切换不会影响 RDP、VNC、SSH；
- 重启和切换主机后设置范围正确；
- 新安装、旧版本自动默认迁移和显式用户切换的 `canvasGestureZoomEnabled` 结果可预测，默认状态为关闭；
- 设置页明确写出“双指长按约 0.4 秒后拖动画布”，用户不需要从滚轮冲突中猜测操作方式；
- 远端 touch-scale 不支持时可用功能不被禁用；
- 设置测试覆盖默认值、迁移、关闭、会话中切换和失败回退。

建议 commit：feat(rustdesk): gate orientation and touch capabilities

### 阶段 6：真实 endpoint、性能和发布复核

目标：证明修复的是实际 RustDesk Android 互操作，而不是本地模拟。

工作：

1. 使用真实 RustDesk Android 被控端验证屏幕权限、输入控制权限、当前版本和厂商差异。
2. 验证连接前 portrait、连接前 landscape、连接后旋转、反向竖屏、快速连续旋转。
3. 观察被控端是否真的产生新 display geometry、实际 frame geometry 和 input capability；没有事件时记录为 endpoint 限制。
4. 验证本地画布缩放、画布平移、远端应用缩放、触控板滚轮/右键、虚拟鼠标和键盘同时工作。
5. 验证双指关闭、开启后的捏合缩放、长按后画布平移、未长按双指滚轮、双指右键和长按后无移动仍右键。
6. 验证横屏/竖屏窗口、PIP、分屏、后台/前台、Surface 重建、断线/重连。
7. 测量 pinch/geometry/input 事件频率、队列深度、丢弃旧 epoch 次数和帧率；不能以增加轮询频率掩盖 ownership 错误。
8. 由独立复核 session 检查 diff、协议边界、RDP/VNC/SSH 隔离和回滚开关。

退出条件：自动化、API 23、HAP、控制端真机和真实 Android endpoint 证据全部齐全；缺少 endpoint 证据时保持实验/灰度状态。

建议 commit：test(rustdesk): close orientation and touch interop matrix

## 7. 文件边界

### 7.1 允许修改的 RustDesk 控制端范围

- entry/src/main/ets/pages/RemoteDesktop.ets
- entry/src/main/ets/pages/HostListPage.ets（仅 RustDesk 设置）
- entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets
- 新增 RustDesk 方向、几何、gesture ownership、capability 纯策略文件
- rustdesk_ffi/src/connector.rs
- rustdesk_ffi/src/lib.rs 或对应 FFI bridge（仅合同需要）
- rustdesk_ffi/src/control_inbox.rs（仅输入队列合同需要）
- RustDesk 专属 ArkTS/ohosTest/Rust 单元测试
- 受影响的 RustDesk provenance/SBOM/NOTICE 文件

### 7.2 明确禁止的越界

- 不修改 VNC、SSH、RDP 的数据 owner、设置 owner 或连接协议。
- 不在其他协议的通用 RemoteDesktop 方向逻辑中添加隐含 RustDesk 分支之外的行为。
- 不直接修改 RustDesk Android endpoint，因为该源码不在本仓库。
- 不通过改 proto 让控制端单方面声称支持远端旋转。
- 不修改其他 session 当前正在处理的文件，除非先完成任务边界协商。

## 8. 测试与验收矩阵

### 8.1 方向和几何

| 场景 | 预期 |
| --- | --- |
| 控制端 portrait + 远端 portrait | 不拉伸，方向策略可解释，输入准确 |
| 控制端 landscape + 远端 portrait | 移动端按策略跟随或 contain；PC 不被强转 |
| 控制端 portrait + 远端 landscape | 远端保持真实几何，输入准确 |
| 连接后远端旋转 | 新 geometry epoch；旧帧/旧光标/旧输入不覆盖 |
| reverse portrait | 无 rotation 证据时显示 unknown，不伪造 90/270 |
| 初始 Surface portrait | 不因 adaptive request 隐式交换远端语义 |
| PIP/分屏/自由多窗 | 方向请求失败时不死锁，画布正常 contain |
| Surface 重建 | renderer、viewport、cursor、touchpad anchor 一致 |
| 断线/重连 | session owner 正确恢复/释放方向与 geometry |

### 8.2 触控

| 场景 | 预期 |
| --- | --- |
| 触控板单指移动/点击/长按 | 只产生预期鼠标语义 |
| 触控板双指滚轮 | 不触发 pinch 或右键 |
| 触控板双指轻点 | 只产生右键 |
| 直接触控单指点击/拖动 | 不提前误按，Up/Cancel 必须释放 |
| 直接触控第二指落下 | 进入候选态，不产生重复左键或隐式右键 |
| 本地 Canvas pinch/pan | 只改变本地画布，缩放后仍可移动 |
| Canvas 开关默认值 | 新安装和默认迁移后为关闭；未显式开启时双指不改变画布 |
| Canvas 开启后快速双指移动 | 不进入 CanvasPan；保持触控板滚轮语义 |
| Canvas 开启后双指捏合 | 先到 pinch threshold 时独占缩放，取消 pan timer，不发滚轮 |
| Canvas 开启后双指长按再拖动 | 约 0.4 秒且在 slop 内后，才移动已缩放画布，不发滚轮 |
| Canvas 开启后长按但不拖动 | 不吞掉双指右键；抬起仍只产生右键 |
| Canvas 开启但画布不可平移 | 长按不取得 CanvasPan，触控板滚轮/右键继续可用 |
| RemoteApplication pinch | 只有能力确认时发送，peer 真实内容变化 |
| 键鼠模式手指操作 | 不意外发送普通远端鼠标操作 |
| 三指控制面板 | 不被 Pinch owner 抢回或重复打开 |
| 方向 epoch 变化 | 当前触摸统一取消/重锚定，下一次手势正常 |
| 设置中途关闭 remote touch-scale | 当前远端序列立即结束，下一序列降级 |
| 设置中途关闭 Canvas zoom | 取消长按 timer、结束本地 CanvasPan/Pinch、恢复默认画布并让下一序列回到触控板 |
| 高频 pinch + 键盘/鼠标 | 不饿死键盘鼠标，不丢 start/end，不积压旧更新 |

### 8.3 远端能力

| endpoint 能力 | UI/行为 |
| --- | --- |
| 只有 geometry reporting | 正确显示和映射，不显示远端旋转承诺 |
| 有 rotation reporting | 可记录明确方向并驱动本地 auto 策略 |
| 有 rotation control | 显示可用入口，记录 request/accepted/geometry result |
| 无 touch injection | 降级为可用鼠标/触控板语义 |
| 有 touch injection 无 touch-scale | 关闭远端应用缩放，保留 Canvas/Touchpad |
| FFI 入队成功但 peer 不确认 | 诊断显示未确认，不标记功能成功 |

### 8.4 自动化和工程门禁

每个代码阶段必须按受影响范围执行：

- ArkTS 纯策略单元测试；
- RustDesk FFI/Rust 定向测试；
- API 23 测试编译；
- default@OhosTestCompileArkTS；
- assembleHap；
- 受影响时执行 ohosTest@OhosTestCompileArkTS；
- git diff --check；
- RustDesk/第三方依赖的 provenance、SBOM、NOTICE、AGPL 合规检查。

强制命令：

~~~sh
cd RemoteDeskHarmonyOS
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
~~~

不能用旧的 default@OhosTestBuildArkTS 替代。任何 SDK、签名、设备、远端 endpoint 或网络失败都必须单独记录为 blocker，不能写成代码已验证。

## 9. 提交顺序与复核流程

实施时按以下顺序，一个阶段一个 commit：

1. 基线与纯策略测试；
2. 几何合同；
3. Window 方向策略；
4. geometry epoch 与输入映射；
5. gesture ownership；
6. 设置隔离与能力门；
7. 真实 endpoint/性能测试和发布文档。

每次 commit 前：

- 只检查本阶段允许的文件；
- 运行定向测试、API 23 编译、assembleHap 和 diff check；
- 将命令、退出码和 blocker 写入共享状态；
- 不提交其他 session 的修改；
- 不在 main 上直接提交代码。

所有阶段完成后：

1. 独立 session 复审代码和测试；
2. 修复复审发现的问题并重新执行全部门禁；
3. 按仓库流程提交 PR 和开源合规检查；
4. 合并回 main；
5. 确认 main 构建和工作树状态；
6. 删除已合并任务分支。

本次只是计划落盘，不执行上述代码提交和合并流程。

## 10. 风险、阻塞和回滚

| 风险/阻塞 | 级别 | 处理 |
| --- | --- | --- |
| 当前页面无条件横屏 | 高 | 由阶段 2 拆为 session-owned policy |
| 远端协议没有 rotation 字段 | 高 | 显式 unknown；没有 endpoint 能力不承诺远端旋转 |
| 当前仓库没有 Android 被控端源码 | 高 | 建立真实版本/权限/能力矩阵；必要时由 endpoint 项目单独交付 |
| adaptiveSurfaceSize 交换宽高 | 高 | 阶段 1 删除隐式语义并以几何合同替代 |
| ArkUI overlay 与 XComponent 重复收触摸 | 高 | 单一 GestureOwnershipCoordinator 和 gestureId |
| DirectTouch 先发鼠标 Down | 高 | 双指候选期延迟或幂等补偿，增加取消测试 |
| CanvasPan 与 TouchpadScroll 再次并行发送 | 高 | coordinator 单 owner；长按前位移锁定滚轮，长按后有效位移锁定画布；增加事件序列断言 |
| 长按 timer 吞掉双指右键 | 中高 | timer 到期只 arm，不 claim；无位移 Up 仍提交右键 |
| 默认值迁移覆盖用户明确开启 | 中 | 版本化迁移并记录一次性迁移策略；新版本以后保存显式用户选择，必要时给用户一次性提示 |
| 长按延迟导致用户认为双指拖动失效 | 中 | 设置文案明确约 0.4 秒；提供可观测日志和真机调参，不降低 ownership 规则为并行发送 |
| TouchScale 入队但 peer 不消费 | 高 | capability gate 和 enqueue/sent/peer accepted 分层诊断 |
| PIP/分屏禁止方向请求 | 中高 | keep-local + contain fallback，不阻塞视频和输入 |
| API 23 与最新网页 API 不一致 | 高 | 本地 API 23 文档、编译和真机先行 |
| 官方源码与本地 vendor 版本漂移 | 中高 | 锁定 ref，变更时更新 provenance/NOTICE/SBOM |
| 方向请求异步回调乱序 | 中 | request generation + session owner |
| 其他 session 正在修改共享文件 | 高 | 不混入、不覆盖，等待边界清晰后再实施 |

回滚设计：

- 方向策略必须有 RustDesk 专属 feature flag；关闭后回到 keep-local/contain，而不是恢复通用页面级无条件横屏。
- RemoteApplication touch-scale 能力门关闭时，保留本地 Canvas 和 Touchpad。
- 几何合同升级失败时，保留旧 renderer 输入合同，但禁止发送未经确认的远端旋转/TouchScale。
- 每个阶段独立 commit，回滚只能回滚本阶段文件和策略，不回滚 RDP/VNC/SSH。

## 11. 计划完成后的交付物

- 本计划文件；
- RustDesk 控制端代码和对应阶段 commit；
- API 23 文档/编译证据；
- ArkTS/Rust 测试结果；
- 方向、Surface、geometry epoch、输入 ownership 诊断样例；
- 真实 RustDesk Android endpoint 能力矩阵和版本记录；
- 真机验收矩阵；
- provenance、SBOM、NOTICE、AGPL 合规更新（仅在依赖/协议实际变化时）；
- 独立复核结论、合并记录和分支清理记录。
