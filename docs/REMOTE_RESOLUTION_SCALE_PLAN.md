# RDP、RustDesk 分辨率预设、Windows 式缩放与双指交互实施计划

> 版本：v2.1（补充设置中心布局与会话内显示菜单协同）
> 日期：2026-07-19  方式：审查后合并落盘，当前不修改功能代码

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task after approval. The current document is a design/implementation plan, not evidence that the features are already implemented.

**Goal:** 统一规划 RDP/RustDesk 远端分辨率、设置缩放、双指画布缩放/平移、远端应用内部缩放以及 RustDesk Android portrait 几何修复。

**Architecture:** 远端分辨率、持久化本地缩放、会话内画布变换和远端应用 touch-scale 使用四个独立状态层。所有协议共用 `RemoteVideoGeometry` 与 `CanvasTransform` 的渲染/输入坐标合同；RustDesk Android 额外补齐帧几何、方向、采集 stride 和远端多点触控能力。

**Tech Stack:** HarmonyOS ArkTS/XComponent, C++ OpenGL ES renderer, FreeRDP, RustDesk Rust FFI/vendor protobuf, Android Kotlin AccessibilityService/MediaProjection, ArkTS/native/Rust tests and real-device matrix.

## Global Constraints

- 本计划合并后才是唯一执行版本；功能实现必须在用户批准后按阶段逐项进行。
- 本任务范围内不得把远端分辨率、本地设置缩放、双指画布缩放和远端应用内部缩放互相替代。
- 双指默认目标为本地画布；远端应用目标必须能力协商、权限检查和真实设备验收通过后再开放。
- 所有用户可见能力必须在设置中心的共享区或对应协议区有明确入口；远端分辨率、本地显示缩放、双指画布操作、远端应用缩放和方向策略不得共用一个含义不清的开关。
- RustDesk Android portrait 修复必须保留宽高比并同步 frame geometry、rotation、stride、renderer、输入和远端光标；不得靠强制横屏或隐式交换宽高掩盖问题。
- RDP 分辨率验收必须使用 `USE_REAL_FREERDP=ON` 的真实 FreeRDP 构建；fallback skeleton 不能作为功能通过证据。
- 保留当前工作树的用户/其他任务改动；后续实现只修改明确列出的文件，不恢复、清理、重置或格式化无关文件。
- 涉及 vendor/proto/ABI/依赖的变更必须同步 SBOM、NOTICE、provenance、许可证和生成文件审查。

---

## 0. 文档定位与边界

本文件把 RDP、RustDesk 分辨率选择、本地缩放、双指画布交互和 RustDesk Android portrait 审查结果整理为后续可执行计划。当前阶段只维护计划文件，不实现功能、不调整配置、不提交用户已有改动，也不把本文件视为功能已经完成。

本计划将四个容易混淆的概念拆开：

1. **远端分辨率**：要求远程主机改变桌面、显示器或虚拟显示器的实际输出尺寸。它会改变远端视频帧尺寸，可能影响远端物理显示器、虚拟显示器、权限和多显示器状态。
2. **本地缩放**：只改变 HarmonyOS 客户端如何把已经收到的视频帧放进本地窗口，不改变远程主机的桌面分辨率。它必须同时影响画面、黑边/裁剪、平移、鼠标、触摸、触控板和远端光标的坐标变换。
3. **双指画布缩放**：本地会话内的临时 `zoom + pan` 变换，用来查看溢出客户端屏幕的远端画布；不改变远端窗口、远端分辨率或远端应用状态。
4. **远端应用内部缩放**：向远端应用发送真实的多指触控/scale 事件，使浏览器、图片、地图、文档等应用内容缩放，而远端系统窗口和视频采集尺寸保持不变。它不是本地画布缩放，也不是远端分辨率切换。

建议的首版范围是：RDP 扩展连接初始化时的分辨率预设，RustDesk 在协议支持和远端权限允许时的运行中分辨率切换，RDP/RustDesk 共用的本地 Fit/百分比缩放，以及默认面向画布的双指缩放/平移。RustDesk Android 远端应用内部缩放必须在协议、服务端和 AccessibilityService 注入链路完成并通过能力协商后再开放；RDP 运行中动态改分辨率不应在没有 FreeRDP Display Control 验证前与 RustDesk 的运行中切换混为同一能力。

---

## 1. 审查结论先行

| 能力 | 当前实现状态 | 审查判断 | 后续建议 |
|---|---|---|---|
| RDP 固定远端分辨率 | UI 有“自动、1920×1080、2560×1440、3840×2160”4 档，值能传到 `SessionConfig` 和真实 FreeRDP 配置 | **静态链路正常；运行时尚未证明** | 保留兼容语义，先做真机/真实 Windows 主机矩阵，再扩展为统一预设模型 |
| RustDesk 固定远端分辨率 | 当前宽高主要进入初始化参数、日志和回退逻辑；分辨率入口被禁用 | **当前不能视为可用的远端分辨率切换** | 先读取 `PeerInfo` 的显示器/支持分辨率，再通过已有 `change_resolution` 协议能力接通 FFI |
| 本地缩放 | 菜单有“原始尺寸、适应窗口、自定义缩放”的状态和 Toast，但 GL 渲染仍统一 `contain/letterbox` | **菜单语义与画面行为不一致** | 重做为共享 viewport/变换模型，至少提供 Fit、100%、125%、150%、175%、200% |
| 双指画布缩放/平移 | 当前没有 `PinchGesture` 或运行时 canvas transform；双指已被右键/滚轮/直接触控语义占用 | **当前不可用，且存在手势冲突** | 以 renderer 级 `CanvasTransform` 实现焦点缩放、裁剪、pan 和输入反变换 |
| 远端应用内部缩放 | RustDesk 上游有 `TouchScaleUpdate`，但 HarmonyOS FFI 未接入；Android server/input 端忽略或未实现 scale；RDP 适配器只有鼠标/滚轮 | **当前不能视为可用** | RustDesk Android 单独做能力协商、协议/FFI/注入链路；RDP 先只承诺本地画布 |
| RustDesk Android portrait | FFI 连接时一次性读取 PeerInfo 宽高并盖到所有帧；Android 端方向重排、只比较 width，且无 rotation/stride 合同 | **高概率存在几何状态失配，需真机探针确认** | 以实际帧/解码几何为渲染事实源，补充 geometry epoch、方向归一化、stride 和输入同步 |
| 超过 10 个常用预设 | 技术上可行，当前 UI 只是四个整数挡位 | **可行，建议一次性建立数据模型** | 首版提供 17 个常用尺寸加 Auto；RustDesk 按远端能力过滤，RDP 按本地/服务端限制校验 |
| 类 Windows 缩放 | 可在本地渲染层实现，不需要改变远端协议 | **可行，但不能只调用组件 `.scale()`** | 以统一坐标变换为单一事实源，覆盖渲染、裁剪、平移和输入映射 |
| 设置中心布局 | PC 端协议侧栏与设置入口分离；手机/平板设置页用折叠区承载 RDP/RustDesk；RDP 仍是四挡单行滑块，RustDesk 没有远端显示/应用缩放设置入口 | **现有入口不足以承载新增能力，且容易把本地/远端语义混在一起** | 设置中心增加“显示与交互”共享区，在 RDP/RustDesk 区分别放远端能力；会话内显示菜单只做临时覆盖并显示能力状态 |

### 1.1 当前审查所依据的关键链路

