# 主机列表排序、RustDesk 安卓横竖屏与触控体验统一升级计划

> 状态：仅完成只读诊断与计划落盘，尚未实施任何代码修改。
>
> 日期：2026-07-26
>
> 仓库：`RemoteDeskHarmonyOS`
>
> 适用平台：HarmonyOS NEXT，项目兼容上限 API 23
>
> 计划性质：实体实施计划；本文件只描述后续工作，不代表功能已经实现。

## 0. 执行边界与基本规则

本轮用户明确要求“不改代码”。本次只新增本计划文件，不修改 ArkTS、Rust、C++、Proto、构建配置、测试代码、依赖或现有文档，不运行会生成构建产物的任务。

后续实施必须遵守以下边界：

- 保留当前工作区已有的未提交修改和未跟踪文档，不使用 `git reset --hard`、`git checkout --`、自动 stash 或覆盖式恢复。
- 代码实施前从同步后的 `main` 建立独立任务分支；当前工作区有既有修改时，先完成任务边界确认，不把其他任务混入本任务提交。
- 所有 HarmonyOS API 先按本地 API 23 文档和实际 SDK 编译确认，不能因为当前网页文档存在某个接口就默认 API 23 可用。
- RustDesk 协议、Android 被控端或其他第三方源码发生变化时，必须同步处理 provenance、版本、哈希、SBOM、NOTICE、AGPL 合规和互操作验证。
- 代码、构建、真机、远端被控端、云端同步属于不同证据层；任何一层通过都不能替代其他层的验收。
- 只在所有实现阶段完成、自动化检查通过、真机和真实 RustDesk Android 端验证完成后，才将功能标记为可发布。

## 1. 目标、范围和非目标

### 1.1 目标一：远程主机列表

为主机列表增加可解释、可持久化、可同步的排序能力：

- 手动拖拽排序；
- 按添加时间新到旧、旧到新排序；
- 按名称 A-Z、Z-A 排序；
- 按最近连接排序；
- 为中文、英文、数字、空名称和重复名称定义稳定排序规则；
- 明确排序模式、手动位置、搜索、协议 Tab、工作区分组和多选删除之间的关系；
- 在重启、云同步、过滤和主机增删后保持顺序稳定。

### 1.2 目标二：RustDesk Android 横竖屏

拆分并正确处理三个不同概念：

1. 控制端 HarmonyOS 窗口方向；
2. 被控端 Android 的远端显示/帧方向；
3. 远端输入坐标和本地画布坐标之间的旋转、缩放、留白、平移变换。

移动控制端在可行时可以按远端 Android 的显示方向调整本地窗口；PC/大屏控制端不应被远端手机竖屏强行旋转，而应保持画布比例并正确显示留白。

“让被控端 Android 手机物理旋转”不是控制端单方面可以保证的功能。它必须由被控端 RustDesk Android 服务提供能力、接收指令、重建采集链路并回传新的几何信息。本计划把它列为独立能力和独立验收门，不把控制端 `setPreferredOrientation()` 误称为远端手机旋转。

### 1.3 目标三：触控模式

优化手机/Pad 上的：

- 触控模式（远端直接触控语义）；
- 触控板模式（虚拟鼠标语义）；
- 键鼠模式；
- 本地画布双指缩放/平移；
- RustDesk 远端应用双指缩放；
- 双指右键、双指滚轮、三指控制面板之间的冲突处理；
- 输入丢失、方向变化、Surface 重建和断线时的状态清理。

### 1.4 非目标

本计划第一阶段不包含：

- 完整替换 RustDesk 网络核心；
- 在当前仓库中伪造或复制缺失的 Android 被控端实现；
- 对所有 Android 应用承诺通用 pinch 缩放；
- 在没有真实被控端能力证明时默认打开远端应用 touch-scale；
- 改变 RDP、VNC、SSH 的协议语义；
- 用本地画布缩放冒充远端 Android 应用内部缩放；
- 在搜索结果或隐藏条目中进行没有明确定义的隐式全局排序修改。

## 2. 代码现状和证据基线

### 2.1 主机列表

当前主机页面的核心链路是：

```text
CloudStore orderByDesc(sortorder)
  -> HostSyncService.getAllHosts() / Map insertion order
  -> HostListPage.refreshHostListView()
  -> protocol tab + search + workspace filter
  -> LazyForEach(ListItem)
```

主要证据：

