# VNC 协议升级设计

更新日期：2026-07-15

## 1. 目标

在不改变 RDP、RustDesk、SSH/SFTP 行为的前提下，将当前 VNC mock 升级为可持续演进的真实 VNC 客户端。首个可交付目标是在可信局域网内，通过 macOS 官方“VNC 使用者可使用密码控制屏幕”模式连接 Mac，显示桌面并完成键鼠控制。

首期必须形成长期基线，而不是只为某一台 Mac 编写一次性握手代码。后续应能在同一架构上逐步增加 macOS 账户认证、主流 VNC 服务端、TLS/VeNCrypt、更多编码、文本剪贴板、网关、Repeater 和公开厂商扩展。

## 2. 当前事实

- `entry/src/main/cpp/vnc/vnc_adapter.cpp` 当前明确拒绝连接，没有 RFB、认证、framebuffer 或输入实现。
- VNC 已注册到协议扩展系统，`RemoteDesktop.ets` 也能识别 `RemoteProtocol.vnc`。
- `RemoteSessionCapabilityPolicy.ets` 正确地将当前 VNC 连接与扩展能力标为不可用。
- `RemoteHost` 已有通用 host、port、username、password 和 displayConfig 字段，首期不需要新增云表。
- `RendererNapi` 已提供 generation-safe 的 BGRA 全帧与脏矩形提交接口，可复用现有 GLRenderer。
- 当前 encoded `VideoFrameCallback` 会进入 H.264/VPx decoder，不适用于 VNC raw framebuffer。
- RustDesk 中继数据模型专用于 ID Server、Relay Server、API Server、账户和 Key，不能复用为普通 VNC 主机。

## 3. 产品范围

### 3.1 首期 V1

- 直接连接 IP/DNS 和 TCP 端口，默认 5900。
- 协商 RFB 3.3、3.7、3.8。
- 支持独立 VNC 密码认证。
- 连接 macOS 内置 Screen Sharing/Remote Management 的 VNC 兼容入口。
- 接收 framebuffer，输出 BGRA，完成首帧、增量刷新和尺寸变化。
- 支持鼠标移动、左右中键、滚轮和基础键盘输入。
- 支持客户端缩放、保持比例、平移和 view-only。
- 支持显式断开、异常断开、重连、Home/前后台恢复。
- 只在协商成功且运行时 ready 后开放对应能力。

### 3.2 紧随其后的 V1.5

- 探测 Apple ARD security types。
- 支持经过验证的 macOS 用户名/账户密码认证类型。
- 将 macOS 账户认证与独立 VNC 密码建模为不同 auth mode。
- 系统账户凭据必须进入现有安全存储、备份和云同步边界审计。
- 不支持的 Apple auth type 必须明确报错或回退到用户已配置的 VNC 密码，不得静默降级认证强度。

### 3.3 明确不属于首期

- Apple High Performance Screen Sharing。
- Apple 虚拟显示器、HDR、立体声音频、物理屏幕隐私遮蔽。
- Apple 高性能模式提供的真正动态分辨率。
- 文件传输、音频、云账号、厂商私有云连接。
- UltraVNC Repeater、reverse/listen mode、SSH tunnel。
- RealVNC 私有 RFB6 或未公开扩展。

这些能力可以进入后续研究或扩展阶段，但不得作为标准 RFB V1 的隐含承诺。

## 4. 方案决策

### 4.1 采用受控 LibVNCClient engine

首个 engine 使用 LibVNCClient，原因是它提供 C API、CMake 构建和成熟 RFB client 基础，不依赖桌面 UI。只构建 client 所需代码，不引入 server、示例 viewer 或 HTTP server。

依赖必须固定到包含所需安全修复的明确 commit。仓库需要记录上游地址、commit、源码哈希、构建参数、双 ABI 产物哈希、许可证、NOTICE、SBOM 和已知安全公告。由于上游安全策略主要在 master 修复问题，不能长期停留在未经审计的旧 release archive。

### 4.2 不直接绑定第三方类型

`rfbClient*`、LibVNCClient callbacks 和第三方枚举只能出现在 `LibVncEngine` 内。ArkTS、NAPI、`VncAdapter`、renderer 和测试不得依赖第三方结构体。

如果未来需要更换协议库、引入 Apple 认证 engine 或对某个厂商做独立兼容，替换范围必须限制在 engine/security/extension 层。

### 4.3 不采用的路线

- TigerVNC viewer core：依赖 FLTK、pixman、GnuTLS/nettle、libjpeg-turbo 等桌面栈，首期 HarmonyOS 移植面积过大。
- 自研 RFB client：认证、编码、边界检查和安全修复全部由项目承担，不符合首期风险目标。