- RDP UI 和文案位于 `entry/src/main/ets/pages/HostListPage.ets:317`、`entry/src/main/ets/pages/HostListPage.ets:6213`。
- RDP 选择值在 `entry/src/main/ets/pages/RemoteDesktop.ets:1510` 附近转换为桌面尺寸，并在 `entry/src/main/ets/pages/RemoteDesktop.ets:2788` 附近写入 `SessionConfig`。
- 真实 FreeRDP 分支在 `entry/src/main/cpp/rdp/freerdp_adapter.cpp:1967` 附近设置宽高；`entry/build-profile.json5:6` 当前明确打开 `-DUSE_REAL_FREERDP=ON`。
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp:2574` 之后是未打开真实 FreeRDP 时的 skeleton fallback。直接使用 CMake 默认值可能只完成 TCP/X.224/MCS 握手，不应作为真实分辨率能力的验收构建。
- RustDesk 初始化参数在 `rustdesk_ffi/src/lib.rs:161`、`rustdesk_ffi/src/lib.rs:725` 附近；当前显示信息读取在 `rustdesk_ffi/src/connector.rs:2004` 附近。
- RustDesk 的分辨率入口当前由 `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets:33` 明确标记为待接入显示枚举和 resize 协议。
- 仓库内置 RustDesk 代码已经存在 `ui_session_interface.rs:1548` 附近的 `change_resolution`、`change_display_resolution` 发送逻辑，以及 `server/connection.rs:4147` 附近的远端处理逻辑，说明协议层能力可以复用，但现有 HarmonyOS FFI/UI 链路尚未打通。
- 本地渲染器在 `entry/src/main/cpp/render/gl_renderer.cpp:745` 附近始终计算等比 `contain/letterbox`；ArkTS 输入换算在 `entry/src/main/ets/pages/RemoteDesktop.ets:2011`、`:2052` 附近也按 contain 假设计算。
- `entry/src/main/ets/pages/RemoteDesktop.ets:4998–5334` 当前没有 PinchGesture；双指在 touchpad 模式承担右键/滚轮，直接触控模式承担双指右键，三指承担控制面板。`RemoteDesktop.ets:5535–5628` 还存在 XComponent touch 与透明 ArkTS overlay 两层事件入口，后续必须确定唯一 gesture owner。
- 设置中心位于 `entry/src/main/ets/pages/HostListPage.ets:3343–3380` 的协议/设置入口之后：PC 端 RDP、RustDesk 是主机列表侧栏项，设置通过独立按钮打开；手机/Pad 端设置是独立底部 Tab，内部在 `HostListPage.ets:4427` 以后用折叠区组织内容。当前 RDP 设置在 `HostListPage.ets:4800–4845` 仍用四项滑块，RustDesk 设置在 `HostListPage.ets:4847–4923` 只有画质、编码、控制、LAN、隐私和音频。
- 会话内 RustDesk 显示菜单由 `entry/src/main/ets/pages/RemoteDesktop.ets:5666` 附近的 `RemoteSessionTopBar` 承载，当前把 `viewScaleMode` 传给会话菜单；`entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets:33` 已有分辨率待接入原因，但尚未为画布手势、远端应用缩放和方向能力建立统一的设置/能力状态。
- RustDesk 协议在 `rustdesk_vendor/libs/hbb_common/protos/message.proto:155–184` 已定义 `TouchScaleUpdate` 和 pan 事件；上游 Flutter 在 `rustdesk_vendor/flutter/lib/common/widgets/remote_input.dart:460–500` 对桌面 peer 发送远端 scale、对移动 peer 使用本地 canvas scale，说明两种语义应保持分离。
- RustDesk Android 服务端 `rustdesk_vendor/src/server/connection.rs:2741–2765` 只转发 pan，`rustdesk_vendor/src/server/input_service.rs:1022–1027` 只在 Windows 执行 scale；安卓 `InputService.kt:52–57` 虽声明 scale 常量，但 `:215–235` 没有实现 scale 分支。当前 HarmonyOS `rustdesk_ffi/src/lib.rs:284–310`、`connector.rs:1253–1314` 和 `rustdesk_bridge.cpp:25–48` 也没有 scale control。
- RustDesk FFI `rustdesk_ffi/src/lib.rs:820–845` 在 streaming 启动前只调用一次 `peer_display_size()`，`:385–394`、`:401–424` 用该宽高标记所有编码帧；`FfiVideoFrame:214–224` 没有 display、rotation、scale 或 geometry epoch。Android `MainService.kt:258–310` 用 orientation 重排 max/min、只比较 `SCREEN_INFO.width`，`:350–379` raw ImageReader 只传 buffer 不传 pixel/row stride。

### 1.2 当前工作树注意事项

本计划是在已有用户改动的工作树上追加的文档。已有的 ArkTS、RustDesk、测试文件、`.appanalyzer/` 和其他 `docs/` 文件均不属于本计划，不应在后续实现时被覆盖、格式化、暂存或清理。

---

## 2. 目标产品行为

### 2.1 远端分辨率与本地缩放的产品规则

| 操作 | 影响远端桌面 | 影响本地窗口 | 是否需要远端权限 |
|---|---:|---:|---:|
| 选择 RDP 远端分辨率 | 是，首版在连接建立时生效 | 间接影响收到的帧尺寸 | 由 RDP 会话/服务端能力决定 |
| 选择 RustDesk 远端分辨率 | 是，运行中发送 resize 请求 | 是，收到新帧后重新布局 | 是，且受远端物理/虚拟显示器能力限制 |
| 适应窗口 Fit | 否 | 是，等比缩小并居中，可有黑边 | 否 |
| 100% / 125% / 150% / 175% / 200% | 否 | 是，按比例显示，超过窗口时裁剪/平移 | 否 |
| 双指画布缩放/平移 | 否 | 是，改变本地画布 zoom/pan；可查看溢出内容 | 否 |
| 远端应用内部缩放 | 远端应用内容改变，系统窗口和采集分辨率不变 | 本地画布保持当前变换 | 需要远端触控能力、权限和版本兼容 |

首版不提供“拉伸到满屏”作为默认行为。保持宽高比可以避免远端文字、鼠标和 UI 控件变形；如果将来需要 Stretch，应作为显式、独立且默认关闭的选项，并重新验证输入坐标。

双指默认目标建议为“画布”。“远端应用”作为显式目标，仅在 RustDesk Android 能力协商成功后显示。不能根据手指移动自动猜测目标，因为两种操作视觉上相似，但一个只改变本地画面，另一个会改变远端应用状态。

远端分辨率建议按主机保存；本地缩放建议先在本机保存为当前客户端默认或每个会话最近使用值，不纳入账号云同步，避免同一远端配置在不同尺寸设备上产生不合适的缩放。

### 2.2 首版常用分辨率目录

建议用一个共享目录代替当前的整数 `0/1/2/3`。下面的 17 个标准尺寸已经超过 10 个，覆盖 4:3、5:4、16:9、16:10 和常见超宽屏；`Auto` 不计入标准尺寸数量。

| ID | 尺寸 | 典型场景 | 备注 |
|---|---:|---|---|
| `1024x768` | 1024×768 | 传统 4:3 | 兼容旧系统/管理终端 |
| `1280x720` | 1280×720 | HD 16:9 | 低带宽/低性能档 |
| `1280x800` | 1280×800 | WXGA 16:10 | 笔记本常见 |
| `1280x1024` | 1280×1024 | 传统 5:4 | 工控/旧显示器 |
| `1366x768` | 1366×768 | HD+ 16:9 | Windows 笔记本常见 |
| `1440x900` | 1440×900 | WXGA+ 16:10 | 旧宽屏 |
| `1600x900` | 1600×900 | HD+ 16:9 | 中低规格桌面 |
| `1680x1050` | 1680×1050 | WSXGA+ 16:10 | 旧桌面显示器 |
| `1920x1080` | 1920×1080 | Full HD | 当前默认核心档 |
| `1920x1200` | 1920×1200 | WUXGA 16:10 | 办公显示器 |
| `2560x1080` | 2560×1080 | 超宽 21:9 | 超宽显示器 |
| `2560x1440` | 2560×1440 | QHD | 当前已有核心档 |
| `2560x1600` | 2560×1600 | WQXGA 16:10 | 高分辨率笔记本/显示器 |
| `2880x1800` | 2880×1800 | 高分屏 16:10 | 高 DPI 笔记本 |
| `3200x1800` | 3200×1800 | 高分屏 16:9 | 高 DPI 笔记本 |
| `3440x1440` | 3440×1440 | 超宽 21:9 | 超宽 QHD |
| `3840x2160` | 3840×2160 | 4K UHD | 当前已有高档 |
| `3840x2400` | 3840×2400 | 4K 16:10 | 高分辨率工作站 |

目录还应保留两个非标准选择：

- `Auto`：沿用当前自动尺寸策略，但要在 UI 中说明“按当前窗口/会话能力计算”，不能让用户误以为它是某个固定远端尺寸。
- `Custom`：建议在标准目录和协议能力稳定后再开放。自定义值必须经过统一校验，不能直接把任意用户输入传给 native/Rust 层。

RDP 可以展示完整目录，但连接前需校验协议和构建上限；RustDesk 不能把这张目录当成远端支持列表，必须以目标 Peer 的 `PeerInfo.resolutions` 为准，并可将本地标准目录作为“推荐值”与远端枚举求交集。

### 2.3 分辨率数据模型

建议建立稳定 ID、数值和显示文案分离的数据模型，避免继续通过整数分支判断：

```text
ResolutionPreset {
  id: string                 // 例如 1920x1080，稳定持久化键
  width: number
  height: number
  label: string              // 例如 1920 × 1080
  aspectFamily: string       // 4:3 / 5:4 / 16:9 / 16:10 / 21:9
  source: builtin | peer | custom
  enabled: boolean
}

ResolutionChoice = auto | preset(id) | custom(width, height)
```

统一校验规则建议如下，具体上限以实际 FreeRDP/RustDesk ABI 和设备内存测试结果为最终准入条件：

1. 宽高必须为正整数，拒绝 NaN、无穷、负数和超出安全整数范围的输入。
2. 连接参数使用偶数宽高；若远端枚举返回奇数尺寸，先按协议规则过滤或明确显示“不兼容”，不得静默产生偏移。
3. 默认目录中的值应在客户端 native 允许的最大边长内；高分辨率还要进行像素面积、帧缓冲和解码内存检查。
4. 持久化只保存 `id` 或经过验证的 `{width,height}`，读取旧版整数挡位时做一次迁移；未知 ID 回退到 `Auto` 或 `1920x1080`，不得导致连接参数为空。
5. 所有过滤和回退都要返回原因，供 UI 显示或日志记录，例如“远端未枚举”“旧版本不支持”“超出本机安全上限”。

### 2.4 设置中心、协议选项卡与会话内菜单布局

设置布局必须先解决“用户在哪里配置”和“当前会话在哪里快速调整”两个问题。设置中心保存默认策略和主机偏好；会话内显示菜单只负责当前连接的临时操作，并且必须提供“恢复设置默认值”。不得在 RDP、RustDesk 两个区分别复制一套本地缩放开关，否则同一设置会出现两个来源和两个状态。

建议的信息架构如下：

```text
设置
├─ 显示与交互（共享区）
│  ├─ 本地画布显示：Fit / 100% / 125% / 150% / 175% / 200% / Custom
│  ├─ 双指操作：启用、默认目标、溢出后的拖动/滚动说明、重置策略
│  └─ 远端方向：自动适配（默认；不暴露 rotation/stride 等技术字段）
├─ Windows RDP（协议区）
│  ├─ 远端桌面分辨率：Auto、17 个标准预设、受控 Custom
│  ├─ 生效时机：连接建立时；热切换未接入时必须明确写出
│  └─ RDP 专属：色深、控制模式、音频、剪贴板、文件共享和凭据
└─ RustDesk（协议区）
   ├─ 远端显示器与分辨率：显示器选择、能力枚举、当前尺寸、支持列表
   ├─ 远端应用缩放：能力/权限门控的默认策略与说明
   └─ RustDesk 专属：画质、编码、控制模式、LAN、隐私和音频