- `entry/src/main/ets/pages/HostListPage.ets` 的 `refreshHostListView()` 只复制主机、过滤并刷新 `LazyForEach`，没有排序模式。
- `entry/src/main/ets/pages/HostListPage.ets` 的 `ListItem` 使用 `LongPressGesture` 进入多选，当前没有拖拽占位或重排提交。
- `entry/src/main/ets/services/HostListFilterService.ets` 只做协议过滤和搜索。
- `entry/src/main/ets/services/HostWorkspacePolicy.ets` 的工作区过滤保持输入顺序，没有主机排序。
- `entry/src/main/ets/services/CloudStore.ets` 只按 `sortorder` 降序加载主机，未定义相同序号的稳定 tie-breaker。

当前数据模型已有 `sortOrder`、`createdAt`、`lastConnected`，但存在语义冲突：

- `RemoteHost.sortOrder` 当前注释是“手动排序序号”；
- `RemoteHost.SortOrder` 枚举却表示 `CUSTOM/RECENT/NAME_AZ/NAME_ZA/FAVORITES_FIRST` 排序模式；
- 当前没有找到将这些排序模式接入 UI 或列表计算的实现；
- 当前没有发现收藏字段可以支撑 `FAVORITES_FIRST`；
- `RemoteHost.fromJSON()` 对 `createdAt` 的恢复只接受真值，旧数据 `0` 可能回退为构造时的当前时间；
- `CloudStore.insertHost()` 会把数据库 `createdat` 写成插入时刻，因此导入/迁移数据需要单独定义添加时间来源。

### 2.2 RustDesk 控制端

当前代码已经有一些可复用的基础：

- `RemoteDesktop.ets` 有 RustDesk 显示器列表、显示切换和几何同步定时器；
- `rustdesk_ffi` 有显示器宽高、原始尺寸、缩放比例、分辨率列表和 `geometry_epoch`；
- `RemoteSurfaceTransformPolicy.ets` 有 contain viewport、远端点到本地点和本地点到远端点的正逆映射；
- `ControlInbox` 会合并高频触控缩放/平移更新，同时保留 start/end 可靠边界；
- 方向变化或 Surface 生命周期变化时，当前代码已经会清理部分 Pinch、光标、触控板锚点和键盘状态。

当前问题：

- 页面出现时调用 `setPreferredOrientation(LANDSCAPE)`；
- RustDesk 连接成功后再次强制 `LANDSCAPE`；
- `adaptiveSurfaceSize()` 会将初始竖屏尺寸交换成横屏尺寸；
- FFI 的 display state 主要表达宽高，没有明确 rotation；
- `FfiVideoFrameV2` 虽有 display、width、height，但当前几何合同仍主要依赖显示器状态，不足以证明每个实际解码帧的方向；
- 协议快照的 `SwitchDisplay` 有显示器和宽高信息，没有独立旋转语义；
- 当前测试只验证宽高从横向改成纵向，不等于真实 Android 设备的采集、编码、解码、渲染和输入已经端到端正确。

### 2.3 RustDesk 源码边界

当前仓库的 `rustdesk_vendor` 只保留 `hbb_common` protobuf 快照和 provenance 文件，没有完整官方 RustDesk 的 `flutter`、`src/server` 或 Android service 源码。

当前默认 CMake 配置走本地 `librustdesk_ffi.a` FFI。`rustdesk_ffi/Cargo.toml` 使用 protobuf、NaCl 和本地实现，官方 RustDesk core 的 git 依赖仍是注释状态。因此后续必须区分：

- 当前项目自己的 RustDesk 协议/FFI 实现；
- 官方 RustDesk 当前源码的行为参考；
- 真实 Android 被控端实际运行的版本和能力。

### 2.4 当前触控链路

触控板模式已有单指相对移动、单指点击、长按拖拽、双指右键、双指滚轮和三指控制面板。

直接触控模式在单指 Down 时立即发送远端左键按下，第二指落下时再补发释放。PinchGesture、XComponent `onTouch`、透明 overlay 和远端鼠标手势同时存在，因此必须建立统一的输入 ownership，而不能继续依赖局部 `stopPropagation()`。

RustDesk 远端应用 touch-scale 的设置默认关闭。控制端已经有发送 TouchScale/TouchPan 的 ArkTS、Bridge、Rust FFI 和队列链路，但当前仓库没有 Android 被控端源码，必须用真实 Android RustDesk 端证明消息被消费，而不是只证明 FFI 入队成功。

## 3. 官方资料和约束

### 3.1 RustDesk 官方资料