## 5. 分层架构

```text
RemoteHost / HostListPage
        |
        v
ExtensionLoader / ConnectionConfig
        |
        v
VncAdapter
  `-- VncSession
      |-- IVncEngine
      |    `-- LibVncEngine
      |-- IVncTransport
      |    `-- DirectTcpTransport (V1)
      |-- VncSecurityCoordinator
      |-- VncCapabilityNegotiator
      |-- VncFramebuffer
      |-- VncFramePump
      |-- VncInputMapper
      |-- VncClipboardBridge
      `-- VncDiagnostics
               |
               v
      RendererNapi raw BGRA generation gate
               |
               v
            GLRenderer
```

### 5.1 IVncEngine

项目自有 engine 接口负责：

- 初始化协议实例。
- 通过 transport 建立和关闭连接。
- 协商 RFB version、security types 和 encodings。
- 驱动一次或一批 server messages。
- 发送 pointer、key、clipboard 和 framebuffer update request。
- 把协商结果、pixel rectangles、cursor、clipboard 和错误转换为项目自有事件。

首期接口需要支持同步测试 engine 和异步生产 engine。测试可注入 scripted engine，不依赖真实网络。

### 5.2 Transport

Transport 只提供连接、读写、取消、超时和 peer endpoint，不理解 RFB message。V1 使用直连 TCP；后续 TLS、SSH tunnel、SOCKS/HTTP proxy、Repeater 和 reverse mode 通过新的 transport 实现接入。

网络线程必须可以被 `disconnect()` 主动唤醒。不得依赖无限阻塞 read，也不得在 ArkTS/UI 线程执行 connect、认证或 message loop。

### 5.3 Security/Auth

认证模式使用显式枚举，不根据 username 是否为空猜测：

- `vnc_password`
- `macos_account`（V1.5）
- `vencrypt`（后续）
- `x509`（后续）

协商规则采用 allowlist。服务端只提供不被策略允许的安全类型时连接失败，并展示服务端实际类型和用户可采取的安全配置步骤。

VNC 密码不得写日志。V1 在未加密连接前显示安全提示，默认只建议可信局域网或 VPN。不能把传统 VNC password 描述成端到端加密。

### 5.4 Encoding registry

所有 encoding 通过 registry 和 allowlist 管理。每个 decoder 声明：

- encoding ID 和名称。
- 输入数据上限。
- framebuffer 尺寸限制。
- 输出格式。
- 是否支持增量矩形、alpha/cursor 或 resize。
- 安全/fuzz 验证状态。

V1 优先启用 Raw、CopyRect，以及 Mac 实际协商所需且通过安全门的最小编码。ZRLE、Hextile、Tight、JPEG 和 cursor/desktop extensions 按独立测试结果逐个启用。

Tight 在固定依赖包含相关安全修复、项目 fuzz corpus 和恶意矩形测试通过前保持关闭。

### 5.5 Framebuffer pipeline

VNC engine 回调不能把临时 framebuffer 指针跨线程传递。`VncFramebuffer` 拥有尺寸受限的 BGRA staging buffer，并在 engine callback 内完成有界复制或解码。

提交规则：

- 第一帧、resize、surface generation 变化和前台恢复强制 full frame。
- 普通 rectangle update 合并为有界 dirty region。
- frame pump 采用 latest-frame replacement，不能让网络 callback 等待 GL swap。
- surface detached 时继续维护 staging，但不访问 GL。
- surface 恢复时从 staging 发布 full frame。
- 断连先停止新提交并失效 generation，再销毁 framebuffer。

渲染使用现有 `RendererNapi::PresentRawBgraActive` 和 `PresentRawBgraRectActive`。encoded decoder 继续只服务 RustDesk/H.264 路径。

### 5.6 Input

`VncInputMapper` 把项目统一输入转换为 RFB pointer/key events：

- 鼠标移动和按钮位掩码。
- 左、中、右键。
- 垂直滚轮；水平滚轮后续按 server capability 开放。
- HarmonyOS/项目 scancode 到 X11 keysym 的显式映射。
- 修饰键按下/释放配对。
- 断连时清理本地 pressed-state，不向新 session 重放旧事件。

V1 的文本输入先使用 keysym/Unicode 可表达范围。完整 IME 完成态输入和扩展 Unicode 兼容在 V2/V4 矩阵中验收。

### 5.7 Clipboard

V1 可以先保持关闭，直到 macOS 标准文本剪贴板双向路径真机通过。开放后只支持文本：

- local to remote：显式用户复制后发送 ClientCutText。
- remote to local：收到 ServerCutText 后进入现有 pasteboard 策略。
- 会话 generation 隔离，旧 clipboard event 不得进入新会话。
- 文本长度设上限，日志只记录长度和方向。