```

#### 设置项的归属与保存范围

| 设置项 | 设置中心位置 | 推荐保存范围 | 会话内行为 |
|---|---|---|---|
| RDP 远端分辨率 | Windows RDP / 远端桌面分辨率 | RDP 全局默认；如主机编辑页已有覆盖能力，再按主机保存 override | 连接前显示最终选择；未接入热切换时不在会话菜单伪装成即时生效 |
| RustDesk 远端显示器/分辨率 | RustDesk / 远端显示器与分辨率 | 主机保存“上次成功的 displayIndex + resolutionId”，每次连接必须与当前 PeerInfo 重新校验 | 会话显示菜单打开实时枚举、发送切换、展示 pending/成功/失败和最终尺寸 |
| 本地 Fit/百分比/Custom | 显示与交互 / 本地画布显示 | 客户端设备默认，不进入账号云同步；可由会话临时覆盖 | 会话显示菜单快速选择；“恢复设置默认值”清除临时覆盖和 gesture transform |
| 双指启用与默认目标 | 显示与交互 / 双指操作 | 客户端设备默认；首版默认目标为画布 | 会话可临时切换为画布/远端应用；远端应用目标无能力时只能显示画布或禁用并说明原因 |
| 双指产生的 zoom/pan | 不作为持久设置项；只在当前会话画布上显示重置入口 | session-scoped，重连、Fit 或“重置画布”清零 | 双指改变当前 viewport；不得写回 Custom 百分比或远端分辨率 |
| RustDesk 远端应用缩放 | RustDesk / 远端应用缩放 | 客户端安全开关 + 当前会话能力状态，不把“支持”写死在主机配置里 | 只有 capability、权限、版本和 server/input 链路均通过时才允许目标切换；否则显示禁用原因 |
| 远端方向策略 | 显示与交互 / 远端方向 | 客户端默认 `Auto`，必要时按会话临时覆盖 | Android portrait 修复由 geometry 合同内部完成；设置只表达“自动适配/跟随远端”产品语义，不暴露强制横屏或手工交换宽高 |

#### 三类设备的布局规则

1. **PC/大屏**：保留当前设置独立入口；设置面板增加左侧分类导航或等价的分栏选项卡，至少包含“显示与交互”“Windows RDP”“RustDesk”，右侧显示详情。RDP 17 个预设用分组网格或两列列表，RustDesk 显示器/分辨率用“目标显示器 → 支持分辨率”的两级选择，不把长列表塞进一行滑块。
2. **Pad/中屏**：保留设置底部 Tab 和现有折叠区视觉语言；“显示与交互”放在 RDP/RustDesk 之前作为共享首项，协议区保持单列卡片。预设列表使用可滚动底部 Sheet 或分组卡片，手指可点击区域不得因为增加尺寸档位而缩小。
3. **Phone/小屏**：设置页只使用单列 Row/Card；每个 Row 只显示图标、标题、当前值和简短副标题，点击后打开底部 Sheet。17 个尺寸必须可滚动并按比例分组，Custom 用独立输入/校验 Sheet；不能在设置首页展开成密集的 17 个按钮。双指目标使用分段选择或单选列表，远端应用选项在非 RustDesk/不支持时显示禁用原因。

#### 状态、文案与交互一致性

- 每个设置卡片按“本地”或“远端”标识影响范围：使用“本地显示 150%”“远端桌面 1920 × 1080”“远端显示器 1 · 竖屏”等文案，禁止只写“缩放/分辨率”。
- RustDesk 远端能力必须有 `加载中 / 已支持 / 不支持 / 无权限 / 旧版本 / 请求失败` 状态；不可用项保留可见但不可点击，并展示 `RemoteSessionTopBarPolicy` 返回的原因，不能隐藏成无效按钮。
- 设置中心的默认值与会话菜单必须共用同一策略模型。会话菜单顶部显示“当前会话覆盖”或“使用设置默认值”，Fit/重置后清除 `gestureScale` 和 pan；分辨率切换的 pending/最终尺寸只由 RustDesk 当前会话状态驱动。
- Android portrait 的修复不应增加“旋转 90°/交换宽高/强制横屏”这类技术选项。若产品确认需要窗口跟随远端方向，只提供“自动适配/跟随远端”二选一，并在控制端窗口方向与远端帧方向之间保持独立。
- 共享区的远端应用目标只能在 RustDesk 会话可用时启用；RDP 设置区应明确显示“当前协议仅支持本地画布双指缩放”，避免用户以为 RDP 也能把 pinch 注入远端应用。

#### UI 实施文件和验收边界

| 文件 | 计划职责 |
|---|---|
| `entry/src/main/ets/pages/HostListPage.ets` | 保留现有设置折叠模式，新增共享“显示与交互”区；将 RDP 四挡滑块替换为分组预设选择；新增 RustDesk 远端显示/应用缩放能力状态卡，并按 `pc/pad/phone` 分支布局 |
| `entry/src/main/ets/services/RemoteDisplaySettingsPolicy.ets` | 统一设置项 ID、标题、副标题、作用域、默认值、设备布局和 `local/remote` 文案；供设置页与会话菜单复用 |
| `entry/src/main/ets/services/RemoteGestureSettingsPolicy.ets` | 双指开关、默认目标、重置策略、RDP/RustDesk 能力门控和禁用原因；不得把 gesture zoom 写回远端分辨率 |
| `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets` | 扩展 `displaySettings`、`canvasGestureZoom`、`remoteTouchScale`、`remoteOrientation` 的可用性/原因，区分默认设置和当前会话临时覆盖 |
| `entry/src/main/ets/pages/RemoteDesktop.ets` | 把设置默认值注入会话；承载显示菜单的临时覆盖、重置、当前远端尺寸/显示器/方向状态，并与 `CanvasTransform`/能力 epoch 同步 |
| `entry/src/test/RemoteDisplaySettingsPolicy.test.ets`、`entry/src/test/RemoteGestureSettingsPolicy.test.ets` | 作用域、默认值、协议归属、设备布局、禁用原因、会话覆盖和重置行为的纯逻辑回归；另加 UI/设备测试验证可见性和点击区域 |

设置布局阶段的完成条件不是“入口存在”，而是：在设置页能够找到正确的协议区；本地/远端当前值和作用域可读；不支持能力有原因；会话菜单不会产生第二套持久化语义；Phone/Pad/PC 均能完成选择、取消、恢复默认和状态刷新。

---

## 3. RDP 实施方案

### 3.1 保留并验收当前四档

当前四档的静态链路是完整的：UI 选择值进入连接页的桌面尺寸转换，再进入 `SessionConfig`，真实 FreeRDP 分支使用宽高初始化客户端。四档在 native 端约束内，4K 也不因当前已知边长上限而天然越界。因此审查结论是“代码链路看起来正常”，但还不能替代真实连接验收。

在扩展前必须逐档完成以下验证：

1. 检查连接日志或 native 断点，确认选择值最终对应 `DesktopWidth/DesktopHeight`，而不是只修改了 UI 状态。
2. 在 Windows 10、Windows 11 和至少一个 Windows Server 版本上分别连接 1920×1080、2560×1440、3840×2160；确认远端会话桌面尺寸、收到的视频帧和本地输入坐标一致。
3. 验证“自动”在 PC 窗口缩放、窗口调整大小、分屏和重连时的实际语义；记录它是取本地 viewport、最大边长还是服务端返回尺寸。
4. 验证连接失败、NLA、网络重连、远端拒绝高分辨率时的错误提示和回退，不得出现 UI 显示一个尺寸而 native 使用另一个尺寸的情况。
5. 对 4K 做至少 30 分钟压力观察，记录首帧时间、帧率、输入延迟、CPU/GPU、内存和是否黑屏/花屏/崩溃。

### 3.2 扩展为统一预设

实施时先把旧整数挡位映射为稳定 ID：

| 旧值 | 旧语义 | 迁移后的 ID |
|---:|---|---|
| 0 | 自动 | `auto` |
| 1 | 1920×1080 | `1920x1080` |
| 2 | 2560×1440 | `2560x1440` |
| 3 | 3840×2160 | `3840x2160` |

UI 先按分组或可滚动列表呈现，不把 17 个选项挤成难以点击的单行菜单。推荐分组为“自动”“常用 16:9”“16:10/传统比例”“超宽”“高分辨率”，同时保留搜索或最近使用项的扩展空间。

RDP 首版仍以**连接建立时设置远端尺寸**为准。若需求是连接中立即变更，应另行确认 FreeRDP Display Control 是否在当前版本、当前编译产物和 Windows Server 目标上都可用；在确认前可以通过断开重连应用新尺寸，不应伪装成已经支持热切换。

### 3.3 RDP 构建门禁

所有 RDP 分辨率验收必须使用和发布 HAP 相同的真实 FreeRDP 构建路径，确认 `entry/build-profile.json5` 的 `USE_REAL_FREERDP=ON` 生效。必须同时记录：

- arm64-v8a 和 x86_64 产物是否都包含真实 FreeRDP 分支；
- 真实 FreeRDP 库、头文件和 ABI 是否来自预期版本；
- 未打开宏的 fallback 只作为开发诊断路径，不能作为通过分辨率验收的产物；
- 连接日志中是否能区分“真实 FreeRDP”与“fallback skeleton”。

---

## 4. RustDesk 远端分辨率实施方案

### 4.1 先接通显示器和能力枚举

RustDesk 不能直接复用 RDP 的固定目录。连接成功后，需要从远端 `PeerInfo` 读取并转换为 HarmonyOS FFI 可用的结构：

```text
RustDeskDisplayInfo {
  displayIndex: number
  name: string
  x: number
  y: number
  width: number
  height: number
  scale: number
  isCurrent: boolean
  supportedResolutions: ResolutionPreset[]
}
```

计划步骤：

1. 在现有 `ControlInbox`/streaming message dispatch 中完整识别 `peer_info`，不仅记录消息类型，还解析 displays、current display 和 resolutions。
2. 通过 FFI 事件或查询 API 将显示器列表传给 ArkTS；数据要带连接 epoch/session ID，避免重连后旧会话的列表覆盖新会话。
3. 对旧版 RustDesk PeerInfo 缺少 `resolutions` 的情况做兼容：显示当前尺寸和“远端未提供支持列表”，不发送未经确认的任意预设。
4. 如果有多个显示器，先让用户选择目标显示器，再显示该显示器的支持尺寸；不能把一个显示器的列表应用到另一个显示器。
5. UI 只在能力枚举完成且会话拥有分辨率控制权限时启用入口；加载中、无列表、旧版本和权限拒绝要有不同状态。

仓库内的 RustDesk vendor 已经在 `ui_session_interface.rs:1548` 附近实现 `change_resolution`，并根据版本决定发送 `change_display_resolution` 或旧的 `change_resolution`。后续应优先通过 FFI 暴露这条已有路径，不另造一套自定义控制消息。

### 4.2 发送分辨率请求与处理结果

建议的连接中状态机如下：

```text
PeerInfo 到达
    ↓