- [RustDesk Android 文档](https://rustdesk.com/docs/en/client/android/)：官方 Android 控制界面区分 Mouse mode 和 Touch mode；Mouse mode 支持双指点击触发右键；Android 被控端需要 Screen Capture 和 Input Control 权限。
- [RustDesk 官方源码仓库](https://github.com/rustdesk/rustdesk)：用于确认官方目录结构和平台实现边界。
- [官方移动端 remote_page.dart](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/mobile/pages/remote_page.dart)：官方移动页面会观察本地方向变化并刷新 canvas/action overlay，同时把 touch mode、mouse mode 和 GestureHelp 分开。
- [官方 display_service.rs](https://github.com/rustdesk/rustdesk/blob/master/src/server/display_service.rs)：官方显示服务在几何变化时向客户端发送支持分辨率和显示切换信息。
- [官方 input_service.rs](https://github.com/rustdesk/rustdesk/blob/master/src/server/input_service.rs)：官方输入服务包含 `TouchEvent`、`ScaleUpdate` 等触控相关协议路径，但不同被控端平台的实际消费能力需要按版本和设备验证。

### 3.2 HarmonyOS 官方资料

当前会话没有暴露用户所说的 HarmonyOS 文档 MCP 资源，因此本轮用华为公开文档做补充依据，并把“本地 API 23 文档复核”设为后续实施硬门禁：

- [华为 Input Kit/API 总参考](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/input-headerfile-V13)：包含窗口、Touch Event、Drag Event、组件尺寸变化等 API 入口。
- [华为 ArkUI 拖放文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-drag-drop)：用于主机列表拖拽、拖拽预览、拖放回调和边缘滚动能力核对。
- [华为 ArkUI 多级手势文档](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-gesture-events-multi-level-gesture)：用于 LongPress、Pan、Pinch、优先级、并行和冲突处理设计。
- [华为窗口尺寸生命周期 FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-190)：官方提醒 `aboutToAppear` 时窗口可能尚未可见，窗口尺寸可能不准确，应在窗口可见后获取。
- [华为方向控制 API 参考](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/js-apis-inner-app-context-V13)：用于核对方向控制能力及 API 版本；本项目实际使用的 `window.Window.setPreferredOrientation()` 仍必须以本地 API 23 SDK 文档确认。

## 4. 需要先冻结的产品决策

这些决策在写实现代码前必须落成测试和 UI 文案，避免实现过程中反复改变手势或数据语义。

### 4.1 主机列表排序决策

推荐排序模式：

| 模式 | 排序键 | 方向 | 是否允许拖拽 |
| --- | --- | --- | --- |
| 手动排序 | 持久化 manual rank | 用户定义 | 允许 |
| 添加时间 | `createdAt` | 新到旧 | 不允许 |
| 添加时间 | `createdAt` | 旧到新 | 不允许 |
| 名称 | `label`，空时回退 host | A-Z | 不允许 |
| 名称 | `label`，空时回退 host | Z-A | 不允许 |
| 最近连接 | `lastConnected` | 新到旧 | 不允许 |

默认建议：移动端和 PC 均使用“手动排序”作为初始兼容模式，保留现有顺序；用户选择自动排序后，列表显示当前模式，拖拽按钮变为不可用。

名称排序必须明确：

- 空名称的回退字段；
- 中英文混排规则；
- 数字自然排序规则；
- 中文是否按 locale、拼音或首字母分组；
- 相同名称的稳定 tie-breaker，推荐最终使用主机 ID。

### 4.2 长按与多选决策

推荐交互：

- 普通模式点击主机连接；
- 长按主机进入“整理排序模式”，并开始可视拖拽；
- 多选删除通过复选框、顶部按钮或更多菜单进入；
- 桌面设备提供拖拽手柄和鼠标拖动；
- 排序模式不显示删除操作，退出整理模式后才回到普通/多选入口。

如果产品必须保留“长按直接多选”，则拖拽必须改为明确拖拽手柄或额外的“整理”入口，不能让长按同时承担两个含义。

### 4.3 排序作用域

推荐手动顺序是全局作用域：协议 Tab、搜索和工作区分组只做过滤，不能生成不同的隐含位置。

搜索、协议或分组筛选处于活动状态时，第一版建议禁用拖拽并提示清除筛选后整理。若将来需要在过滤结果中拖动，必须定义隐藏条目之间的插入算法和 UI 反馈，并增加专门测试。

### 4.4 RustDesk 方向策略

建议提供三种本地窗口策略：

| 策略 | 移动控制端 | PC/大屏控制端 |
| --- | --- | --- |
| 自动适配 | 远端几何优先，必要时跟随远端方向 | 保持窗口方向，画布 contain |
| 跟随远端 | 远端 portrait/landscape 驱动本地窗口 | 仅在窗口管理器允许时使用 |
| 锁定方向 | 用户锁定横屏或竖屏 | 用户锁定窗口方向 |

推荐默认使用“自动适配”：远端画面保持真实宽高比，移动控制端在窗口、PIP、分屏等场景允许时跟随远端；不因控制端横屏而把远端竖屏帧强行旋转。

### 4.5 远端 Android 旋转能力

必须把能力分成：

- `remote_geometry_reporting`：被控端能报告当前 display/width/height/scale；
- `remote_rotation_reporting`：被控端能报告明确 rotation；
- `remote_rotation_control`：控制端能请求被控端旋转；
- `remote_touch_scale`：被控端能消费远端应用 pinch。

只具备前两项时，控制端只能正确显示远端画面；不应在 UI 中承诺能够改变远端手机方向。

### 4.6 触控目标决策

双指必须由显式目标决定：

- `Canvas`：只改变本地画布比例和平移；
- `RemoteApplication`：只在能力确认后发送远端 TouchScale/TouchPan；
- `Touchpad`：保留双指滚轮/右键，仅适用于触控板语义。

第一版不根据单次手指移动自动猜测这三个目标。

## 5. 目标架构

### 5.1 主机排序层

新增独立的纯策略层，建议命名为 `HostSortPolicy.ets`，职责包括：

- `HostListSortMode` 合法值归一化；
- 排序键选择；
- 名称回退和 locale/numeric 比较；
- 稳定 tie-breaker；
- 手动顺序的比较；
- 过滤后是否允许重排的策略判断。

`RemoteHost.sortOrder` 保留为手动 rank 或迁移为语义更清晰的字段；排序模式不得写入主机对象。

排序管线应固定为：

```text
raw hosts
  -> normalize legacy values
  -> apply global sort mode
  -> apply protocol/search/workspace visibility filter
  -> render list
```

如果产品需要“过滤后仍保持原列表中的相对顺序”，可以先过滤再排序，但必须通过测试固定语义；不能让不同调用点各自排序。

手动 rank 建议：

- 以稳定主机 ID 为唯一身份；
- 不依赖数组下标作为云端永久值；
- 初始数据按当前实际顺序生成 rank；
- 拖动一次尽量只产生一个批量事务；
- 采用间隔 rank 或批量重编号，避免每次拖动都更新所有主机；
- 同步冲突时以显式列表版本或最后一次有效重排策略处理，不能依赖数据库无序 tie。

### 5.2 主机列表 UI 层

预计涉及：

- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/services/HostListFilterService.ets`
- `entry/src/main/ets/services/HostWorkspacePolicy.ets`
- 新增排序策略和测试文件

UI 要求：

- 排序入口放在主机列表工具栏或更多菜单；
- 当前排序模式始终可见或可通过菜单确认；
- 手动模式显示拖拽手柄/占位线；
- 拖拽时显示明确的目标插入位置；
- 拖动中不能触发连接、编辑、删除、滑动操作；
- 列表为空、加载中、过滤无结果时不启动拖拽状态；
- `LazyForEach` key 始终使用稳定主机 ID，不使用临时数组 index；
- 多选状态和整理状态互斥，退出时清理所有临时选中/拖动状态。

拖拽 API 具体采用 ArkUI 原生 ListItem 拖放能力，还是使用自定义 `PanGesture` + reorder DataSource，必须在 API 23 编译和真机回调顺序验证后决定。不能只按最新网页文档复制高版本示例。

### 5.3 RustDesk 统一远端几何

建议建立协议无关的 `RemoteVideoGeometry`：

```text
RemoteVideoGeometry
  displayIndex
  pixelWidth / pixelHeight       # 当前解码/渲染实际尺寸
  logicalWidth / logicalHeight   # 远端输入坐标空间
  rotation                       # 0/90/180/270/unknown
  inputScale
  geometryEpoch
  sourceKind                     # RustDesk/RDP/VNC/decoded

CanvasTransform
  baseScaleMode
  baseScale
  gestureScale
  panX / panY
  focalPoint
  viewportX / viewportY / viewportW / viewportH
```

几何事件流：

```text
remote PeerInfo / display event / actual decoder frame
  -> normalize geometry
  -> increment geometryEpoch
  -> update renderer viewport
  -> update input transform and cursor transform
  -> optionally request local window orientation
  -> release/re-anchor active input gesture
```

关键原则：

- PeerInfo 只作为初始逻辑尺寸，不能永远覆盖实际帧尺寸；
- 显示器几何更新必须有 epoch，旧帧不能覆盖新方向；
- 如果协议没有 rotation，必须显式记录 `unknown`，不能用交换宽高伪装 90°/180°；
- 旋转、Surface 重建和 PIP 转移期间，必须暂停或取消当前触控序列；
- 远端光标、光标形状、画布、触控和鼠标坐标必须使用同一份变换；
- 本地窗口方向改变后，重新读取可见窗口和 Surface 尺寸，不能把连接前的冷启动尺寸当作最终尺寸。

### 5.4 RustDesk 本地窗口策略

建议在 `RemoteDesktop.ets` 中把当前的无条件横屏调用拆成：

```text
resolveLocalOrientationPolicy(protocol, deviceClass, remoteGeometry, userPreference)
  -> UNSPECIFIED / LANDSCAPE / PORTRAIT / AUTO_*
```

执行时需要：

- 只对当前协议和策略生效，不能让 RDP 错误路径覆盖 RustDesk 方向策略；
- 对连续几次 width/height 抖动做 debounce；
- 用 orientation request generation 防止旧异步调用覆盖新策略；
- 在窗口、PIP、分屏、自由多窗不允许旋转的场景下记录降级原因；
- 方向变化时先清理输入，再更新画布和光标，避免方向中途的触点被映射到错误坐标；
- 断开后恢复 `UNSPECIFIED`，但不能在旧会话异步回调中恢复错误方向。

### 5.5 触控 ownership 与输入状态机

建议新增协议无关的输入策略层，例如 `RemoteGesturePolicy.ets`，由一个入口决定当前触摸序列的 owner：

```text
Idle
  -> OneFingerCandidate
      -> DirectTouch / TouchpadPointer / Click / LongPressDrag
  -> TwoFingerCandidate
      -> CanvasTransform
      -> RemoteTouchScale
      -> TouchpadScroll / RightClick
  -> ThreeFingerPanel
  -> Cancel
```

状态规则：

- 第二指落下时不能立刻发送右键或滚轮；
- Pinch 达到距离阈值并获得 ownership 后，整段触摸序列都不能再进入鼠标/滚轮 handler；
- Direct Touch 不应在尚未判断点击、拖动、长按前就不可逆地发送左键按下；
- `Up`、`Cancel`、Surface 销毁、方向 epoch 变化、断开都必须走同一清理函数；
- 清理函数必须具备幂等性，重复执行不能重复发送 release；
- overlay 和 XComponent 只允许一个层成为 finger touch owner，物理 mouse/axis/key 仍走独立通道；
- 所有 RustDesk TouchScale/TouchPan 更新都要区分 enqueue、consumed、sent、peer accepted 四种状态。

### 5.6 远端应用 touch-scale 能力

控制端 UI 只有在 capability negotiation 或真实配置确认后才显示“远端应用缩放”。能力未知时：

- 保持开关关闭；
- 双指默认走本地画布；
- UI 明确提示“被控端不支持远端应用缩放”或隐藏该选项；
- 不能因为 FFI `sendRustDeskTouchScale()` 返回 true 就认为 Android 应用已经缩放。

能力验证至少需要：

- 被控端版本；
- Android API/厂商；
- Screen Capture/Input Control 权限；
- peer 是否消费 TouchEvent/ScaleUpdate；
- 远端应用是否真正发生内容缩放；
- 远端窗口和视频几何是否保持不变。

## 6. 分阶段实施计划

### 阶段 0：基线、资料和决策冻结

目标：在任何实现前建立可重复的代码、设备和官方资料基线。

任务：

1. 确认工作树边界、当前分支、当前 commit 和已有修改。
2. 在实施设备读取本地 API 23 的 Drag、LongPress、Pan、Pinch、TouchEvent、Window、XComponent 文档。
3. 固定排序模式、长按语义、筛选中拖动策略和默认方向策略。
4. 明确真实 RustDesk Android 被控端版本和是否能取得其日志/源码。
5. 建立四层日志命名：endpoint、FFI/bridge、decoder/renderer、ArkTS。
6. 准备主机数据样本：英文、中文、数字、空名称、重复名称、旧 `createdAt=0`、相同 `sortOrder`。

交付物：

- 产品决策表；
- API 23 可用性记录；
- RustDesk Android endpoint 能力表；
- 方向和触控基线截图/日志；
- 不包含真实地址、密码、token 或用户数据的可重复测试样本。

退出条件：任何一个关键语义未冻结时，不进入实现阶段。

### 阶段 1：主机排序纯策略和数据迁移

目标：先让排序逻辑脱离 UI，可测试、可稳定复现。

预计工作：

1. 新增 `HostListSortMode` 和 `HostSortPolicy`。
2. 把排序模式从 `RemoteHost.sortOrder` 语义中分离。
3. 定义名称归一化、空字段回退、中文/英文/数字比较和 ID tie-breaker。
4. 定义 `createdAt` 历史值修复策略；不得默默把旧时间改为当前时间而不留记录。
5. 定义手动 rank 初始化、插入、删除、批量重编号和冲突处理。
6. 定义排序模式的本地/云端作用域；推荐排序偏好属于用户设置，手动 rank 属于主机数据。
7. 补充纯策略测试和迁移测试。

预计文件：

- `entry/src/main/ets/model/RemoteHost.ets`
- `entry/src/main/ets/services/HostSortPolicy.ets`（新增）
- `entry/src/main/ets/services/HostSyncService.ets`
- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/test/HostSortPolicy.test.ets`（新增）
- `entry/src/test/HostSyncService.test.ets`
- `entry/src/test/CloudStore.test.ets`

退出条件：同一输入数组在不同刷新、重启和相同数据库数据下产生完全一致的排序结果。

### 阶段 2：主机列表 UI、拖拽和云同步

目标：实现可理解且不与多选删除冲突的主机整理体验。

预计工作：

1. 增加排序入口和当前模式展示。
2. 增加手动整理模式和 drag handle/drag preview。
3. 处理 ListItem 的连接、编辑、删除、滑动和拖拽手势竞争。
4. 将拖动结果转换为稳定主机 ID 序列。
5. 使用批量数据库事务或 rank 策略保存一次拖动。
6. 处理筛选状态：默认禁止搜索/分组/协议过滤下拖动。
7. 处理主机删除、添加、批量删除、云同步刷新与拖拽中的并发。
8. 在多选模式下隐藏或禁用拖拽，在整理模式下隐藏删除按钮。

预计文件：

- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/services/HostListFilterService.ets`
- `entry/src/main/ets/services/HostWorkspacePolicy.ets`
- `entry/src/test/HostListSortPolicy.test.ets`
- `entry/src/test/HostListInteractionPolicy.test.ets`（新增）

退出条件：长按只能进入已定义的一个模式；拖拽不会连接主机、误选主机或触发删除；重新加载和另一台设备同步后顺序一致。

### 阶段 3：RustDesk 几何合同和方向诊断

目标：先证明远端方向/帧尺寸问题，再改变窗口方向策略。

预计工作：

1. 记录连接初始 PeerInfo、display state、geometry epoch、实际 decoder output、renderer viewport 和 ArkTS surface 尺寸。
2. 区分 `pixelWidth/Height` 与 `logicalWidth/Height`。
3. 明确实际帧尺寸的来源；不能让连接开始时的一次性宽高永久覆盖后续帧。
4. 为 display/rotation/scale/epoch 增加明确事件语义；无 rotation 时保持 `unknown`。
5. 使 renderer、canvas、input、cursor 共用同一几何对象。
6. 移除或隔离 RustDesk 的无条件横屏策略，增加移动端自动适配和用户锁定策略。
7. 在方向变化时取消或重锚定 Pinch、触控板、鼠标拖拽和远端 TouchScale。
8. 处理 PIP、分屏、自由多窗、Surface 重建和窗口方向请求失败。
9. 与真实 Android 被控端核对几何变化是否来自 `PeerInfo`、`SwitchDisplay`、实际编码帧或 endpoint 私有消息。

预计文件：

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- `entry/src/main/cpp/render/gl_renderer.h/.cpp`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- `rustdesk_ffi/src/lib.rs`
- `rustdesk_ffi/src/connector.rs`
- `rustdesk_vendor/libs/hbb_common/protos/message.proto`（仅在协议扩展获批准时）
- RustDesk Android endpoint 独立源码/版本（当前仓库不存在，不能假定可直接修改）

退出条件：控制端能在不强制横屏的情况下正确显示远端 portrait/landscape；方向改变后输入和光标仍准确；日志能明确说明每个 geometry epoch 的来源。

### 阶段 4：触控模式和手势 ownership

目标：使触控模式可预测、可取消、可观测。

预计工作：

1. 新增协议无关的 gesture policy/state machine。
2. 明确 Touchpad、Direct Touch、Keyboard/Mouse 三种模式的单指和多指语义。
3. 解决 XComponent 和 overlay 的唯一触摸 owner。
4. 解决双指候选期的右键、滚轮、Pinch 竞争。
5. 重新设计 Direct Touch 的 click/drag/long-press 时序，避免 Down 即不可逆发送左键。
6. 保留 RustDesk 官方移动端的模式切换和 GestureHelp 思路。
7. 将本地 Canvas pinch 与 RustDesk RemoteApplication touch-scale 完全分离。
8. 为 touch-scale 增加能力探测、降级 UI 和端到端 consumed/peer accepted 诊断。
9. 为方向 epoch、Surface cancel、后台/前台和断线加入统一清理。
10. 对 `ControlInbox` 做高频触控、键盘、鼠标按钮、视频接收并发压力测试。

预计文件：

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/services/RemoteGesturePolicy.ets`（新增）
- `entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets`
- `entry/src/main/ets/pages/HostListPage.ets`（设置和默认值）
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- `rustdesk_ffi/src/control_inbox.rs`
- `rustdesk_ffi/src/connector.rs`
- `entry/src/test/RemoteGesturePolicy.test.ets`（新增）
- `rustdesk_ffi/src/control_inbox.rs` 单元测试

退出条件：所有测试手势只能产生一种远端语义；不存在重复点击、误右键、滚轮泄漏、卡住按键或方向变化后的坐标漂移。

### 阶段 5：整合、真机、远端互操作和发布门禁

目标：证明功能不仅在纯策略测试中成立。

预计工作：

1. 执行 HarmonyOS API 23 ArkTS 测试编译和 HAP 构建。
2. 执行受影响的 Rust/native 测试和双 ABI 构建。
3. 在至少一台 HarmonyOS 手机和一台 Pad/PC 控制端验证窗口方向、PIP、后台恢复。
4. 使用真实 Android RustDesk 被控端验证 portrait、landscape、反向竖屏、连接后旋转。
5. 使用有/无 Screen Capture、Input Control 权限的被控端验证降级路径。
6. 验证远端应用 pinch 是否真的改变应用内容，不能只观察本地画布。
7. 验证主机排序重启、云同步、离线恢复、冲突和多选删除。
8. 更新 CHANGELOG、provenance、SBOM、NOTICE、测试结果和 `docs/codex/CURRENT.md`，只记录实际完成的层级。

退出条件：自动化、设备、远端 endpoint、云同步和开源合规证据全部独立通过；任何一层缺失都保持功能为实验/灰度状态。

## 7. 测试和验收矩阵

### 7.1 主机列表

| 场景 | 验收结果 |
| --- | --- |
| 5 个主机手动拖拽 | 视觉顺序、持久化顺序和重新加载顺序一致 |
| 相同 `sortOrder` | 使用稳定 tie-breaker，不依赖数据库返回顺序 |
| 添加时间排序 | 新旧方向正确，历史 `createdAt=0` 有明确迁移结果 |
| 名称排序 | 英文大小写、中文、数字、空名称、重复名称均稳定 |
| 最近连接排序 | 更新连接时间不会破坏手动 rank，切换模式可恢复手动顺序 |
| 协议 Tab/搜索/分组 | 过滤不改写隐藏主机的全局顺序 |
| 过滤中尝试拖拽 | 明确禁用或按已冻结的可解释规则执行 |
| 批量删除 | 删除后 rank 不产生重复或不可排序空洞 |
| 云同步 | 两台设备不会因单次拖动产生半套顺序 |
| 多选与整理 | 两种模式互斥，不误连接、不误删除 |

### 7.2 RustDesk 横竖屏

| 场景 | 验收结果 |
| --- | --- |
| 控制端 portrait / 远端 portrait | 画面不拉伸，输入坐标准确 |
| 控制端 landscape / 远端 landscape | 画面不裁剪异常，输入坐标准确 |
| 控制端 landscape / 远端 portrait | 远端保持 portrait 几何，控制端可 contain 显示 |
| 控制端 portrait / 远端 landscape | 远端保持 landscape 几何，控制端按策略显示 |
| 连接后远端旋转 | 收到新 epoch，旧帧不覆盖新几何 |
| reverse portrait | rotation 未知时不伪造旋转结果；有能力时正确区分 |
| FFI/decoder/renderer 尺寸不一致 | 日志能定位不一致层，不静默覆盖 |
| PIP/分屏/自由多窗 | 不因不可旋转窗口导致卡住或进入错误方向 |
| 方向变化中输入 | 不产生坐标跳变、卡住按键或未结束的 touch-scale |
| 断开/重连 | 恢复窗口策略、清理几何 epoch 和所有输入状态 |

### 7.3 触控

| 场景 | 验收结果 |
| --- | --- |
| Touchpad 单指点击/移动/长按拖拽 | 只产生预期鼠标语义 |
| Direct Touch 点击/滑动/长按 | 不提前误按、不误触发右键 |
| 双指滚轮 | 不触发 pinch 或右键 |
| 双指右键 | 不触发滚轮或画布移动 |
| 本地画布 pinch | 只改变本地画布，不改变远端窗口/应用 |
| 远端应用 pinch | 只有能力确认时发送，且远端应用内容实际变化 |
| 三指控制面板 | 不被已经获得 ownership 的 Pinch 抢回或重复触发 |
| Touch Cancel | 所有临时状态和远端按钮正确释放 |
| 方向 epoch 变化 | 当前手势取消或重锚定，下一次手势正常 |
| 高频输入 | 控制队列合并不丢 start/end，不饿死键盘鼠标和视频 |
| 无远端 touch-scale 能力 | 清晰降级为本地画布或可用的触控板语义 |

### 7.4 构建和合规

后续代码实施时按变更范围执行：

- `git diff --check`；
- `default@OhosTestCompileArkTS`；
- `ohosTest@OhosTestCompileArkTS`；
- ArkTS 策略测试；
- RustDesk FFI Rust tests；
- 受影响 ABI 的 native/Rust 构建；
- `assembleHap`；
- RustDesk/第三方依赖 provenance、SBOM、NOTICE 和 AGPL 合规门；
- 真机和真实远端 endpoint 验证。

文档计划本身不要求执行上述构建；本轮不把历史日志或旧构建结果当作本任务的当前通过证据。

## 8. 风险、阻塞和降级方案

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| 长按同时承担多选和拖拽 | 高 | 采用整理模式/拖拽手柄二选一，禁止模糊手势 |
| `sortOrder` 语义冲突 | 高 | 分离排序模式和手动 rank，先迁移再接 UI |
| 旧 `createdAt` 不可信 | 中高 | 迁移、标记未知或使用明确回退，不能隐式伪造当前时间 |
| 云端多行顺序更新冲突 | 高 | 批量事务、列表版本或稳定 rank，增加双设备测试 |
| 过滤结果拖拽破坏隐藏条目 | 中高 | 第一版禁用，后续另定算法 |
| HarmonyOS API 23 拖拽回调差异 | 中高 | 本地 API 23 编译 + 真机事件日志；必要时自定义 reorder fallback |
| WMS/PIP/自由多窗拒绝旋转 | 中 | 保持画布 contain，记录降级，不把失败当作远端错误 |
| RustDesk 协议没有 rotation 字段 | 高 | 显式 `unknown`，依赖实际帧几何或扩展协议，不交换宽高伪造 |
| 当前仓库没有 Android endpoint 源码 | 高 | 建立真实被控端版本/能力矩阵；没有 endpoint 证据就不能宣称远端功能完成 |
| TouchScale 入队但 peer 不消费 | 高 | 增加 consumed/sent/peer accepted 证据和明确降级 |
| XComponent 与 overlay 重复收事件 | 高 | 单一 ownership coordinator、gesture id、重复发送测试 |
| 引入官方 RustDesk Android 源码 | 高 | 先完成 AGPL、NOTICE、SBOM、源码提供和发布边界评估 |

## 9. 发布策略和回滚

建议分开设置功能开关：

- `hostManualReorderEnabled`；
- `hostSortModesEnabled`；
- `rustdeskAutoOrientationEnabled`；
- `rustdeskRemoteGeometryDiagnosticsEnabled`；
- `rustdeskCanvasGestureEnabled`；
- `rustdeskRemoteAppTouchScaleEnabled`。

默认安全策略：

- 主机自动排序可以发布，但保留手动顺序；
- RustDesk 自动方向先灰度到已验证设备；
- 本地画布缩放可以独立发布；
- 远端应用 touch-scale 在 peer 能力未确认时保持关闭；
- 任一方向或触控回归时，可单独关闭新策略，恢复旧窗口和触控板行为。

回滚必须能只回滚对应策略，不删除已有主机 rank、createdAt 或云端数据；排序模式和方向偏好应保留可向后兼容的默认值。

## 10. 完成定义

本计划只有在以下条件全部满足时才算完成：

- 主机列表排序模式、手动拖拽、多选删除和过滤关系有明确产品语义；
- 手动 rank 与排序模式完全分离，历史 `createdAt` 有迁移结论；
- RustDesk 本地窗口方向不再无条件覆盖远端几何；
- 远端几何、实际帧、renderer、canvas、cursor、input 使用统一 epoch/transform；
- 远端 Android 物理旋转能力和远端应用 touch-scale 能力被单独标记并经过真实 endpoint 验收；
- Touchpad、Direct Touch、Canvas Pinch、Remote TouchScale 不会互相泄漏事件；
- API 23、自动化、双 ABI、HAP、真机、云同步、远端互操作和合规证据分别记录；
- 计划中所有“已完成”状态都能指向当前代码、当前构建或当前设备证据，而不是历史文档。