文件剪贴板不是标准 RFB 能力，不复用 RDP CLIPRDR 文件实现。

## 6. Capability 真值模型

VNC 建立连接后生成只读运行时快照：

```text
VncCapabilities
  rfbVersion
  serverName
  securityTypesAdvertised
  securityTypeSelected
  transportEncrypted
  encodingsAdvertised
  encodingsEnabled
  remoteCursor
  clipboardTextSend
  clipboardTextReceive
  desktopResize
  continuousUpdates
  fileTransferExtension
  repeater
  viewOnly
```

UI 能力必须来自该快照与本地策略的交集。未完成握手、功能未实现、服务端未协商或安全策略禁止时，按钮必须禁用并给出原因。

## 7. 主机与产品模型

### 7.1 添加主机

V1 基础字段：

- 名称。
- 协议 VNC。
- 地址。
- 端口，默认 5900。
- 认证方式，V1 固定为 VNC 密码。
- 独立 VNC 密码。
- 仅查看。
- 客户端缩放模式。

高级项在 capability 成熟后逐步加入 encoding preference、color depth、TLS、证书、proxy 和 gateway。不能提前显示无效开关。

### 7.2 中继/网关

普通 VNC Server 是远程主机，不进入 RustDesk 中继列表。V1 不修改 `RustDeskRelayConfig` 或 RustDeskRelayPage。

后续支持 Repeater/SSH tunnel 时，将现有页面升级为“服务器与网关”，并新增带类型的独立 gateway model：RustDesk infrastructure、VNC repeater、SSH tunnel。不同类型不共享凭据或字段。

### 7.3 数据与迁移

V1 复用 RemoteHost 的通用字段，不新增云表。默认端口、验证、JSON、本地备份、CloudStore 和 HostSyncService 必须接受 `protocol=vnc`。

V1.5 增加 auth mode 时使用向后兼容默认值：已有 VNC 主机默认为 `vnc_password`。迁移不得把已有 password 自动解释为 macOS 系统账户密码。

## 8. 生命周期与并发

状态机固定为：

```text
DISCONNECTED
  -> CONNECTING
  -> AUTHENTICATING
  -> CONNECTED
  -> DISCONNECTING
  -> DISCONNECTED

CONNECTING/AUTHENTICATING/CONNECTED
  -> ERROR
  -> DISCONNECTING
  -> DISCONNECTED
```

`CONNECTED` 只能在 protocol、security、ServerInit、framebuffer allocation 和 message loop 全部 ready 后发布。TCP connect 成功不等于 VNC connected。

断开顺序：

1. session generation 失效并停止接收新输入。
2. 停止 frame pump 和 renderer submission。
3. 取消 transport 阻塞读写。
4. join VNC worker。
5. 清空 engine callback。
6. 释放 LibVNCClient、framebuffer 和凭据临时副本。
7. 发布 DISCONNECTED。

VNC teardown 走现有异步 session teardown executor，UI 线程不能等待网络 worker。

## 9. 错误与诊断

错误采用稳定域和阶段码，不直接把第三方文本作为产品错误：

- `E-VNC-CONNECT-*`
- `E-VNC-RFB-VERSION-*`
- `E-VNC-SECURITY-*`
- `E-VNC-AUTH-*`
- `E-VNC-SERVER-INIT-*`
- `E-VNC-ENCODING-*`
- `E-VNC-FRAMEBUFFER-*`
- `E-VNC-INPUT-*`
- `E-VNC-DISCONNECT-*`

诊断允许记录 session id、阶段、耗时、RFB version、security type ID、encoding ID、尺寸、矩形数量、队列深度、丢弃/替换数和错误码。不得记录密码、系统用户名明文、剪贴板文本或屏幕像素。

用户可见错误需要区分：网络不可达、端口关闭、服务端不是 RFB、认证类型不支持、密码错误、服务端拒绝、framebuffer 超限、编码被安全策略禁用和连接后无首帧。

## 10. 安全边界

- V1 最大桌面边长与总像素使用项目常量约束，不能信任 ServerInit。
- 所有 `width * height * bytesPerPixel` 使用 checked arithmetic。
- rectangle 必须裁剪到 framebuffer，拒绝负值、溢出和越界 CopyRect。
- compressed payload、解压输出、矩形数量和 clipboard 长度都有硬上限。
- 连接超时、认证超时、首帧超时和断连 join 有明确门限。
- 密码只在连接期间进入 native 临时对象，使用后覆盖；不进入 hilog。
- 未加密 VNC 不允许在 UI 中显示“安全连接”。
- 默认不允许 `None` authentication；开发诊断开关不能进入公开构建。
- 依赖升级必须重新运行安全公告审计、fuzz corpus 和双 ABI build。