显示器/支持尺寸可用
    ↓ 用户选择
发送 change_display_resolution 或兼容的 change_resolution
    ↓
等待远端确认/新尺寸视频帧
    ├─ 成功：更新 remoteWidth/remoteHeight、渲染 viewport、输入矩阵
    ├─ 拒绝：恢复之前选择，显示远端权限/能力原因
    └─ 超时：保留旧画面或请求 refresh_video，不得清空成黑屏
```

具体要求：

1. 新版本、多 UI session 场景发送带 display index 的 `DisplayResolution`；旧版本按现有兼容分支发送单一 `Resolution`。
2. 请求需要有 pending 状态、超时和取消 epoch；用户快速连续选择时，旧请求不能在新请求之后回写状态。
3. 以实际收到的视频帧尺寸作为最终渲染尺寸，不以按钮点击值作为唯一事实。远端可能裁剪、取整、拒绝或按 DPI/虚拟显示器规则返回不同尺寸。
4. 收到新帧后同步 native GL surface、ArkTS 的 `remoteWidth/remoteHeight`、viewport、黑边计算、远端光标和鼠标/触摸坐标。
5. 切换期间保留旧帧或显示明确的“正在切换”状态；如果 RustDesk 发送 refresh-video，必须保持消息 oneof 的正确 variant，避免后续 setter 把刷新请求覆盖掉。
6. 会话关闭时验证远端是否按 agent 的既有策略恢复原始物理/虚拟显示分辨率；若未恢复，必须记录并提供用户可理解的提示，不能静默宣称完成。

### 4.3 物理显示器、虚拟显示器和权限

RustDesk 的“改分辨率”可能落到三类不同目标，测试和 UI 文案必须区分：

- **物理显示器**：受 Windows 显示设置、驱动和管理员权限限制，可能影响远端用户当前桌面。
- **RustDesk 虚拟显示器/IDD**：通常更适合远程控制，但依赖远端已安装并启用相应驱动，支持列表和行为与物理显示器不同。
- **多显示器**：需要先选择 display index；切换显示器后视频尺寸、坐标原点和远端光标都可能变化。

当远端没有权限、没有虚拟显示器、驱动不支持或服务端拒绝时，UI 应给出“远端不允许/未安装虚拟显示器/该版本不支持”等可行动原因，并继续允许本地缩放。远端分辨率功能失败不能连带禁用整个会话。

---

## 5. 共享本地缩放方案（Windows 式体验）

### 5.1 菜单与持久化

建议把设置中心和会话内菜单分成“默认值”和“临时覆盖”两层：设置中心的“显示与交互”卡片保存本机默认，RustDesk/RDP 协议卡片保存各自的远端策略；会话内显示菜单只修改当前连接，并提供“恢复设置默认值”。建议把当前“原始尺寸”改名为更明确的“100%”，避免用户把它理解为远端分辨率；“自定义缩放”必须真正有数值，而不是只有 Toast。

首版菜单：

- 适应窗口（Fit，保持比例并居中）；
- 100%；
- 125%；
- 150%；
- 175%；
- 200%；
- 自定义（建议 50%–300%，按 5% 或 10% 步长校验）；
- 可选扩展：225%、250%，仅在高 DPI/大窗口设备验证后开放。

旧状态迁移建议为：`原始尺寸 → 100%`，`适应窗口 → Fit`，没有有效数值的旧`自定义 → Fit`。显示模式和缩放值单独保存，不与远端分辨率 ID 共用字段。

设置页和会话菜单必须使用同一 `RemoteDisplaySettingsPolicy` 生成标题、当前值、作用域和禁用原因。设置页显示“默认：Fit/150%”，会话菜单显示“本次会话：150%（恢复设置默认值）”；双指产生的 `gestureScale/pan` 只能由会话状态保存，点击 Fit、重置画布或断开连接时清零。RustDesk 的远端分辨率和显示器列表则只在当前 Peer 能力枚举后出现在会话菜单的“远端显示”子区，不能用设置页的本地百分比选项代替。

### 5.2 统一 viewport 变换

必须建立一个同时被 GL 渲染器、ArkTS 叠加层和输入处理使用的 viewport/变换模型，不能只在 ArkUI 容器上调用 `.scale()`。模型至少包含：

```text
RemoteVideoGeometry {
  displayIndex
  pixelWidth / pixelHeight       // 当前实际渲染帧或解码输出尺寸
  logicalWidth / logicalHeight   // 远端输入坐标空间
  rotation                       // 0/90/180/270 或 unknown
  inputScale                     // Android half-scale 等逻辑到物理换算
  geometryEpoch                  // 显示/旋转/采集几何变化递增
  sourceKind                     // RDP / RustDesk / raw / decoded
}