## 11. 分阶段升级路线

### V0：依赖、安全与测试基线

- 固定 LibVNCClient commit 和双 ABI 构建。
- 完成 license/NOTICE/SBOM/provenance/hash。
- 建立 scripted RFB server、协议 parser tests 和恶意输入 corpus。
- 建立 feature gate，依赖缺失时 VNC 继续明确 unsupported，不影响其他协议。

### V1：macOS VNC 密码直连

- 添加 VNC 主机表单、默认端口、筛选和能力门。
- 实现 RFB 连接、VNC password、ServerInit、framebuffer 和输入。
- 实现 full/dirty BGRA presentation、断连和恢复。
- 在 Intel/Apple Silicon Mac 的可用系统版本中至少选择一台真实目标完成验收。

### V1.5：macOS 账户认证

- 记录目标 macOS 实际 advertised ARD auth types。
- 只实现有规范、可审计且测试覆盖的类型。
- 接入安全凭据模型，完成锁屏、登录窗口、当前用户和错误密码矩阵。

### V2：主流服务端与交互

- TigerVNC、TightVNC、RealVNC direct、UltraVNC direct、WayVNC。
- Hextile、ZRLE、Tight/JPEG、remote cursor、continuous updates。
- 双向文本剪贴板、view-only、键盘/IME 和 quality presets。

### V3：安全 transport

- VeNCrypt、TLS/X.509、证书确认和 pinning。
- SSH tunnel、SOCKS/HTTP proxy。
- 公网连接默认要求加密 transport。

### V4：桌面与网络扩展

- ExtendedDesktopSize 和服务端支持时的 resize。
- UltraVNC Repeater、reverse/listen mode。
- 多显示器公开扩展和 gateway 管理模型。

### V5：厂商扩展

- TightVNC/UltraVNC 文件传输等公开且可测试的扩展。
- 每个厂商扩展独立 capability、设置和兼容矩阵。
- Apple High Performance 维持独立研究线，不阻塞标准 VNC。

## 12. 测试与放行门

### 12.1 自动测试

- RFB 3.3/3.7/3.8 handshake。
- security type allowlist 和 VNC password challenge。
- ServerInit 尺寸、pixel format 和名称解析。
- Raw、CopyRect及每个后续 encoding 的正常、截断、越界和解压炸弹测试。
- framebuffer resize、dirty merge、surface generation 和 full-resync。
- pointer button mask、wheel、keysym、modifier release。
- connect timeout、auth failure、server close、disconnect during callback。
- callback 清理后不得访问 session 或 renderer。
- capability policy 与 UI 可用性一致。

### 12.2 构建门

- host native focused tests。
- arm64-v8a 和 x86_64 VNC library/ABI/linkage。
- `default@OhosTestCompileArkTS`。
- production `assembleHap`。
- `git diff --check`。
- Light open-source compliance；依赖变化还需 SBOM/NOTICE/provenance/hash 校验。

### 12.3 macOS V1 真机门

- Mac 开启 Screen Sharing 或 Remote Management 的 VNC password compatibility。
- 正确密码连接、错误密码明确失败。
- 首帧可见，无蓝屏、黑屏或错色。
- 鼠标移动、左右键、中键、滚轮和键盘可用。
- 1920x1080 及一项 Retina/非整数缩放场景。
- 窗口 resize、Home/前后台恢复后画面完整。
- 网络断开、Mac 睡眠/唤醒、服务关闭后的错误可解释。
- 连接/断开 20 次，无线程、socket、framebuffer 或 renderer 残留。
- 30 分钟动态桌面，内存不线性增长，输入和画面不持续劣化。
- VNC 失败后立即连接 RDP、RustDesk、SSH，三者行为不变。

## 13. 发布规则

只有 V1 真机门完成后，VNC 才能从“规划中”改为“可用”。发布文案必须说明首期是标准 VNC 直连、无音频/文件传输、未加密连接仅建议可信局域网或 VPN。

任何未协商、未实现或未真机通过的能力不得显示为可用。VNC依赖安全公告存在未处置高危问题时，VNC feature gate 必须关闭，但应用其他协议仍可发布。

## 14. 成功标准

首期成功不是“TCP 5900 能连通”，而是：在目标 Mac 上完成安全边界明确的 VNC password 认证，稳定显示真实桌面，完成键鼠控制和生命周期恢复；同时形成可替换 engine、分层扩展、能力真值、安全解码和独立测试基础，使后续功能可以增量加入而不重写主机、NAPI、渲染或其他协议。