ViewportState {
  baseMode: fit | original | fixed | custom
  baseScale: number
  gestureScale: number         // 双指临时比例，不写回设置
  zoom: number                 // baseScale × gestureScale；Fit 时由窗口和远端帧计算
  panX: number
  panY: number
  viewportWidth: number
  viewportHeight: number
  remoteWidth: number          // 等价于 RemoteVideoGeometry.logicalWidth
  remoteHeight: number         // 等价于 RemoteVideoGeometry.logicalHeight
  contentOriginX: number
  contentOriginY: number
  focalPoint: number, number
}
```

变换规则：

1. Fit：`zoom = min(viewportWidth / remoteWidth, viewportHeight / remoteHeight)`，内容居中，剩余区域为黑边或主题背景。
2. 固定百分比：`zoom = percentage / 100`，内容仍保持宽高比；小于 viewport 时居中，大于 viewport 时进入裁剪/平移模式。
3. 平移范围必须钳制：内容宽度超过 viewport 时，横向只能在可见范围内移动；内容没有超出时不产生无意义的平移。
4. 窗口调整、旋转、分屏、设备 DPI 变化、远端新帧尺寸变化和切换显示器都要重新计算 viewport，但尽量保持用户当前可见中心。
5. GL 纹理按收到的原始帧采样缩放，避免为每个百分比档位重复生成大 bitmap；高分辨率帧必须经过内存和纹理上限检查。

双指结束后推荐保留当前 `gestureScale/pan` 到当前连接结束，重新连接或点击 Fit 时清零；不把手势结果写回设置中的 Custom 值。这样设置缩放是持久化基线，双指是会话内临时操作。

双指焦点缩放必须满足“手指下的远端内容尽量不跳动”：先根据两指距离更新比例，再用两指中心的位移更新 pan，最后按内容尺寸与 viewport 尺寸 clamp。内容超过 viewport 时，双指中心移动承担 pan；内容未溢出时不产生无意义平移，也不能发送远端点击。

### 5.3 输入和远端光标

本地显示放大后，输入坐标不能继续使用当前只适用于 contain 的公式。统一定义正向和反向变换：

```text
remote → local:  local = contentOrigin + remote * zoom - pan
local  → remote:  remote = (local - contentOrigin + pan) / zoom
```

实际实现中，远端 rotation 的逆变换必须先于 `local → remote` 坐标换算；远端光标则按相反顺序投影回本地。pixel geometry 与 logical input geometry 可以不同，但必须由 `RemoteVideoGeometry` 显式表达，不能继续用隐式宽高交换代替 rotation。

在送入远端前要按远端帧边界取整并钳制。以下行为必须共用同一变换：

- 鼠标移动、点击、拖拽、滚轮；
- 触摸单指点击和拖动；
- 触控板相对移动/绝对定位转换；
- 远端光标显示、热点位置和显示器切换后的坐标原点；
- 选择框、拖放反馈和任何 ArkTS overlay。

建议把变换函数做成无 UI 副作用的纯测试单元，至少验证 Fit 黑边、100% 居中、200% 裁剪、四角点击、平移边界、远端尺寸变化和旋转/窗口变化后的 round-trip 误差不超过 1 个像素或一个明确的取整误差。

### 5.4 用户体验细节

- Fit、百分比和远端分辨率在菜单上分成两个小节，避免用户误以为 150% 会把远端 Windows 分辨率改成另一档。
- 进入固定百分比且内容大于窗口时，显示可平移提示；触摸拖动平移时不能误发送点击。
- 远端分辨率切换失败时不要自动改变本地缩放；本地缩放失败时回退 Fit，不影响会话连接。
- 文案显示“本地显示 150%”和“远端桌面 1920×1080”，两者同时显示时语义明确。
- 双指默认进入画布目标；进入固定百分比且内容溢出时，双指中心移动负责平移，不能误发送右键、滚轮或点击。
- 现有 touchpad 双指右键/滚轮必须迁移到显式触控板模式或独立入口；三指控制面板保留，但 pinch 已提交后不得再触发三指面板。
- 键盘快捷键、双击 Fit/100% 可作为后续增强；双指画布缩放属于本计划的第一版验收范围。

---

### 5.5 双指目标、手势仲裁与远端应用缩放

建议使用以下状态机，避免一次手势同时改变本地画布和远端应用：

```text
Idle
  ↓ 第二根手指落下
TwoFingerCandidate
  ├─ 画布目标 + 距离/中心超过阈值 → CanvasTransform
  ├─ 远端应用目标 + capability 已确认 → RemoteTouchScale
  └─ 取消/三指接管/连接结束 → Cancel → Idle
```

`TwoFingerCandidate` 阶段暂不发送右键、滚轮或远端 touch-scale；只有超过阈值后才提交目标。XComponent native touch 与 ArkTS overlay 必须由同一个 gesture owner 消费，并以 session/gesture id 防止重复转发。

远端应用目标的验收语义是：浏览器、图片、地图或文档内容发生缩放，远端系统窗口边界、远端显示分辨率和采集帧几何保持不变；本地 `CanvasTransform` 不跟随变化。

RustDesk 上游已有 `TouchScaleUpdate`，但它只有相对 scale 增量，没有双指焦点和两条触点轨迹。因此不能只在 HarmonyOS FFI 增加一个标量函数就宣称 Android pinch 完成。实施时必须：

1. 在 `rustdesk_ffi/src/lib.rs`、`control_inbox.rs`、`connector.rs` 增加可合并的 scale update，保证 start/end 可靠有序，并在 `rustdesk_bridge.cpp/.h` 暴露 FFI 入口。
2. 在 RustDesk Android server `connection.rs` 转发 scale start/update/end，在 `MainService.kt`/`InputService.kt` 实现真实多点手势注入。若标量协议不能表达焦点和触点轨迹，则增加向后兼容的 touch-scale 扩展字段/消息并进行版本协商。
3. 只有目标 peer 明确支持并通过真实 Android 应用验收后，才显示“远端应用”目标；旧 peer、无 Accessibility 权限或协议不兼容时降级为本地画布，并给出可见状态。

RDP 当前 `ProtocolAdapter`/FreeRDP 输入面只有键盘、鼠标和滚轮，没有通用 multi-touch API。RDP 本计划只承诺本地画布 pinch；FreeRDP 触控扩展或应用相关的 `Ctrl+wheel` 兼容动作需另行验证，不能当成通用远端应用缩放。

### 5.6 RustDesk Android portrait 诊断与修复方案

#### 根因优先级

| 优先级 | 候选根因 | 依据/判断 |
|---|---|---|
| 高 | FFI 连接时一次性读取 `peer_display_size()` 并把宽高盖到所有帧 | `rustdesk_ffi/src/lib.rs:820–845`、`:385–394`、`:401–424`；不能表达旋转后的实际帧尺寸 |
| 高 | Android 端按 configuration orientation 二次重排 max/min | `MainService.kt:258–310`；所有非 landscape 都按 portrait，可能造成宽高反转 |
| 高 | 只比较 `SCREEN_INFO.width` | height、scale、dpi 变化时不会重建采集，方向切换可能保留旧几何 |
| 中 | 控制端强制本地窗口横屏 | `RemoteDesktop.ets:1456`、`:3067`、`:3140–3158`；会掩盖远端 portrait，但不是远端旋转修复 |
| 中 | ImageReader 未传 pixel/row stride | `MainService.kt:350–379` 只传 buffer，可能造成裁剪/错位等旋转样假象 |
| 待验证 | Android 服务未在所有设备/版本收到 `onConfigurationChanged` | 需要方向切换日志和设备实测确认 |

#### 诊断探针与最小复现

在修复前建立同一时间轴日志：

- Android：configuration orientation、display rotation、原始 WindowMetrics bounds、归一化前后宽高、half-scale、dpi、`SCREEN_INFO`、VirtualDisplay、ImageReader width/height/pixelStride/rowStride、每次 stop/start 原因。
- RustDesk FFI/native：PeerInfo displays/current_display、连接时读取的尺寸、每个 geometry epoch、编码/解码帧尺寸、纹理尺寸、renderer viewport、surface 尺寸。
- ArkTS：`remoteWidth/remoteHeight`、viewport、`CanvasTransform`、输入点正逆映射、方向变化时序。

至少覆盖：连接前 portrait/landscape；连接后 portrait→landscape→reverse portrait；raw 与实际 codec；half-scale 切换；重连和后台恢复。若 PeerInfo、FFI、decoder 都是 portrait 而截图仍横向，转查 renderer/surface；若 FFI 已横向而 PeerInfo 仍 portrait，先修几何合同；若方向切换无新尺寸，先修 Android/FFI 更新。

#### 修复顺序

1. **统一帧几何合同**：实际编码/解码尺寸作为 pixel geometry；PeerInfo 作为 logical display/input 初始来源。增加 display、rotation、geometry epoch 传播；没有 wire rotation 字段时，不用强行交换宽高冒充 rotation。
2. **修正 FFI 更新时机**：不要在 `run_streaming()` 外捕获固定宽高并标记所有帧；使用 decoder 实际输出或 geometry event 更新 renderer、ArkTS、输入和远端光标。
3. **修正 Android 屏幕归一化**：同一套 WindowMetrics 与 Display rotation 得到物理方向；configuration orientation 仅作受控 fallback，明确处理 `ORIENTATION_UNDEFINED`，避免二次 max/min 交换。
4. **完整比较采集状态**：比较 width、height、scale、dpi、rotation；任何变化都按 stop old capture → rebuild ImageReader/VirtualDisplay/encoder → refresh → start new capture 的顺序处理，并发出新 epoch。
5. **修正 raw stride**：复制成紧密 RGBA，或随帧传递 pixel/row stride；不得用 `buffer.length / height` 隐式推断行宽。
6. **解除本地方向耦合**：控制窗口可以保留独立横屏策略，但 renderer 不得因本地横屏而旋转远端帧；如需窗口跟随远端方向，作为 geometry 驱动的独立策略。
7. **同步输入/光标**：同一 `RemoteVideoGeometry` 供 renderer、remoteWidth、输入矩阵、远端光标和光标热点使用；方向切换中丢弃旧 epoch 帧/触摸。

### 5.7 实现文件与责任边界

| 文件/目录 | 责任 | 主要产出 |
|---|---|---|
| `entry/src/main/ets/pages/HostListPage.ets` | 设置中心共享“显示与交互”区、RDP 预设分组、RustDesk 能力状态卡、旧值迁移和 `pc/pad/phone` 布局 | `ResolutionChoice`、显示默认值和协议设置入口 |
| `entry/src/main/ets/pages/RemoteDesktop.ets` | 会话状态、gesture owner、双指状态机、输入/光标正逆变换 | `CanvasTransform`、`PinchTarget`、session/gesture epoch |
| `entry/src/main/ets/services/RemoteDisplaySettingsPolicy.ets` | 显示/缩放设置 ID、默认值、作用域、设备布局、文案和设置默认值恢复 | 设置页与会话菜单共用的显示策略模型 |
| `entry/src/main/ets/services/RemoteGestureSettingsPolicy.ets` | 双指目标、开关、重置策略、协议能力门控和禁用原因 | `PinchTarget` 的设置级默认与会话级可用性 |
| `entry/src/main/ets/services/ExtensionLoader.ets`、`entry/src/main/ets/types/rdpnapi.d.ts` | ArkTS/native geometry 与 renderer viewport API | 类型化 `RemoteVideoGeometry`/viewport 查询或事件 |
| `entry/src/main/cpp/render/gl_renderer.h/.cpp` | GL 等比缩放、裁剪、pan、纹理和 surface resize | renderer 级 transform 与 viewport snapshot |
| `entry/src/main/cpp/extensions/protocol_adapter.h` | 跨协议输入、视频几何和能力边界 | 不把 RDP/RustDesk 特有语义泄露给通用画布层 |
| `rustdesk_ffi/src/lib.rs`、`control_inbox.rs`、`connector.rs`、`protocol/session.rs` | RustDesk FFI frame geometry、PeerInfo、分辨率/scale control、epoch/错误 | FFI C ABI、消息序列化和 control queue |
| `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h` | Rust FFI 与 ArkTS/native 之间的 C++ 桥 | remote resolution、touch-scale、geometry callback |
| `rustdesk_vendor/src/server/connection.rs`、`input_service.rs` | RustDesk peer 端分辨率与 Android touch-scale 分发 | capability/version 分支和 Android scale start/update/end |
| `rustdesk_vendor/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt`、`InputService.kt`、`common.kt` | Android 屏幕几何、采集重建、stride 和 Accessibility 多点注入 | portrait geometry epoch 与真实远端 pinch |
| `entry/src/test/`、`entry/src/main/cpp/test/`、`rustdesk_ffi` tests | 纯变换、手势仲裁、FFI queue、geometry/stride | 可重复的 host/native/ArkTS 证据 |

---

## 6. 分阶段实施计划

### 阶段 0：基线、构建门禁和协议确认

**目标**：把当前审查结论变成可重复的基线，避免在 fallback 或错误设备上开发。

**工作项**：

1. 固定真实 FreeRDP 构建参数，记录 arm64-v8a/x86_64 的产物和版本。
2. 为当前四档 RDP 建立连接日志和真机验收记录。
3. 确认 RustDesk vendor proto、`PeerInfo`、`SupportedResolutions`、`Misc` oneof 和版本兼容分支。
4. 确认当前 GL renderer、ArkTS surface、输入和远端光标的尺寸来源。
5. 完成 RustDesk Android portrait 诊断探针：PeerInfo、FFI、decoder、renderer、surface、Android capture 的同时间轴尺寸/方向/stride 记录。
6. 盘点设置中心的现有 PC 侧栏、手机/Pad 设置 Tab、RDP/RustDesk 折叠区和会话内 `RemoteSessionTopBar`，固定“显示与交互 / Windows RDP / RustDesk”三类信息架构、作用域和文案。
7. 增加设计阶段使用的 feature flag 方案：RustDesk 远端分辨率默认关闭；本地新缩放失败时可强制 Fit；远端 touch-scale、Android geometry v2 和设置布局 v2 单独灰度。

**退出条件**：四档 RDP 的实际输入值可追踪；RustDesk 的目标 Peer 版本、显示器和权限样本齐全；设置项的协议归属、保存范围和 Phone/Pad/PC 布局已冻结；当前行为已有可回退基线。

### 阶段 1：统一预设模型与 RDP 扩展

**目标**：以稳定 ID 替代整数挡位，保留旧配置兼容，并将目录扩展到 10 个以上。

**工作项**：

1. 建立共享 `ResolutionPreset`/`ResolutionChoice` 模型和纯校验函数。
2. 迁移旧值 0–3，保留原有默认行为和已有主机配置。
3. 加入 17 个标准尺寸、Auto 和受控 Custom；按比例分组、搜索或可滚动展示。
4. RDP 连接前执行最大边长、像素面积、偶数尺寸和 native ABI 校验。
5. 明确 Auto 的计算和日志语义；新尺寸先按连接初始化生效。
6. 在 `HostListPage.ets` 的 Windows RDP 设置区将四挡滑块替换为 Auto、分组标准目录和受控 Custom；PC 使用网格/两列，Phone 使用可滚动 Sheet，Pad 使用单列分组卡片。
7. 在真实 Windows 主机上验收代表性比例和 4K；只有通过后才考虑允许更多高分档。

**退出条件**：旧配置无损迁移；至少 11 个标准尺寸可选择并能正确传递；不支持的尺寸会在连接前说明原因；RDP 设置区在三类设备可完成选择/取消/恢复默认；RDP 四档回归通过。

### 阶段 2：共享本地缩放、画布双指缩放和坐标变换

**目标**：让菜单里的 Fit、100% 和百分比真正改变画面，并加入默认面向画布的双指 zoom/pan，保证交互不偏移。

**工作项**：

1. 建立 `ViewportState` 和纯变换/平移约束模块。
2. 让 GL renderer 使用 Fit 或固定 zoom；保持 letterbox，不做默认拉伸。
3. 让 ArkTS 的输入、光标和 overlay 使用同一变换结果。
4. 接入窗口大小、设备旋转、远端新帧尺寸和多显示器切换事件。
5. 实现 100/125/150/175/200%，再开放 Custom；旧“原始尺寸/自定义”状态按迁移规则处理。
6. 在 `RemoteDesktop.ets` 实现 `Idle → TwoFingerCandidate → CanvasTransform/Cancel` 状态机；双指距离更新 zoom、中心移动更新 pan，焦点保持并 clamp 到内容边界。
7. 确定 XComponent/native 与 ArkTS overlay 的唯一 gesture owner，阻止重复转发；三指面板保留，现有双指右键/滚轮迁移到显式触控板模式或独立入口。
8. 在 `HostListPage.ets` 增加共享“显示与交互”设置区：本地 Fit/百分比/Custom、双指开关/默认目标、溢出滚动说明、重置策略和 Auto 方向；在 `RemoteDesktop.ets` 会话菜单增加临时覆盖与“恢复设置默认值”。
9. 完成触摸平移与点击冲突处理；触控板和鼠标继续沿用相对/绝对语义，但统一进行边界校验。

**退出条件**：画面模式不再只有 Toast；所有固定缩放档都可观察到实际变化；双指只改变本地画布且能查看溢出内容；设置默认和会话临时覆盖语义一致；坐标 round-trip、黑边、裁剪、平移和窗口变化测试通过；出现异常时可一键回退 Fit。

### 阶段 3：RustDesk 远端分辨率

**目标**：把已有 RustDesk vendor 分辨率协议能力安全接入 HarmonyOS UI。

**工作项**：

1. 解析 `PeerInfo` 的 displays、current display 和 supported resolutions。
2. 设计 FFI 的查询/事件 API，附带 session epoch 和错误状态。
3. 按 Peer 能力生成候选列表；不支持的本地标准尺寸不能显示为可点击成功项。
4. 通过 `change_display_resolution`/兼容的 `change_resolution` 发送请求，加入 pending、超时、取消和错误回退。
5. 以新视频帧尺寸驱动 renderer、viewport、输入和远端光标更新。
6. 在 RustDesk 设置区增加“连接后按能力显示”策略、显示器/分辨率说明和不可用原因；当前 Peer 的实时列表放在会话显示菜单，不在离线设置页硬编码成功选项。
7. 验证物理显示器、RustDesk 虚拟显示器、多显示器、旧版本 Peer、Pro/OSS、直连/中继以及远端权限拒绝。
8. 连接结束时验证原始分辨率恢复；必要时保留原始显示快照和恢复失败提示。

**退出条件**：新版本 Peer 可以完成枚举、选择、切换、收到新帧和交互；RustDesk 设置区和会话菜单对能力状态、当前显示器和失败原因一致；旧版本/无权限/无驱动场景有清晰的禁用或失败提示；失败不会导致黑屏或错误坐标。

### 阶段 4：RustDesk 远端应用内部缩放

**目标**：在能力协商成功的 RustDesk Android peer 上，实现“远端应用内容缩放、远端窗口与采集尺寸不变”；不把本地画布 zoom 误报为远端应用缩放。

**工作项**：

1. 在 `rustdesk_ffi/src/lib.rs`、`rustdesk_ffi/src/control_inbox.rs`、`rustdesk_ffi/src/connector.rs` 增加 scale control；高频 update 合并，start/end 可靠有序。
2. 在 `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h` 增加 FFI 入口和 capability/error 返回，未确认能力时不发送或明确降级。
3. 复用现有 `TouchScaleUpdate` 验证桌面 peer；对 Android 评估其只有 delta scale、没有 focal point/双触点轨迹的限制。
4. 在 `rustdesk_vendor/src/server/connection.rs` 转发 Android scale start/update/end，在 `rustdesk_vendor/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt`/`InputService.kt` 实现真实多点手势注入；若现有消息不能表达焦点，则增加向后兼容的扩展字段/消息并做版本协商。
5. 在 RustDesk 设置区增加远端应用缩放的安全开关和能力说明；在共享“双指操作”区显示默认目标，但只有当前 RustDesk 会话通过 capability/权限后才允许切换到“远端应用”。
6. 只有 capability、权限和真实 Android 应用矩阵通过后，会话控制条才显示“远端应用”目标；旧 peer、无 Accessibility 权限、relay/direct 不兼容时降级为画布目标。
7. RDP 继续只承诺本地画布 pinch；单独验证 FreeRDP touch/gesture channel，`Ctrl+wheel` 仅作为显式应用相关兼容动作，不作为通用远端 pinch。

**退出条件**：支持的 RustDesk Android 版本上，浏览器/图片/地图/PDF 等应用内容改变而窗口边界、远端显示分辨率、采集帧几何和本地 CanvasTransform 保持不变；设置区、会话菜单和能力状态文案一致；旧 peer 有可见降级；一次手势不会同时改变本地画布。

### 阶段 5：RustDesk Android portrait 几何修复

**目标**：修复 portrait/landscape 的帧几何、方向、采集 stride、renderer viewport、输入和远端光标同步，不用本地强制横屏掩盖问题。

**工作项**：

1. 修正 `rustdesk_ffi/src/lib.rs` 的固定 `peer_display_size()` 传播，以实际编码/解码尺寸作为 pixel geometry，PeerInfo 作为 logical display/input 来源。
2. 增加 display、rotation、geometry epoch 的 FFI/native/ArkTS 传播；没有 wire rotation 字段时，不用隐式交换宽高替代 rotation。
3. 重写 Android `MainService.kt:updateScreenInfo()` 的 WindowMetrics/Display rotation 归一化，明确处理 `ORIENTATION_UNDEFINED`，比较 width、height、scale、dpi、rotation 全字段。
4. 任一采集几何变化时按 stop old capture → rebuild ImageReader/VirtualDisplay/encoder → refresh → start new capture 的顺序处理，并将新 epoch 传到 renderer、ArkTS、输入和光标。
5. 修复 raw ImageReader 的 pixel/row stride 合同：紧密复制或传 stride 元数据，禁止由 buffer 长度隐式推断行宽。
6. 将控制窗口方向和远端帧方向解耦；portrait、landscape、reverse portrait 均由远端 geometry 正确 contain；方向切换时丢弃旧 epoch 帧和触摸。
7. 在共享“显示与交互”设置区只提供“自动适配/跟随远端”的产品级方向策略（默认自动适配）；不提供强制横屏、交换宽高或手工 rotation 入口，并让会话菜单显示当前方向来源。
8. 设备实测后再决定是否提供“控制窗口跟随远端方向”策略；该策略不得影响远端 portrait 正确渲染。

**预计涉及文件**：`rustdesk_ffi/src/lib.rs`、`rustdesk_ffi/src/connector.rs`、`entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`、`entry/src/main/cpp/render/gl_renderer.h/.cpp`、`entry/src/main/ets/pages/RemoteDesktop.ets`、`entry/src/main/ets/types/rdpnapi.d.ts`、Android `MainService.kt`/`InputService.kt`，以及必要的协议生成/合规文件。

**退出条件**：连接前/后 portrait、landscape、reverse portrait 都能正确显示比例；方向切换不使用旧尺寸；无旋转、镜像、裁剪、stride 错位和输入坐标偏移；本地画布缩放不改变远端窗口尺寸。

### 阶段 6：真机矩阵、性能和发布验收

**目标**：证明高分辨率和缩放在实际 HarmonyOS 设备及不同远端环境下稳定。

**工作项**：

1. 覆盖 HarmonyOS PC、Phone、Pad，窗口化、全屏、分屏、旋转和不同 DPI。
2. 覆盖 Windows RDP 主机和 RustDesk 物理/虚拟/多显示器目标。
3. 做低分辨率、4:3、16:9、16:10、21:9、4K 代表性组合，不要求测试人员手工穷举所有组合，但每个目录值都要通过模型校验。
4. 进行双指画布焦点缩放、四边 pan、三指控制面板、旧双指右键/滚轮模式的冲突和取消测试。
5. 对 RustDesk Android 验证应用内部缩放时远端窗口/采集帧尺寸不变，并覆盖 portrait、landscape、reverse portrait、half-scale、raw/codec、重连和旋转中断。
6. 验证设置中心在 PC/Pad/Phone 的分类布局、17 个预设可发现性、触控区域、Sheet 返回/取消、默认值恢复，以及 RDP/RustDesk/共享区没有重复或错放入口。
7. 验证重连、网络抖动、切换失败、首帧刷新、长时间播放和内存压力测试。
8. 收集首帧时间、帧率、端到端输入延迟、CPU/GPU、内存峰值、切换耗时和黑屏/花屏次数。

**退出条件**：发布门禁、设备矩阵、性能基线、回滚演练和用户文案审查全部完成，且没有未解释的分辨率/缩放状态不一致。

---

## 7. 测试与验收矩阵

### 7.1 纯逻辑和 ArkTS 测试

- 预设目录：ID 唯一性、尺寸校验、偶数规则、分组、过滤、旧值迁移、未知值回退。
- RDP 映射：四个旧档和新增目录映射到正确的宽高；Auto 不被误当作固定尺寸。
- RustDesk 能力：PeerInfo displays/resolutions 解析、空列表、旧版本字段缺失、多显示器当前项和远端错误。
- 请求状态：快速连点、超时、取消、重连 epoch、旧响应晚到、切换后刷新帧。
- viewport：Fit、100%、125%、150%、175%、200%、Custom、黑边、裁剪、平移钳制、窗口变化和远端尺寸变化。
- 输入：鼠标、触摸、触控板、远端光标、四角和黑边点击不应产生越界或偏移。
- 画布手势：焦点保持、双指平移、溢出内容四边、`TwoFingerCandidate` 取消、双指与三指面板/右键/滚轮仲裁、native/ArkTS 重复事件防护。
- 几何变换：0/90/180/270 rotation、pixel/logical geometry、geometry epoch、输入与远端光标 round-trip。
- 设置布局：共享“显示与交互”只出现一次；RDP 远端预设只能出现在 RDP 区；RustDesk 显示器/能力/远端应用缩放只能出现在 RustDesk 区；默认值、主机偏好和会话临时覆盖的读取/恢复范围正确。
- 响应式 UI：PC 分栏/网格、Pad 单列分组卡片、Phone 底部 Sheet/可滚动预设列表均能完成选择、取消、非法值提示、禁用原因和恢复默认；设置页与会话菜单文案一致。

### 7.2 Native/Rust/构建验证

- 复用并扩展 RustDesk FFI host tests，覆盖 `PeerInfo`、版本分支、`change_display_resolution` oneof、错误和取消。
- 增加 RustDesk scale control queue/oneof 测试，覆盖高频 update 合并、start/end 有序、旧 session 丢弃、Android capability 降级。
- 增加 native GL viewport/纹理尺寸测试；确认 4K 纹理、surface resize 和 fallback 不会破坏已有视频路径。
- 增加 Android geometry/stride 解析测试，确认 width、height、scale、dpi、rotation 任一变化都触发新 epoch，且不会用固定 PeerInfo 尺寸覆盖实际帧。
- 生产 `assembleHap` 必须使用 `USE_REAL_FREERDP=ON` 的真实 FreeRDP 链路；arm64-v8a 与 x86_64 都要检查。
- 运行项目规定的 `default@OhosTestCompileArkTS`、受影响 native/Rust 测试、`git diff --check` 和 Light 合规门。
- 不把默认 CMake 的 `USE_REAL_FREERDP=OFF` skeleton 构建当作 RDP 分辨率通过证据。

### 7.3 远端和真机矩阵

| 维度 | 最低覆盖 |
|---|---|
| RDP 主机 | Windows 10、Windows 11、至少一个 Windows Server；NLA、重连、服务端拒绝高尺寸 |
| RustDesk 主机 | 当前支持的新版 Peer、至少一个旧版 Peer；OSS/Pro；直连/中继 |
| 显示目标 | 单物理显示器、RustDesk 虚拟显示器、多显示器、无权限/无驱动 |
| 预设比例 | 4:3、5:4、16:9、16:10、21:9、4K；至少覆盖现有 4 档和新增目录的每个分组 |
| 客户端设备 | HarmonyOS PC、Phone、Pad；窗口调整、全屏、分屏、旋转、不同 DPI |
| 缩放档位 | Fit、100%、125%、150%、175%、200%、Custom 边界值和非法值；双指画布 zoom/pan |
| 设置布局 | PC 设置分类分栏、Pad/Phone 折叠区和底部 Sheet；共享/RDP/RustDesk 归属、禁用原因、默认值恢复和会话临时覆盖 |
| RustDesk Android 应用 | 浏览器、图片、地图、PDF；支持/不支持 touch-scale、无 Accessibility 权限、direct/relay |
| Android 方向 | portrait、landscape、reverse portrait；连接前后旋转、half-scale、WindowMetrics/stride |
| 稳定性 | 首帧、重连、分辨率切换、输入、远端光标、30 分钟 4K/高缩放压力 |

建议的发布验收标准：

1. UI 选择、native/Rust 日志、远端实际尺寸和本地显示文案四者一致；如果远端主动取整或拒绝，必须明确显示最终状态。
2. 分辨率切换成功后第一帧不黑屏，viewport 和输入在新尺寸下立即正确；切换失败保留旧画面或明确恢复。
3. 输入映射在四角、黑边、放大裁剪和平移边界的 round-trip 误差不超过 1 个像素或已定义的取整误差。
4. 同一远端帧在 Fit 和固定缩放下的远端坐标语义不变；本地缩放不得意外触发远端 resize。
5. 4K 和 200% 场景无崩溃、无持续黑屏、无不可恢复的 surface 泄漏；性能相对同一基线的退化要有记录和解释。
6. 旧配置、旧 Peer、无权限主机和 fallback 错误都能安全回退，不会因为一个新功能让原有 RDP/RustDesk 会话无法连接。

---

## 8. 风险、灰度和回滚

### 8.1 主要风险

- **RDP Auto 语义不清**：窗口尺寸、设备 DPI 和远端桌面尺寸可能被混用。必须先固定定义并在日志中同时记录请求值、实际值和帧值。
- **误用 FreeRDP fallback**：未打开真实宏时连接看似建立但分辨率不代表真实 FreeRDP。构建门禁必须阻断这种误判。
- **高分辨率资源压力**：4K 帧、解码、纹理、surface 和缩放同时发生时会放大内存峰值。需要逐设备测量并限制危险组合。
- **RustDesk 远端副作用**：改变物理显示器可能影响远端用户，虚拟显示器可能缺驱动，多显示器可能改变坐标原点。入口必须显示目标显示器和权限状态。
- **协议版本差异**：旧 Peer 可能没有支持列表或只认识旧 oneof。必须按版本/能力降级，不能假设所有 RustDesk 目标一致。
- **帧与 UI 状态竞态**：请求成功、旧帧、重连和新 session 同时到达时容易黑屏或显示错误尺寸。所有异步事件必须带 session epoch/请求序号。
- **缩放后的输入偏移**：只改画面、不改输入会造成严重误操作。渲染、overlay、鼠标、触摸、触控板和远端光标必须共用变换。
- **双指手势冲突**：现有双指右键/滚轮/直接触控与画布 pinch 不能并行消费；必须使用目标模式、候选阈值和唯一 gesture owner。
- **远端应用缩放能力不足**：RustDesk `TouchScaleUpdate` 只有 delta scale；Android server/input 端当前不处理它，AccessibilityService 的多点注入还需真实设备验证，未完成前不得显示成功入口。
- **Android 方向元数据缺失**：固定 PeerInfo 尺寸、无 rotation/epoch、orientation 二次重排和 raw stride 可能互相叠加；必须先采证再修复，不能用本地横屏或强制交换宽高掩盖。
- **用户认知混乱**：远端分辨率和本地缩放名称相似。菜单分组、当前状态文案和失败提示必须明确写出“远端/本地”。
- **设置入口重复或错放**：若把本地缩放复制到 RDP、RustDesk 两个区，或把 RustDesk 的实时能力列表硬编码进离线设置，用户会得到互相矛盾的状态。必须由共享设置策略生成入口，协议区只拥有协议专属能力，会话菜单只拥有临时覆盖。
- **响应式布局挤压**：17 个预设、能力状态和禁用说明在 Phone 上可能造成过小点击区域或滚动冲突；必须按设备断点使用网格、卡片和 Sheet，并把 UI 矩阵纳入发布门禁。

### 8.2 建议的灰度开关

建议分别设置：

- `rdp_extended_resolution_presets`：预设模型及新增尺寸；关闭时保留原四档。
- `local_view_scale`：Fit/百分比缩放；任何变换异常都能回退 Fit。
- `rustdesk_remote_resolution`：PeerInfo 枚举和远端 resize；首版默认关闭，先对白名单设备/测试账号开放。
- `canvas_gesture_zoom_enabled`：双指画布 zoom/pan；关闭时恢复旧双指输入语义。
- `remote_touch_scale_enabled`：RustDesk 远端应用 scale；默认关闭，只有 capability、权限和设备矩阵通过后开放。
- `rustdesk_android_geometry_v2`：新 frame geometry/rotation/stride/epoch 合同；异常时回退 Fit/旧渲染路径并保留诊断日志。
- `remote_display_settings_layout_v2`：共享显示与交互区、协议专属远端显示区和会话菜单默认/临时覆盖协同；关闭时保留现有设置入口和兼容值，不删除已保存数据。

开关关闭时，已有持久化值不删除，只在运行时回退到兼容默认；重新打开后可继续使用。日志只记录协议、尺寸、显示器索引、结果和耗时，不记录账号、密码、token 或远端文件内容。

### 8.3 回滚方案

1. RustDesk resize 出现远端副作用时，立即关闭 RustDesk 开关，继续提供本地 Fit/百分比；不回滚整个连接协议。
2. 本地 viewport/画布手势出现输入偏移时，关闭 `canvas_gesture_zoom_enabled`、强制 `Fit` 并保留旧 contain 公式作为临时兼容路径。
3. 新预设造成服务端兼容问题时，关闭扩展目录，旧 ID 仍映射到 Auto/1920×1080/2560×1440/3840×2160。
4. Android geometry v2 或 stride 异常时，关闭 `rustdesk_android_geometry_v2`，退回安全 Fit/旧渲染路径并保留诊断日志；不得回退到隐式宽高交换。
5. 远端 touch-scale 不可用时，关闭 `remote_touch_scale_enabled`，仅保留画布目标；不能把事件静默吞掉后显示成功。
6. 任何升级/迁移失败都不能清空主机配置；未知值回退并记录原因。
7. 在发布前演练“切换失败、连接中断、重连、应用重启、远端旋转、权限撤销”恢复，确认远端显示器能按 RustDesk agent 策略恢复。

---

## 9. 待确认的产品决策

以下问题不影响当前审查结论，但进入实施前需要产品/技术负责人确认：

1. RDP 是否只要求“下一次连接生效”，还是必须支持连接中热切换；建议首版只承诺连接初始化，热切换单独立项。
2. 本地缩放默认值是全局记忆还是按主机记忆；建议首版本地设备记忆最近选择，不同步到云端。
3. RustDesk 是否允许改变远端物理显示器；建议默认优先列出虚拟显示器，物理显示器须显示影响提示并依赖远端授权。
4. Custom 远端分辨率是否首版开放；建议先开放 17 个标准尺寸，Custom 等 PeerInfo/权限/性能稳定后再开放。
5. 250% 及以上本地缩放是否需要支持；建议先以 200% 为发布门槛，依据 PC/Pad 高 DPI 真机结果决定是否放开 225%/250%。
6. 双指默认目标是否确定为“画布”；建议默认画布，远端应用目标通过控制条显式切换，避免一次手势同时改变本地和远端状态。
7. RustDesk Android 远端应用缩放是否接受新增协议/安卓注入链路；若不接受，首版只能交付本地画布缩放，不能把现有 scale 协议入口包装成已支持。
8. 控制端窗口是否继续默认横屏；无论本地窗口策略如何选择，远端 portrait 都必须由远端 geometry 正确渲染，二者不能互相替代。
9. 设置中心是否在 PC 使用独立的三项分栏导航；建议 PC 使用“显示与交互 / Windows RDP / RustDesk”分栏，Pad/Phone 保持设置底部 Tab + 折叠区，避免小屏嵌套 Tab。
10. 远端应用缩放是否允许在离线设置页显示可用开关；建议离线只保存安全偏好，实时可用性由当前 RustDesk Peer 能力、权限和版本决定，设置页和会话菜单都必须显示该条件。

---

## 10. 完成定义

本计划对应的功能任务只有在以下条件全部满足后，才能对外宣称完成：

- RDP 现有四档和新增目录都有真实 FreeRDP/真实 Windows 主机证据；
- RustDesk 只对已枚举、已授权、兼容的显示器和分辨率提供成功路径，旧版本和失败路径有明确降级；
- 本地 Fit、100%、百分比和自定义缩放确实改变画面，并且输入、远端光标、黑边、裁剪和平移一致；
- 双指画布缩放能够在远端画布溢出时保持焦点、平移到边界且不误发远端输入；设置缩放和手势缩放状态独立；
- RustDesk Android 只有在能力协商、协议、服务端和 AccessibilityService 注入链路全部通过后，才宣称远端应用内部缩放可用；远端窗口和采集尺寸保持不变；
- RustDesk Android portrait/landscape/reverse portrait 的 frame geometry、rotation、stride、renderer、输入和远端光标一致，方向切换不使用旧 epoch；
- 设置中心在 PC/Pad/Phone 都能按“显示与交互 / Windows RDP / RustDesk”找到对应功能；本地和远端状态、保存范围、禁用原因、会话临时覆盖和恢复默认行为一致，且没有把技术性 rotation/stride 选项暴露给用户；
- 旧配置迁移、session epoch、重连、失败恢复、4K 资源压力和 30 分钟稳定性通过；
- ArkTS、native、Rust FFI、HAP 构建、真机矩阵和 Light 合规门均通过；
- 用户文案清楚区分“远端分辨率”和“本地缩放”，并且灰度/回滚已演练。

当前阶段的完成状态仅为：**原计划、双指画布/远端应用缩放、Android portrait 方案和设置中心布局已合并为 v2.1 总计划；未修改功能代码，未声称新增功能已经可用。**
