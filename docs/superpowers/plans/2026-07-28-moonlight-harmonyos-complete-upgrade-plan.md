# RemoteDeskHarmonyOS Moonlight / Sunshine 串流能力完备升级计划

> 文档状态：完成评估，待后续立项实施
> 评估日期：2026-07-28
> 当前代码基线：main，HEAD 951d1a390
> 适用仓库：/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS
> 本轮变更边界：只新增本计划文件；不修改 ArkTS、C/C++、Rust、配置、依赖、云表或构建流程代码。

## 0. 结论先行

### 0.1 是否值得加入

值得加入，但它应被定义成独立的“游戏主机串流”产品域，而不是现有 RDP、RustDesk 或 VNC 的一个普通协议枚举。

Moonlight/GameStream 的核心价值是低延迟音视频和游戏输入闭环，目标不是远程办公桌面。它需要同时满足以下条件：

1. 主机控制面：主机发现、serverinfo、配对、应用目录、启动/停止应用。
2. 串流控制面：RTSP/SDP、会话协商、编解码能力、分辨率、帧率、码率、音频模式。
3. 可靠控制面：ENet/控制流、输入可靠发送、重连、取消和主机反馈。
4. 实时媒体面：UDP RTP、视频 FEC/重排/解密、音频 FEC/重排/解密、关键帧恢复。
5. 设备交互面：键盘、鼠标、触摸、实体手柄、振动、LED、运动数据和多玩家槽位。
6. 鸿蒙生命周期面：Surface、NativeImage、硬解、OHAudio、PIP、后台长时任务、音频焦点和设备旋转。

推荐的总体路线：

- 以官方 moonlight-common-c 作为串流协议核心；
- 不复制 Moonlight Android 的 Java/JNI/UI，也不移植 Moonlight Qt 的 SDL/Qt/桌面渲染；
- 用项目现有 C/C++ NAPI、OH_AVCodec、NativeImage、GLRenderer、OHAudio、ArkUI 和会话生命周期能力做 HarmonyOS 平台适配；
- 第一版只保证局域网或用户已配置的可达网络、Sunshine 现代版本、H.264 + Opus、键鼠/触摸/实体手柄的可验证闭环；
- HEVC、AV1、HDR、YUV 4:4:4、7.1、触觉高级反馈和复杂公网网络在能力探测通过后逐项开放；
- 新增一张物理云同步表 moonlightrecord，使用 recordType 区分 settings、host、profile、trust、secret；不把 Moonlight 数据写入 remotehosts、usersettings、rustdeskrelays、vncrecord 或 SSH 表；
- 配对私钥默认只保存在本机安全存储，不默认上云；跨设备恢复必须是用户明确开启、加密就绪且经过重新确认的可选能力。

### 0.2 当前可行性等级

| 维度 | 评估 | 结论 |
| --- | --- | --- |
| 协议可实现性 | 高 | 官方 C 核心已覆盖连接、RTSP、控制、视频、音频和输入；项目已有 C/C++ NAPI |
| 鸿蒙视频复用 | 高，但需真机校准 | 现有 OH_AVCodec Surface 管线支持 H.264/H.265/VP8/VP9/AV1，需增加 Moonlight decode unit 桥接 |
| 鸿蒙音频复用 | 高 | 现有 OHAudio 播放器接受 PCM；需增加 Opus/Opus multistream 解码和重采样/降混 |
| 键鼠/触摸 | 中高 | 现有输入通道可复用部分能力，但 Moonlight 需要独立坐标、相对鼠标、触摸点和快捷键语义 |
| 实体手柄 | 中，必须先做 API 23 编译探针 | Game Controller Kit 有官方 C/C++ 能力，但本地 API 23 SDK 和目标设备是否完整提供必须以编译和真机结果为准 |
| 背景/PIP | 中高 | 现有生命周期、PIP、后台长时任务已经存在；Moonlight 的视频丢帧、关键帧和音频策略需要单独定义 |
| 公网串流 | 中低 | GameStream 不是浏览器 WebSocket 流；需要 TCP/UDP 端口、NAT/IPv6/MTU 和用户网络环境，不能仅靠一个 HTTP relay 地址 |
| 云同步 | 高 | 当前已有正式 CloudStore/Coordinator/加密 envelope 体系，可复制 VNC 的单表隔离思路 |
| 开源合规 | 中高风险 | moonlight-common-c、Moonlight Android/Qt 和 Sunshine 均涉及 GPL 体系；必须锁定来源、依赖、SBOM、源码提供和发布 notice |
| 产品交付风险 | 中高 | 最大风险不在 UI，而在 API 23 手柄/解码能力、真实 Sunshine 主机、UDP 网络矩阵、温控和旧回调生命周期 |

### 0.3 明确不承诺的内容

在以下条件没有完成之前，不在 UI 中宣称“全平台 Moonlight 兼容”“公网免配置”“支持所有手柄”“支持 HDR/AV1/7.1”：

- API 23 本地头文件和双 ABI 构建探针通过；
- 至少一台真实 ARM64 HarmonyOS 设备完成 H.264 + Opus 串流；
- 至少一台真实 Sunshine 主机完成配对、目录、启动、键鼠、手柄和停止；
- 真实 UDP 丢包、抖动、IPv6/NAT64、后台、PIP、Surface 重建和断连重连通过；
- 第三方来源、GPL/AGPL 组合、ENet 固定子模块、Opus/OpenSSL 复用和 HAP 源码提供方案通过合规复核。

## 1. 评估范围、现状和证据

### 1.1 工作区状态

本次评估启动时工作区位于 main，HEAD 为 951d1a390，相对 main 没有额外分支；工作树存在用户已有的 ArkTS、VNC、RustDesk、SSH 及计划文档变更。本计划不接管、不覆盖、不整理这些变化，也不要求 stash、reset、切换分支或新建任务分支。

本轮只允许出现一个新增文件：

- /Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md

### 1.2 应用当前定位

当前 README 已明确应用是 HarmonyOS NEXT 多协议远程桌面客户端，技术栈为 ArkTS/ArkUI、C/C++ NAPI、RustDesk Rust FFI、FreeRDP、VNC、渲染、音频、输入和华为云同步；当前 VNC 仍处于设备验证和逐项开放阶段。参见：

- [README.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/README.md:3)
- [README.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/README.md:30)
- [README.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/README.md:42)

这意味着 Moonlight 应优先作为第五个协议产品域接入，而不是先扩展一个通用 RemoteHost 再让页面猜字段。

### 1.3 当前代码的可复用资产

| 资产 | 当前位置 | 能复用什么 | 复用前必须解决的问题 |
| --- | --- | --- | --- |
| C/C++ NAPI 主库 | entry/src/main/cpp/CMakeLists.txt | 统一 native 构建、NAPI 出口、OpenSSL、Opus、OHOS 系统库 | 当前目标是单体 rdpnapi；Moonlight 应先以独立静态子目标隔离，再链接主库 |
| ProtocolAdapter | entry/src/main/cpp/extensions/protocol_adapter.h | 基础连接/状态/键鼠/视频/音频回调抽象 | 当前接口是远程桌面单连接思维，没有配对、应用目录、RTSP 阶段、手柄、码率和流配置 |
| ExtensionLoader | entry/src/main/cpp/extensions/extension_loader_napi.cpp | 协议注册、会话激活、native 回调到 ArkTS 的边界 | 当前存在进程级 g_activeConnection 和 active decoder/audio 路径，Moonlight 需要 session + generation 作用域 |
| 硬解管线 | entry/src/main/cpp/render/hw_decoder.h、hw_decoder.cpp | OH_AVCodec、NativeImage、Surface、GL OES 纹理、关键帧恢复、队列上限 | Moonlight 回调是 DECODE_UNIT 链，不是简单的单 buffer VideoFrame；需要保存 SPS/PPS/VPS 和 frameType |
| GLRenderer | entry/src/main/cpp/render/gl_renderer.h、gl_renderer.cpp | XComponent、GL context、NativeImage texture、重绘和 Surface 生命周期 | 必须把旧会话回调和新会话 generation 隔离，不能把 Moonlight 纹理事件写入全局旧 owner |
| OHAudio | entry/src/main/cpp/audio/audio_player.cpp | S16LE PCM 播放、低时延模式、队列、欠载统计、暂停/恢复 | Moonlight common-c 的音频回调需要由 Opus decoder 产出 PCM；多声道必须能力探测后降级 |
| 输入处理 | entry/src/main/cpp/audio/input_handler.h、input_handler.cpp | 键盘、鼠标、滚轮、触摸输入的部分事件桥 | 当前 activeAdapter 是单全局路由；Moonlight 手柄和相对/绝对鼠标必须独立 owner |
| ArkTS 会话状态 | entry/src/main/ets/services/RemoteSessionState.ets | connecting/connected/background/foreground/disconnecting/failed 状态和时间戳 | Moonlight 需要在通用状态下增加细粒度 stage，不应让 UI 用一条 connected 猜完整可用性 |
| Native handle 生命周期 | entry/src/main/ets/services/NativeSessionHandles.ets | 后台只脱附 renderer、前台重新绑定 Surface、请求关键帧、完全断连 | Moonlight 需要补充视频暂停/丢帧、音频 flush、输入关闭和 RTSP/UDP 关闭顺序 |
| PIP/后台 | entry/src/main/ets/services/RemoteSessionPipLifecyclePolicy.ets、RemoteSessionBackgroundTaskService.ets | decoderReady、远端尺寸、PIP 准备、multiDeviceConnection、audioPlayback | Moonlight 的背景播放必须依赖实际媒体状态和 AVSession/长时任务准入，不可只复用 RDP 文案 |
| 云同步 | entry/src/main/ets/services/CloudStore.ets、CloudSyncCoordinator.ets | 显式表选择、云优先启动、重试、journal、冲突阻断 | Moonlight 必须新增独立 physical table 和 logical record type，不可被普通 selectedTables 无上下文上传 |
| VNC 隔离数据设计 | entry/src/main/ets/model/VncRecord.ets、services/VncRecordPolicy.ets | 19 列单表 envelope、recordType、hash、resetEpoch、secret opt-in、local mirror | Moonlight 应建立自己的 moonlightrecord，不复制 VNC 业务字段，也不引用 VNC secret owner |

### 1.4 当前缺口

当前没有 Moonlight、GameStream 或 Sunshine 的协议实现。全仓搜索没有发现可复用的 Moonlight client core。主要结构性缺口如下：

1. RemoteProtocol 只有 rdp、rustdesk、ssh、vnc，没有 moonlight。
2. RemoteHost 主要服务 RDP、RustDesk、SSH，并不承载 Moonlight 的 server UUID、配对证书、应用 profile、RTSP/UDP 端口和流能力。
3. ProtocolAdapter 的 ConnectionConfig 带有通用 username/password，但 Moonlight 的认证是 HTTP 配对证书/PIN，不应被误建模为普通密码。
4. VideoFrame 是单 buffer 模型，Moonlight common-c 的 DECODE_UNIT 是多 LENTRY 链，且 bufferType 可能标识 SPS/PPS/VPS。
5. AudioData 以 PCM 为主要回调形态，但 Moonlight 音频回调需要在本地执行 Opus/Opus multistream 解码。
6. InputHandler 没有 Game Controller Kit、控制器槽位、振动、LED、运动、触摸点和可靠输入 flush 的专用接口。
7. ExtensionLoader 和 decoder/audio pipeline 仍有全局 active 路径；Moonlight 的网络线程、视频线程、音频线程、输入线程和 UI generation 必须成组销毁。
8. HostProtocolPicker 当前展示 RDP、RustDesk、SSH、VNC；设置策略当前有 RDP、RustDesk、SSH、VNC，Moonlight 需要独立入口和独立设置 owner。
9. 当前 cloud sync 已注册 cryptoparams、usersettings、remotehosts、rdpcredentials、rustdeskrelays、sshkeys、totpentries、vncrecord；新增 Moonlight 时只能增加一个新的物理业务表 moonlightrecord。

## 2. Moonlight 官方实现与协议栈评估

### 2.1 代码边界：只取客户端核心，不搬运整套客户端

推荐的上游边界是官方 moonlight-common-c。它是 Moonlight 多平台客户端共享的 C 核心，已经包含连接编排、RTSP、控制流、视频流、音频流、输入流、FEC、重排、统计和回调接口；它不是完整的 ArkUI 客户端，也不是 Sunshine 服务端。实现时应锁定一个具体 commit，并把该 commit 使用的 ENet 子模块一并锁定，不能直接用系统 ENet 或任意版本的 vendored ENet。官方 README 明确指出其 ENet API/ABI 和 IPv6/可靠传输行为存在版本约束。

推荐直接采用的上游材料：

- [moonlight-common-c README](https://github.com/moonlight-stream/moonlight-common-c)
- [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Connection.c)
- [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h)
- [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/VideoStream.c)
- [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/AudioStream.c)
- [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)
- [moonlight-common-c CMakeLists.txt](https://github.com/moonlight-stream/moonlight-common-c/blob/master/CMakeLists.txt)

不建议直接移植以下部分：

| 来源 | 不直接移植的原因 | 可借鉴内容 |
| --- | --- | --- |
| Moonlight Android | Java/Android Surface、MediaCodec、Android Input、Activity 和 JNI 生命周期与 HarmonyOS 不同 | PairingManager、NvHTTP、JNI 回调的分层方式和错误语义 |
| Moonlight Qt | Qt、SDL、桌面窗口、Linux/Windows/macOS 输入和渲染路径与 ArkUI/XComponent 不同 | session 编排、设置分层、键鼠/手柄 UX、能力提示 |
| Sunshine | 它是服务端，不应打包进手机客户端 | serverinfo、配对、应用目录、RTSP/编码器兼容测试对象 |
| 任意第三方 Moonlight fork | 可能混入过时协议、不同许可证或未审计补丁 | 仅作为问题对照，不作为默认依赖 |

### 2.2 主机发现、控制和可达性

Moonlight 的控制面不是单一长连接。目标流程应拆成以下可观测阶段：

1. 发现：局域网 mDNS/主机发现，或用户手动输入 IPv4、IPv6、域名和端口。
2. 可达性：按地址族和端口探测 HTTP/HTTPS、RTSP 和 UDP 可能性；不得把 TCP 可达误判成媒体可达。
3. 主机信息：读取 serverinfo，得到服务器 UUID、协议代际、主机名、应用目录能力、编码能力和配对状态。
4. 配对：四位 PIN、挑战响应、客户端证书/密钥和服务器证书 pin。
5. 目录：读取可启动应用，显示应用名称、图标、应用 ID、可用分辨率或主机能力。
6. 启动：根据所选应用和流配置发起 launch，等待主机返回可用的串流控制信息。
7. 串流：完成 RTSP/SDP 和 common-c 的媒体、控制、输入流建立。
8. 停止：先停止输入和媒体，再取消/退出应用；超时后仍需关闭本地所有 native 资源。

端口和传输必须在设置和诊断中可解释：

| 用途 | 默认端口/协议 | 产品处理 |
| --- | --- | --- |
| 主机发现 | UDP 5353，mDNS/局域网 | 默认自动发现；失败时保留手动添加 |
| GameStream HTTP/HTTPS 控制 | TCP 47989 为常见控制端口 | 端口可配置；用实际 serverinfo/主机响应校验 |
| RTSP/控制相关 TCP | TCP 47984、47989、48010 | 按上游 common-c 和 NvHTTP 规则协商/回退 |
| 视频 RTP | UDP 47998，另有实现使用相邻媒体端口 | 由 RTSP/会话参数确定，不能在 UI 固定成单端口 |
| 音频/控制/输入 RTP/UDP | UDP 47999、48000、48002、48010 | 由协议协商和主机实现决定 |
| Wake-on-LAN | UDP 广播或定向 magic packet | 仅作为可选唤醒，不承诺公网唤醒 |

以上端口来自 [Moonlight Setup Guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)。产品须把“自动发现”“手动地址”“端口转发/公网访问”“IPv6”分别建模。Moonlight 原生依赖 TCP+UDP，不能用浏览器式 WebSocket 代理替代完整媒体通道；FAQ 也明确浏览器不能直接承载 GameStream 的原始传输，参见 [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions)。

公网路线的最低设计边界：

- MVP 只保证用户明确配置、端口可达的网络；不做自建 TURN、反向代理或云中继。
- 不把云同步表误包装成穿透服务；云只同步配置和可选凭据，不转发视频。
- IPv6、NAT64、双栈地址排序必须由网络层根据系统实际解析结果和失败结果动态处理。
- 多地址主机需要记录地址族、最近成功地址、失败原因和下次探测退避时间。
- WOL 只在本地二层网络或用户明确配置的网关可用时显示，参见 [WOL 文档](https://github.com/moonlight-stream/moonlight-docs/wiki/WOL-%28Wake-On-LAN%29)。

### 2.3 配对、TLS 和信任

配对不能复用 RDP/VNC 的 username/password 表单。Moonlight Android 的 [PairingManager](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/nvstream/http/PairingManager.java) 和 [NvHTTP](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java) 展示了以下业务事实：

- 用户输入四位 PIN，PIN 只在配对会话内存在，不落日志、不进云、不写 host payload。
- 现代主机使用 SHA-256，旧主机存在 SHA-1 兼容路径；兼容路径必须标为 legacy，并受版本/安全策略控制。
- 配对使用随机 salt、由 PIN 派生的 AES 密钥和主机挑战响应。
- 配对成功后会拿到客户端身份材料和服务器证书信息；后续 TLS 连接必须做服务器证书 pin，而不是任意信任新证书。
- 证书变更应进入“信任变更”流程：展示旧/新指纹、要求用户重新确认或重新配对，不能静默替换。

安全数据边界：

| 数据 | 默认位置 | 云同步默认值 | 处理 |
| --- | --- | --- | --- |
| server UUID、主机名、地址、端口 | 本地加密记录 | 同步 | 用于发现和主机卡片 |
| 服务器证书指纹 | 本地 trust 记录 | 可同步 | 同步后仍需显示指纹变更 |
| 客户端证书公钥 | 本地 secret/trust 记录 | 不同步或显式选择 | 不因云同步而放宽设备绑定 |
| 客户端私钥/配对身份 | 本机安全存储 | 默认不同步 | 只有用户开启端到端加密备份后才允许同步 |
| PIN | 临时内存 | 永不同步 | 配对失败后立即清理 |
| 访问令牌、HTTP 会话缓存 | 本地短期缓存 | 永不同步 | 过期、切换账号或撤销时清理 |

配对界面必须支持取消、超时、重试、重置配对、证书变更确认和“仅保存主机、不保存配对身份”。在所有错误文案中区分 PIN 错误、主机未进入配对状态、证书变更、TCP 可达但 UDP 不通、主机正在运行其他会话。

### 2.4 common-c 的连接阶段和线程边界

官方 [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Connection.c) 的启动顺序不是可选的 UI 步骤，而是 native session 的状态机边界。计划中的事件顺序如下：

| 阶段 | 主要动作 | 成功条件 | 失败时 |
| --- | --- | --- | --- |
| platform initialization | 初始化 socket、线程、定时器、平台回调 | 平台资源可用 | SESSION_INIT_FAILED |
| name resolution | 地址解析和地址族选择 | 至少一个候选地址 | HOST_RESOLUTION_FAILED |
| audio stream initialization | 创建音频接收和解码前回调 | 音频通道准备好 | 视配置可降级为无音频 |
| RTSP handshake | 建立 RTSP、发送能力和流配置 | 收到合法响应和 SDP/会话参数 | RTSP_NEGOTIATION_FAILED |
| control stream initialization | 创建 ENet/控制流 | 控制通道 ready | CONTROL_INIT_FAILED |
| video stream initialization | 创建视频 RTP/FEC/重排 | 视频接收结构 ready | VIDEO_INIT_FAILED |
| input stream initialization | 创建输入通道 | 输入通道 ready 或明确禁用 | INPUT_INIT_FAILED |
| control/video/audio/input establishment | 启动各流和回调 | 第一个关键帧、音频可播放、输入可发送 | 按流降级或整会话失败 |

需要额外做两件事：

1. 为 common-c 的每个回调带上 sessionId、generation 和 stream generation。回调到达时先判定 owner 是否仍然有效，再投递到 ArkTS。
2. 关闭顺序与启动顺序相反：停止用户输入，停止控制发送，停止音频接收并 flush，停止视频接收并等待回调归零，停止 RTSP/HTTP，销毁解码器和 Surface，最后释放 session owner。

common-c 本身不是线程安全的业务状态容器。不能把其全局回调直接指向当前页面，也不能在 ArkTS 页面销毁后仍让 native 线程持有 NAPI reference。

### 2.5 视频：RTP、加密、FEC、解码和首帧

视频面至少要保留以下信息，才能和现有 H.264/H.265/AV1 硬解管线正确衔接：

- RTP sequence number、timestamp、payload type、frame boundary；
- 视频包加密状态、会话密钥和包序；
- FEC 数据包、丢包恢复结果、重排窗口和 reorder timeout；
- frame type、frame number、reference frame 标志；
- H.264 SPS/PPS、HEVC VPS/SPS/PPS、AV1 sequence/header 等 codec configuration；
- decode unit 的 bufferType、buffer链、长度、presentation timestamp；
- 最近成功关键帧、待请求 IDR、连续丢帧计数、解码器 flush/reconfigure 状态。

官方 [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/VideoStream.c) 会将 RTP 包经过视频解密、FEC、重排和帧组装，再通过 DECODE_UNIT 回调交给客户端。项目当前 hw_decoder.cpp 已有 OH_AVCodec、Surface、队列上限和恢复逻辑，但其输入假设是一个 encoded frame buffer。两者之间应新增 MoonlightVideoBridge：

1. 将 LENTRY 链复制或引用到 session-owned buffer，不能引用 common-c 将要复用的包内存。
2. 记录配置帧，遇到解码器首次启动、Surface 重建或 codec change 时先补齐配置。
3. 按 codec 将多个片段合并成 OH_AVCodec 可接受的 access unit，并保留关键帧标志。
4. 视频队列满时优先丢弃尚未开始解码的非关键帧，不丢失最近关键帧和配置帧。
5. 首帧超时或 Surface 重绑后主动请求 IDR；不能无限等待旧帧。
6. 将 packet loss、FEC recovery、decode queue、decode latency、render latency 作为诊断指标。

默认视频能力矩阵：

| 能力 | MVP | 后续开放条件 |
| --- | --- | --- |
| H.264 8-bit 4:2:0 | 必须 | 真实 ARM64 设备 1080p60 稳定 |
| HEVC 8-bit/10-bit | 条件支持 | API23 codec probe、硬解 profile 和功耗实测 |
| AV1 | 条件支持 | API23 codec probe、Sunshine 编码、硬解和软件回退实测 |
| HDR | 关闭 | 色彩 metadata、Surface、显示链和 PIP 全链路验证 |
| YUV 4:4:4 | 关闭 | 解码器 profile、纹理采样和显示色彩正确性验证 |
| 4K、高帧率 | 设备/主机能力决定 | 分辨率、码率、温控和内存预算验证 |

不能把 FFmpeg 软件解码作为 Moonlight 主路径。现有 FFmpeg soft fallback 可作为异常设备的实验性兜底，但第一版应优先走 OH_AVCodec 硬解并在能力不足时给出清晰的不可用原因。

### 2.6 音频：Opus、时钟和 OHAudio

官方 [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/AudioStream.c) 的回调输出是经过 common-c 网络处理后的音频样本/配置，客户端需要提供 renderer/decoder 逻辑。计划的音频链路是：

Moonlight RTP audio → common-c 解密/FEC/重排 → Opus 或 Opus multistream decoder → PCM 48 kHz → 重采样/声道映射 → OHAudio renderer → 音频焦点/AVSession。

项目已有 [audio_player.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/audio_player.cpp:70) 使用 OHAudio 播放 48 kHz、双声道、S16LE PCM，并有队列和欠载统计。这条链可复用，但必须新增：

- 每个 Moonlight session 独立的 Opus decoder owner；
- channel count、sample rate、sample format 的动态协商；
- 5.1/7.1 的能力探测与明确降混到 stereo；
- audio timestamp 与视频/本地时钟的漂移监控；
- buffer target、underrun、late packet、decoder reset、focus loss 的处理；
- 断连、后台、PIP、电话/系统音频抢占时的 pause/flush/resume。

鸿蒙侧应以官方 [OHAudio 播放指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5) 和 API23 本地头文件为准。第一版使用游戏音频用途，设置 AUDIO_RENDERER_CALLBACKS 的低时延路径，但不把录音、麦克风回传或语音聊天混入 MVP；如果未来需要麦克风，必须另做权限、回声消除、隐私指示和云端策略评估。

### 2.7 控制流、输入和反馈

控制与输入不能仅调用现有 sendKey/sendMouse。计划分成四层：

| 层 | 事件 | 可靠性/顺序 |
| --- | --- | --- |
| 键盘 | key down/up、unicode/text、组合键、系统快捷键 | 按 common-c 语义发送；页面失焦时 flush 所有按键 |
| 鼠标 | 相对移动、绝对移动、左中右键、滚轮、抓取/释放 | 相对移动允许合并；按钮 down/up 必须成对 |
| 触摸 | 多点 id、down/move/up/cancel、pressure/尺寸 | 保留触摸点生命周期；页面退出统一 cancel |
| 手柄 | 设备槽位、按钮、轴、扳机、帽子开关、运动 | 按控制器协议和设备能力映射；控制器断开先发送安全释放 |
| 反馈 | rumble、低频/高频、LED、可能的 motion | 只对真实设备能力开放；失败不影响视频会话 |

官方 [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c) 和 [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h) 提供了键盘、鼠标、多点触摸、控制器和反馈接口。项目的 [input_handler.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/input_handler.cpp:20) 目前以进程级 activeAdapter 路由，Moonlight 必须使用 session-owned InputBridge，避免旧 VNC/RDP 会话接收新手柄事件。

输入安全策略：

- 普通系统返回、通知、音量、电源、Home 等键不默认转发到远端。
- Alt+Tab、Ctrl+Alt+Del、Win 键等危险快捷键要单独设置，并提供按键释放保险。
- 屏幕触摸默认只发送触摸，不偷偷转换为鼠标，除非用户选择兼容模式。
- 没有实体手柄时，虚拟手柄仅作为后续能力；MVP 可提供最小的触摸鼠标和键盘面板。
- 连接页面必须展示当前输入源和捕获状态，提供一键释放鼠标/键盘/手柄。

## 3. 鸿蒙 API23 能力门槛

### 3.1 先做能力探针，再做功能承诺

鸿蒙 API23 的 SDK、设备镜像和 DevEco 版本是实际合同。官网页面、第三方镜像或其他平台 Moonlight 代码只能作为 API 形状参考，不能替代本地编译和真机验证。第一阶段必须建立不改变业务代码的 probe 工程/目标，逐项验证：

| 能力 | 需要验证 | 通过标准 |
| --- | --- | --- |
| NAPI/线程 | native worker 线程回调 ArkTS、NAPI reference、异步队列、页面销毁 | 可在主线程和后台安全停止，无 use-after-free |
| OH_AVCodec | H.264、HEVC、AV1 的 mime/profile、Surface 输出、flush/reconfigure、关键帧请求 | API23 双 ABI 编译，真实目标设备首帧和重绑通过 |
| NativeImage/Surface | XComponent/PIP/页面重建后 detach/attach | 旧 Surface 不再接收回调，恢复后首帧时间可测 |
| OHAudio | 48 kHz stereo S16LE、低时延、音频焦点、后台 | 连续 30 分钟无不可恢复 underrun，焦点丢失可恢复 |
| Input Kit | 键盘、鼠标、触摸事件和 key code | 页面切换、旋转、取消、系统返回时无悬挂按键 |
| Game Controller Kit | 多控制器、button/axis/trigger、device id、断开、rumble | 至少两类真实手柄每个轴/按钮映射正确 |
| AVSession/后台 | 游戏音频、播放控制、后台任务、锁屏/切应用 | 系统允许的后台范围内可继续音频/必要媒体，不虚报无限后台 |
| PIP | 画面尺寸、解码器持续输出、返回前台 | PIP 和普通页面互切无黑屏/花屏/旧会话画面 |
| 网络 | IPv4/IPv6、mDNS、TCP/UDP、蜂窝/无线切换、NAT64 | 发现失败可手动连接，地址族回退可解释 |
| 安全存储 | 设备级密钥、证书私钥、删除和账号切换 | 私钥不出安全边界；账号退出后按策略清理 |

官方资料入口：

- [HarmonyOS 开发者中心](https://developer.huawei.com/consumer/cn/develop/)
- [HarmonyOS Input Kit C 头文件](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/input-headerfile-V13)
- [OHAudio 播放指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5)
- [Background Process Manager 参考](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/js-apis-backgroundprocessmanager-V13)
- [HarmonyOS 分布式数据库 Codelab](https://developer.huawei.com/consumer/en/codelab/HarmonyOS-Distributed-Database/)

Game Controller Kit 的具体头文件、动态库名、事件模型和 API23 可见性必须以本地 SDK 为准。当前仅把官方开发目录中的 Game Controller Kit 作为方向性依据；任何第三方 API 摘要都不能直接写进生产调用约定。

### 3.2 当前代码对应的鸿蒙复用判断

| 当前实现 | Moonlight 复用策略 |
| --- | --- |
| hw_decoder.cpp 中 OH_VideoDecoder_CreateByMime、SetSurface 和已有 codec 枚举 | 抽出通用 decoder owner；Moonlight 只负责把 DECODE_UNIT 变成 access unit |
| GLRenderer 的 XComponent/NativeImage | 复用渲染表面管理，但用 session generation 阻止旧回调绘制 |
| audio_player.cpp 的 OHAudio 48 kHz stereo | 复用 renderer；前面增加 Opus decoder、时钟和声道降混 |
| RemoteSessionBackgroundTaskService 的 multiDeviceConnection/audioPlayback | 复用生命周期服务；新增 Moonlight 的 media-ready、input-ready、pause/resume 条件 |
| RemoteSessionPipLifecyclePolicy 的 decoderReady/source dimensions | 复用 PIP 决策接口；Moonlight 首帧和关键帧恢复必须成为显式条件 |
| Input Kit 的现有键鼠/触摸桥 | 复用底层事件读取；Moonlight 增加相对鼠标、触摸 id、手柄和按键释放 |
| CloudStore/CloudSyncCoordinator/VncRecordPolicy | 复用 envelope、冲突和 journal 机制；新建 Moonlight namespace，不复制 VNC 业务逻辑 |

### 3.3 能力降级原则

能力结果要分为 supported、unsupported、temporarilyUnavailable、permissionDenied、unknown 五种，不允许把“未探测”当作“支持”。建议按以下优先级降级：

1. 先保证视频解码和输入安全；
2. 音频不可用时允许用户选择无音频串流；
3. HEVC/AV1 不可用时回退 H.264，但要重新协商主机编码；
4. 7.1 回退 stereo；
5. 触觉/LED/motion 失败不影响核心会话；
6. PIP/后台不满足系统条件时回到前台并显示原因；
7. UDP 媒体不可达时结束会话或提示网络配置，不把它伪装成 RDP 式 TCP 串流。

所有能力结果都应同时记录在诊断快照中，便于区分“主机不支持”“设备不支持”“网络不支持”和“应用没有权限”。

## 4. 目标架构和边界

### 4.1 目标数据流

~~~mermaid
flowchart LR
  UI["ArkUI 页面 / 串流 HUD"] --> State["MoonlightSessionService"]
  State --> NAPI["Moonlight NAPI bridge"]
  State --> Cloud["CloudSyncCoordinator"]
  NAPI --> Core["MoonlightCoreSession"]
  Core --> HTTP["HTTP/TLS Host API"]
  Core --> RTSP["RTSP / SDP"]
  Core --> ENET["ENet reliable control"]
  Core --> RTP["RTP / UDP / FEC / reorder"]
  Core --> Video["MoonlightVideoBridge"]
  Core --> Audio["MoonlightAudioBridge"]
  Core --> Input["MoonlightInputBridge"]
  Video --> AVCodec["OH_AVCodec / NativeImage / Surface"]
  Audio --> Opus["Opus decoder / resampler"]
  Opus --> OHAudio["OHAudio / AVSession"]
  Input --> HarmonyInput["Input Kit / Game Controller Kit"]
  AVCodec --> Render["GLRenderer / XComponent / PIP"]
  Host["Sunshine / legacy GameStream host"] --> HTTP
  Host --> RTSP
  Host --> RTP
  Host --> ENET
~~~

### 4.2 Native 组件职责

| 组件 | 责任 | 明确不负责 |
| --- | --- | --- |
| MoonlightCoreSession | common-c 生命周期、流启动/停止、连接阶段、统计、错误码 | ArkUI 页面、云表、UI 文案 |
| MoonlightHostApi | 发现、serverinfo、配对、目录、launch/quit、TLS pin | 视频 RTP 解码 |
| MoonlightTransport | socket 地址族、端口、RTSP/HTTP/UDP 可达性、网络切换 | 云端中继 |
| MoonlightVideoBridge | DECODE_UNIT、配置帧、队列、关键帧恢复、OH_AVCodec 输入 | 绘制业务按钮 |
| MoonlightAudioBridge | Opus、PCM、时钟、重采样、OHAudio renderer | 音频焦点 UI |
| MoonlightInputBridge | 键鼠、触摸、手柄、反馈、释放保险 | 读取 ArkUI 页面状态 |
| MoonlightSecureStore | 私钥、证书、token 的本机安全存取 | 普通 host/profile 配置 |
| MoonlightNapi | 线程安全的 create/connect/events/send/stop/rebind 出口 | 直接决定 UI 路由 |

新组件建议放在独立的 native moonlight 目录下，先形成独立静态库或 object group，再由现有 rdpnapi 统一出口链接。不要把 common-c 的全局符号散落到 RDP/VNC 公共文件中，也不要让 ProtocolAdapter 为了兼容 Moonlight 而继续增加大量可选字段。

### 4.3 会话所有权和线程模型

每个 Moonlight 会话必须拥有：

- sessionId：用户可见会话标识；
- generation：每次连接/重连递增；
- native owner：唯一释放者；
- surface generation：每次 Surface 绑定递增；
- audio generation：音频 renderer 重建递增；
- input owner token：防止旧会话继续发送按键；
- callback gate：销毁前关闭、等待在途回调归零；
- cancellation token：所有网络、解码和输入线程都可观察。

建议的线程边界：

| 线程/队列 | 内容 | 禁止事项 |
| --- | --- | --- |
| ArkTS UI | 页面状态、用户操作、设置和错误提示 | 阻塞等待网络或解码 |
| NAPI dispatch | 将 native 事件序列化投递到 ArkTS | 直接持有已销毁页面对象 |
| HTTP/RTSP worker | serverinfo、配对、目录、launch、RTSP | 直接修改 UI 状态 |
| common-c network workers | RTP、FEC、ENet、输入流 | 访问 ArkTS 对象 |
| video bridge | decode unit、队列、关键帧 | 在回调内执行慢速磁盘 I/O |
| audio bridge | Opus、PCM、时钟、renderer | 和其他会话共享 decoder |
| input worker | 事件节流、可靠发送、feedback | 读全局 activeAdapter |

关闭必须满足 callback gate 已关闭、网络线程已停止、媒体队列已清空或转移、Surface/audio handle 已解除绑定，才能释放 native owner。这个约束是本项目最重要的防回归门。

### 4.4 NAPI 事件合同

ArkTS 只消费稳定的事件模型，不消费 common-c 的原始结构。事件至少包括：

- stageChanged：stage、attempt、elapsedMs、recoverable；
- hostInfo：serverUuid、name、serverGeneration、capabilities；
- pairingRequired：pinLength、legacyCrypto、certificateFingerprint；
- appCatalog：apps、catalogVersion、updatedAt；
- streamNegotiated：codec、width、height、fps、bitrateKbps、audioChannels、hdr、colorSpace；
- firstFrame、audioReady、inputReady；
- stats：rttMs、jitterMs、packetLoss、fecRecovered、decodeQueue、audioUnderrun、bitrate；
- inputState：keyboardCaptured、mouseCaptured、gamepads；
- surfaceState：attached、detached、rebindRequired；
- recoverableError、fatalError；
- stopped：reason、cleanupSummary。

所有事件携带 sessionId、generation、monotonicTimestamp。ArkTS 收到旧 generation 事件时静默丢弃并记录计数，不回滚当前 UI。

## 5. 分阶段实施路线

### 5.1 依赖顺序和交付物

下表是可以实际排期和验收的升级路线。每一阶段都必须先满足退出条件，才允许下一阶段把能力暴露给用户。

| 阶段 | 目标 | 主要交付物 | 前置条件 | 退出条件 |
| --- | --- | --- | --- | --- |
| P0 方案与探针 | 锁定上游、许可证、API23 能力和测试主机 | 上游 commit/ENet lock、合规清单、OH_AVCodec/OHAudio/Input/Game Controller 探针报告 | 无 | 双 ABI 编译；至少一台真机完成能力矩阵；阻断项明确 |
| P1 native 基座 | 把 common-c 接入现有 NAPI 而不污染旧协议 | moonlight 静态目标、平台回调、session owner、callback gate、feature flag | P0 通过 | 无 Moonlight 时旧 RDP/VNC/RustDesk/SSH 编译和测试结果不回退 |
| P2 主机控制面 | 完成发现、serverinfo、配对、目录、启动/停止 | HostApi、TLS pin、PIN flow、app catalog、可达性诊断 | P1 | Sunshine 真实主机完成配对、列出应用、启动和停止 |
| P3 串流控制面 | 完成 RTSP/SDP、端口、能力协商和 common-c 流启动 | StreamConfig、阶段事件、IPv4/IPv6、TCP/UDP 探测、取消/重试 | P2 | 收到合法首个视频/音频/控制流；所有错误能回到明确 stage |
| P4 视频 MVP | H.264 1080p60 硬解和 Surface 生命周期 | DECODE_UNIT bridge、配置帧、FEC/丢包统计、IDR 恢复、PIP rebind | P3 | 连续 30 分钟局域网串流；页面重建/PIP/后台切换后可恢复首帧 |
| P5 音频 MVP | Opus stereo 低时延播放 | Opus decoder、PCM adapter、OHAudio、音频焦点、underrun 统计 | P3 | 视频音频同步稳定；焦点丢失、后台、断连不残留播放 |
| P6 输入 MVP | 键鼠、触摸、实体手柄和基本反馈 | InputBridge、按键释放保险、控制器映射、rumble 能力门 | P3、Game Controller probe | 至少两类手柄、触摸多点、键鼠在真实主机可用；页面退出无悬挂输入 |
| P7 会话产品化 | 做好前后台、网络切换、重连、退出和资源回收 | lifecycle state、PIP、后台任务、reconnect policy、诊断页 | P4-P6 | 20 次 connect/disconnect/rebind 循环无 native 崩溃和旧画面 |
| P8 数据和 UI | 加入独立主机、应用、设置和单云表 | Moonlight model/policy/pages、moonlightrecord、云冲突处理、功能开关 | P2、P7 的接口稳定 | 新用户和老用户都能完成从添加到串流；云开关关闭时不产生上传 |
| P9 硬化与发布 | 兼容、性能、安全、合规和灰度 | fuzz、网络矩阵、功耗/温控、SBOM、第三方 notice、源码包、发布开关 | P0-P8 | 第 13 节所有 release gate 通过 |

### 5.2 P0 的具体决策清单

P0 不能只写“评估完成”，必须产出以下可审计结论：

1. Moonlight-common-c 的具体 commit、仓库 URL、许可证、所有子模块 revision 和 SHA-256。
2. 是否引入 upstream 的 ENet 以及其许可证、构建选项、IPv6 修复和 ABI 约束。
3. API23 对 H.264/HEVC/AV1 Surface 解码、Opus、OHAudio、Game Controller 的实际 probe 结果。
4. 至少一台 Sunshine 主机的版本、操作系统、显卡编码器、开放端口和配对结果。
5. 产品支持矩阵：MVP 必须支持的 codec、分辨率、帧率、音频声道、输入类型和网络类型。
6. 不支持矩阵：HDR、AV1、7.1、公网、WOL、legacy SHA-1、虚拟手柄等是否在首版关闭。
7. 设备私钥的安全存储方式、云端 secret 的端到端加密方式和账号退出清理规则。
8. AppGallery、企业分发或开源发布需要随 HAP 提供的 source offer、SBOM、notice 和许可证文件。

任何一项没有证据，都只能标记为 pending，不能在设置项里显示为已支持。

### 5.3 代码落点规划（实施时才创建）

以下是后续实施建议的文件边界，不是本轮要创建或修改的文件：

| 层 | 建议目录/文件 | 说明 |
| --- | --- | --- |
| upstream | entry/src/main/cpp/moonlight/upstream | 只放锁定的 common-c 和 ENet，保留原始 license/header |
| core | entry/src/main/cpp/moonlight/core | session、host API、transport、stage、stats |
| media | entry/src/main/cpp/moonlight/media | video bridge、Opus bridge、clock、surface |
| input | entry/src/main/cpp/moonlight/input | keyboard/mouse/touch/gamepad/feedback |
| platform | entry/src/main/cpp/moonlight/platform | socket、TLS、clock、thread、secure store、OHOS callback |
| NAPI | entry/src/main/cpp/moonlight/moonlight_napi.cpp | 稳定的 ArkTS 出口和事件序列化 |
| ArkTS model | entry/src/main/ets/model/Moonlight*.ets | host、profile、settings、session snapshot |
| ArkTS policy | entry/src/main/ets/services/Moonlight*Policy.ets | capability、route、record、settings、lifecycle |
| ArkTS service | entry/src/main/ets/services/Moonlight*.ets | host discovery、pairing、catalog、session、cloud adapter |
| UI | entry/src/main/ets/pages/Moonlight*.ets、components/moonlight | 添加、目录、详情、设置、HUD、诊断 |
| tests | entry/src/test/Moonlight*.test.ets、entry/src/main/cpp/moonlight/tests | policy、NAPI contract、parser、生命周期和回归 |

Moonlight 的 native 依赖、头文件和 NAPI 出口都应在这个边界内。现有 ProtocolAdapter 可以在最终产品层被 MoonlightSession 适配，但不应让 common-c 依赖 ProtocolAdapter 的 generic username/password、单 buffer VideoFrame 或 PCM-only AudioData。

### 5.4 风险、回滚和 feature flag

- 首次合入只在隐藏 feature flag 下可见；旧协议路径不改变。
- 主机控制面、视频、音频、手柄、PIP、云 secret 分别设置能力 flag，任一子能力失败不会伪装成整项可用。
- 如果 common-c 依赖或 API23 解码器导致构建/运行时风险，回滚边界是移除 Moonlight static target、NAPI export 和 ArkTS route；不得回滚已有 RDP/VNC 的 decoder/audio 改动。
- 如果云表迁移失败，停止新增 Moonlight 上云，保留本地 mirror 和用户手动导出；不能删除已有 cloud rows。
- 如果某个手柄驱动导致崩溃，先关闭该 device profile 的 Game Controller capability，不关闭视频和键鼠。

## 6. ArkTS 模型、服务和状态机

### 6.1 独立领域模型

Moonlight 不应复用 RemoteHost 的所有字段。建议后续定义下列模型：

| 模型 | 核心字段 | 说明 |
| --- | --- | --- |
| MoonlightHost | id、serverUuid、displayName、addresses、port、hostType、lastSeen、pairingState、trustState、wakeOnLan | 一台主机，不等于一个应用 |
| MoonlightApp | appId、title、iconRef、sortOrder、available、lastCatalogAt | 主机目录的可刷新缓存；图标可本地缓存，不默认进入云 payload |
| MoonlightProfile | id、hostId、appId、titleSnapshot、streamOverrides、inputOverrides、lastUsedAt | 一个主机应用的用户启动入口 |
| MoonlightSettings | video/audio/input/network/background/security/diagnostics | 全局默认值，按 profile 覆盖 |
| MoonlightPairingState | paired、legacy、certificateFingerprint、pairedAt、lastValidatedAt | 不包含 PIN；私钥只通过 secure store 引用 |
| MoonlightCapability | host、device、network、session 四类能力 | 每项带 source、version、reason、expiresAt |
| MoonlightSessionSnapshot | sessionId、hostId、profileId、stage、codec、dimensions、firstFrame、backgroundState、error | 用于 UI 恢复和诊断，不作为云端真相 |

### 6.2 状态机

~~~mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Discovering: 自动发现
  Idle --> ReachabilityChecking: 手动地址
  Discovering --> ReachabilityChecking: 找到主机
  ReachabilityChecking --> PairingRequired: 未配对
  ReachabilityChecking --> Paired: 已配对且证书有效
  PairingRequired --> Pairing: 输入 PIN
  Pairing --> Paired: challenge 成功
  Pairing --> PairingRequired: PIN 错误或超时
  Paired --> LoadingApps: 请求目录
  LoadingApps --> Ready: 目录成功
  Ready --> Launching: 选择应用
  Launching --> Negotiating: launch 成功
  Negotiating --> StartingMedia: RTSP/SDP 成功
  StartingMedia --> Streaming: video/audio/input ready
  StartingMedia --> VideoOnly: 音频被用户关闭或设备不支持
  Streaming --> Reconnecting: 可恢复网络错误
  VideoOnly --> Reconnecting: 可恢复网络错误
  Reconnecting --> Negotiating: 退避后重试
  Reconnecting --> Failed: 超过重试预算
  Streaming --> BackgroundPreserved: 切后台/PIP
  BackgroundPreserved --> Streaming: 前台并重新绑定 Surface
  Streaming --> Stopping: 用户停止或主机退出
  VideoOnly --> Stopping: 用户停止或主机退出
  Stopping --> Idle: cleanup 完成
  Failed --> Idle: 关闭错误页
~~~

对现有 RemoteSessionState 的集成建议：

- 通用 phase 继续表达 connecting、connected、backgroundPreserved、disconnecting；
- Moonlight 专属 stage 作为 protocolSubstate 保存，不让 HostListPage 依赖 common-c 细节；
- connected 只有在至少首个视频关键帧已经提交、音频状态已判定、输入状态已判定后才能出现；
- VideoOnly 必须是显式降级状态，而不是把 AudioReady 永远设为 true；
- 页面销毁不等于会话停止：若进入 PIP/后台保活，保存 snapshot 并执行 surface detach；
- 每次重连生成新的 generation，旧 stage、旧 app catalog 和旧 error 不得覆盖新会话。

### 6.3 重连和错误模型

错误应归一为可行动的 code、stage、userMessage、technicalReason、retryable、suggestedAction：

| 错误类别 | 示例 | 默认动作 |
| --- | --- | --- |
| HOST_UNREACHABLE | DNS、TCP 端口、地址族均失败 | 显示地址/端口检查，允许编辑 |
| PAIRING_REQUIRED | 未配对或证书不存在 | 进入配对页 |
| PAIRING_REJECTED | PIN 错、主机未确认 | 保留主机，清理临时 PIN，允许重试 |
| TRUST_CHANGED | 证书指纹改变 | 阻断连接，要求用户重新确认/配对 |
| CATALOG_FAILED | serverinfo 成功但目录失败 | 保留旧目录并允许重试，不启动未知 app |
| RTSP_FAILED | SDP、能力、端口协商失败 | 显示主机/版本/端口原因 |
| UDP_UNREACHABLE | TCP 成功但媒体无包 | 进入网络诊断，禁止无限重试 |
| CODEC_UNSUPPORTED | 设备或主机 codec 不支持 | 回退 H.264 或降低设置 |
| AUDIO_FAILED | Opus/OHAudio 失败 | 询问是否无音频继续 |
| INPUT_FAILED | 输入通道失败 | 可视频观看，显示输入不可用 |
| SURFACE_REBIND_FAILED | PIP/页面重建失败 | 回前台重建 renderer，必要时请求 IDR |
| HOST_APP_EXITED | 主机应用退出 | 清理并返回 app catalog |
| SESSION_CANCELLED | 用户主动取消 | 静默清理，不显示错误 |

重连策略建议：

- 只对网络短暂断开、Surface 重建、音频焦点恢复等可恢复原因重试；
- 采用 0.5、1、2、4、8 秒退避并设置总预算，用户主动停止立即取消；
- 重连前停止旧 RTP/RTSP 和输入，不能在同一个 common-c session 上叠加第二次 start；
- 重连成功后以关键帧为恢复边界，不能把旧视频帧重新送入新 decoder；
- 连续失败后保留最近一次诊断快照，并提供“复制诊断信息”但脱敏主机地址、证书和 secret。

## 7. 单张云同步表设计

### 7.1 物理表边界

Moonlight 只增加一张云端业务表：

- 云端物理表：moonlightrecord
- 本地镜像表：moonlightlocalrecords

本地镜像不是第二张云业务表；它只用于离线启动、journal、冲突暂存和待上传状态。不得另建 moonlightsettings、moonlighthosts、moonlightapps、moonlighttrust 或 moonlightsecrets 云表。应用目录和诊断数据默认是本地缓存，不进入云同步表。

CloudSyncPolicy 后续只增加 moonlightrecord 的表级注册和权限判断。所有逻辑记录通过 recordType 区分，和当前 VNC 的单表 envelope 思路一致，但 Moonlight 必须拥有自己的 schemaVersion、校验器和 secret 规则。

### 7.2 表结构

第一版沿用当前 VNC 记录已经验证过的 19 列 envelope 结构，字段定义如下：

| 列 | 类型建议 | 约束和用途 |
| --- | --- | --- |
| id | string | 全局唯一稳定 ID；不可用 host name 代替 |
| userid | string | 云账号/用户作用域 |
| recordtype | string | settings、host、profile、trust、secret |
| ownerid | string | 记录归属的用户/设备/主机/配置 ID |
| ownertype | string | user、device、host、profile |
| secretkind | string | none、serverTrust、clientIdentity、sessionToken 等 |
| payload | string | 非敏感或已按策略处理的规范化 JSON |
| ciphertext | string | 加密后的 secret envelope；非 secret 记录为空 |
| envelopeversion | number | 当前 envelope 格式版本 |
| cryptoversion | number | 加密算法/派生方式版本 |
| keyversion | number | 云端用户密钥版本 |
| aadversion | number | AAD 组成规则版本 |
| payloadhashsha256 | string | 规范化明文/密文载荷的完整性 hash |
| syncversion | number | 同一记录的单调同步版本 |
| schemaversion | number | Moonlight 业务 JSON schema 版本 |
| resetepoch | number | 用户重置/重新配对后的 epoch，优先级高于 syncversion |
| createdat | number | 创建时间，服务端写入或可信客户端时间 |
| updatedat | number | 最后变更时间 |
| deletedat | number/null | tombstone 时间；删除不是物理立即删除 |

所有列名、大小写和 nullable 规则在实施前必须与当前 CloudStore 的实际 schema migration 机制对照；计划不允许擅自复制一个看似相同但实际不兼容的表。

### 7.3 recordType 规范

#### settings

全局默认值，允许云同步：

~~~json
{
  "schemaVersion": 1,
  "video": {
    "codecPreference": "auto",
    "resolutionMode": "host",
    "fps": 60,
    "bitrateKbps": 20000,
    "hdr": false
  },
  "audio": {
    "enabled": true,
    "channels": "stereo",
    "volume": 1.0
  },
  "input": {
    "touchMode": "touch",
    "captureKeyboard": false,
    "enableRumble": true
  },
  "network": {
    "discovery": "manualOrMdns",
    "allowLegacySha1": false
  },
  "background": {
    "allowPip": true,
    "allowAudioInBackground": true
  }
}
~~~

#### host

保存主机身份和可达性，不保存 PIN：

~~~json
{
  "schemaVersion": 1,
  "serverUuid": "host-generated-uuid",
  "displayName": "Living Room PC",
  "addresses": [
    {"host": "192.0.2.10", "family": "ipv4", "port": 47989}
  ],
  "preferredAddress": "192.0.2.10",
  "hostType": "sunshine",
  "wakeOnLan": {
    "enabled": false,
    "mac": null,
    "broadcast": null
  },
  "lastSeenAt": 0,
  "catalogVersion": 0
}
~~~

#### profile

一个稳定的主机应用入口；应用目录本身不需要每次云同步：

~~~json
{
  "schemaVersion": 1,
  "hostId": "host-record-id",
  "appId": "sunshine-app-id",
  "titleSnapshot": "Game",
  "streamOverrides": {
    "codecPreference": "h264",
    "resolution": "1920x1080",
    "fps": 60,
    "bitrateKbps": 25000
  },
  "inputOverrides": {
    "controllerSlot": 0,
    "mouseMode": "relative"
  },
  "lastUsedAt": 0
}
~~~

#### trust

保存可公开展示但不可静默替换的信任材料：

~~~json
{
  "schemaVersion": 1,
  "hostId": "host-record-id",
  "serverCertificateSha256": "hex-or-base64-fingerprint",
  "pairingGeneration": 7,
  "trustState": "trusted",
  "trustedAt": 0,
  "lastValidatedAt": 0,
  "sourceDeviceId": "device-local-id"
}
~~~

如果 trust 跨设备同步，首次在新设备使用时仍要执行本地确认或重新验证；云端的 trust 记录不能绕过证书变更保护。

#### secret

只有用户显式打开“同步 Moonlight 配对身份”，并且用户密钥和端到端加密能力就绪时才创建。payload 只放元信息，私钥和客户端证书进入 ciphertext；禁止放 PIN、明文私钥、可复用 session token。

### 7.4 加密、AAD 和同步规则

Moonlight 应复用项目现有 DataCrypto/CloudStore envelope，但不能把 VNC 的 owner、secretKind 或 payload 直接当作 Moonlight 语义。每条记录的 AAD 至少包括：

- cloud table name；
- recordType；
- id；
- ownerId；
- schemaVersion；
- envelopeVersion；
- cryptoVersion；
- keyVersion；
- aadVersion；
- resetEpoch。

建议规则：

1. settings、host、profile：规范化 JSON 放 payload，使用 payload hash 做完整性校验；地址、server UUID 等仍按项目整体数据保护策略决定是否整体加密。
2. trust：至少对记录做完整性保护；证书指纹不作为私钥处理，但证书变更必须可审计。
3. secret：只写 ciphertext；本地 secure store 引用、设备 ID 和恢复状态写入 payload。
4. 禁止把任何密码、PIN、私钥、access token、调试抓包数据写入普通 payload。
5. 密钥轮换只改变 keyVersion/cryptoVersion，不改变 record ID；迁移失败时保留旧 ciphertext 并标记待迁移。
6. 用户关闭 secret sync 时，先停止新 secret 上传，再按当前云数据删除/撤销策略生成 tombstone，不直接删除本地仍在使用的私钥。

冲突选择器必须沿用已存在的稳定规则：resetEpoch 较大者优先，其次 syncVersion、updatedAt、id；同值必须得到确定性结果。secret 冲突不能静默覆盖，应进入配对恢复/用户选择页。

### 7.5 云同步生命周期

| 时点 | 行为 |
| --- | --- |
| 登录/打开云同步 | 拉取 moonlightrecord schema，验证 envelope/hash，创建本地镜像 |
| 打开 Moonlight 页面 | 云优先合并 settings/host/profile；secure secret 由本机优先，云 secret 只进入待恢复状态 |
| 添加/编辑主机 | 先写本地 journal，再按 selectedTables 和用户授权上传 |
| 配对成功 | 默认只更新本地 secret/trust；若用户开启 secret sync，显示明确确认后才上传 |
| 主机目录刷新 | 更新本地 app cache，不自动刷新云 profile 的 titleSnapshot，避免无意义写放大 |
| 删除主机 | host、profile、trust 按关联关系生成 tombstone；secret 先撤销使用再处理 |
| 账号退出 | 停止上传、清理 session token、解除本机云密钥；用户选择保留还是删除本地配对身份 |
| 多设备冲突 | 先合并非 secret；secret 冲突阻断使用并要求重新配对或选择版本 |
| 云端异常 | 保持本地可用，显示待同步；不得因为云失败阻断已配对的局域网串流 |

Malformed row、未知 recordType、schema 过新、hash 不匹配和 AAD 不匹配都应进入隔离队列，不能被当作空记录覆盖。CloudSyncCoordinator 必须能报告每类计数和最近错误。

## 8. UI、用户逻辑和设置项

### 8.1 入口和信息架构

现有 HostProtocolPicker 已有 RDP、RustDesk、SSH、VNC。Moonlight 建议放在 VNC 之后，保持已有入口顺序稳定，并以独立页面流承载：

- Moonlight 添加主机页；
- 主机详情页；
- 应用目录页；
- 应用 profile 编辑页；
- 配对页；
- 串流设置页；
- 串流内 HUD/控制中心；
- 网络与协议诊断页。

不要把 Moonlight 的应用目录塞进通用 HostListPage 的“连接主机”按钮里。HostListPage 只显示主机摘要和最近使用的 profile；点击 Moonlight 主机进入其 app catalog，点击 app profile 才启动串流。

### 8.2 新增主机完整流程

1. 用户点击新增资源，选择 Moonlight。
2. 页面展示“自动发现”和“手动输入地址”两个入口，并说明需要主机运行 Sunshine 或兼容 GameStream 服务。
3. 自动发现显示主机名、局域网地址、最近发现时间和可达性；发现结果必须去重 serverUuid。
4. 手动添加校验地址、端口、IPv4/IPv6 格式，并提供网络测试，不直接保存错误地址。
5. 读取 serverinfo；若未配对，进入配对说明页，提示用户在主机端确认 PIN。
6. PIN 页四格输入、自动聚焦、粘贴支持、倒计时、重试和取消；输入完成后不自动重复提交。
7. 配对成功后展示服务器证书指纹摘要、主机名和“信任此主机”确认。
8. 拉取应用目录，显示加载、空目录、部分失败和旧缓存四种状态。
9. 用户可选择一个 app，创建默认 profile；首次只保存 host/profile，不强迫用户立刻调整全部串流设置。
10. 进入主机详情，提供“立即启动”“刷新应用”“编辑主机”“重新配对”“删除主机”。

如果主机响应成功但 UDP 未验证，主机可以保存，app catalog 可以浏览，但“启动”前必须给出网络风险提示。这样用户不会因录入主机失败而误以为 UI 已经保证串流。

### 8.3 主机卡片和应用目录

主机卡片显示：

- Moonlight 图标和协议标签；
- 主机显示名、最近成功地址、在线/未知/未配对状态；
- 配对状态和证书变更警告；
- 最近使用的应用 profile；
- 最近一次视频 codec、分辨率、帧率和延迟摘要；
- 待同步/本地未同步标记；
- 更多菜单：编辑、刷新目录、重新配对、网络诊断、删除。

应用目录显示：

- 应用图标、标题、最近使用时间、上次串流设置摘要；
- 主机正在运行/不可用/目录过期状态；
- 刷新、搜索、排序和隐藏应用；
- “启动并使用默认设置”“启动前选择设置”两个明确动作。

图标和目录是缓存数据，缓存失效不应删除 profile；应用 ID 失效时 profile 显示“主机已不再提供此应用”，禁止向主机发起未知 launch。

### 8.4 串流内 UI

默认画面应尽量无干扰，支持以下入口：

- 顶部轻量状态条：连接质量、延迟、视频/音频、输入捕获和电量；
- 单击显示 HUD，超时自动隐藏；
- 边缘滑出控制中心：暂停/继续、断开、音频、输入、画面、PIP、诊断；
- 鼠标捕获/释放按钮；
- 键盘按钮和系统快捷键面板；
- 触摸模式切换：触摸、绝对鼠标、相对鼠标；
- 手柄面板：当前设备、槽位、重新映射入口、rumble 开关；
- 网络差时只展示可行动提示，不频繁遮挡游戏画面；
- 断连时保留最近一帧但覆盖明确的重连/退出按钮，防止用户误以为仍在运行。

横屏是游戏串流的推荐布局，但不能在系统不允许或用户关闭自动旋转时强制旋转。切换旋转时先锁定输入映射，再等待新 Surface 绑定和首帧，避免触摸坐标与画面错位。

### 8.5 设置分层和默认值

设置必须明确作用域：全局默认、主机默认、app profile 覆盖、当前会话临时值。临时值不自动写云，用户点击“保存为此应用默认”才写 profile。

| 分组 | 设置项 | 推荐默认/范围 | 依赖和说明 |
| --- | --- | --- | --- |
| 串流基础 | 编码偏好 | Auto | H.264 为可靠回退；不可用 codec 不显示为可选 |
| 串流基础 | 分辨率 | Host recommended | 预设 720p/1080p/1440p/4K 由 host/device 能力裁剪 |
| 串流基础 | 帧率 | 60，必要时 30 | 必须与主机和设备能力共同裁剪 |
| 串流基础 | 码率 | Auto | 提供低/中/高和自定义；提示码率影响 UDP 和功耗 |
| 视频 | HDR | 关闭 | 仅 capability 全链路通过后显示 |
| 视频 | YUV 4:4:4 | 关闭 | 仅专业/验证设备显示 |
| 视频 | 低延迟/平滑 | 低延迟 | 影响 jitter buffer 和 decoder queue；显示取舍 |
| 音频 | 音频 | 开启 | 失败可在会话内降级为无音频 |
| 音频 | 声道 | Stereo | 5.1/7.1 只在设备和主机都支持时显示 |
| 音频 | 音量/静音 | 100%/否 | 应受系统音量和 AVSession 控制 |
| 输入 | 键盘捕获 | 手动开启 | 避免打开页面就吞掉系统快捷键 |
| 输入 | 鼠标模式 | 相对 | 可切换绝对、触摸模拟 |
| 输入 | 触摸模式 | 触摸 | 多点触摸保留 id；兼容模式可转鼠标 |
| 输入 | 控制器槽位 | Auto/1 | 多手柄时允许显式选择 |
| 输入 | Rumble | 开启 | 设备不支持时显示 unavailable |
| 网络 | 自动发现 | 开启 | mDNS 失败不影响手动连接 |
| 网络 | 首选地址族 | Auto | IPv4/IPv6 失败后可回退 |
| 网络 | 允许 legacy SHA-1 | 关闭 | 用户主动开启并显示风险 |
| 网络 | 公网/非本地连接 | 关闭提示 | 只改变提醒，不提供中继承诺 |
| 后台 | PIP | 开启 | 以系统能力和首帧为前提 |
| 后台 | 后台音频 | 开启 | 需要合法 AVSession/后台准入 |
| 安全 | 证书变更 | 阻断 | 不提供“永远信任” |
| 安全 | 保存配对身份 | 仅本机 | 使用安全存储；删除主机时二次确认 |
| 云 | 同步 host/profile/settings | 开启 | 受 selectedTables 和账号状态控制 |
| 云 | 同步 trust | 用户确认 | 跨设备仍需本地信任确认 |
| 云 | 同步配对身份 | 关闭 | 需要端到端加密和单独确认 |
| 诊断 | 统计 overlay | 关闭 | 开启后展示 RTT、丢包、FEC、decode 和 underrun |
| 诊断 | 日志级别 | Error | Debug 需要明确提示可能包含网络元数据 |

UI 必须根据 capability 隐藏或禁用设置，并显示原因。例如“AV1：设备解码器不可用”“7.1：当前输出设备只有双声道”，不能让用户保存一个永远失败的组合。

### 8.6 配对、云同步和删除的用户确认

需要确认的高影响动作：

- 重新配对会使旧 client identity 失效；
- 信任新证书会改变后续 TLS 验证对象；
- 同步配对身份会把高敏感凭据复制到云端；
- 删除主机会同时删除 profile、trust 和可选 secret；
- 关闭云同步是否保留本地记录；
- 清除应用数据是否包括本地私钥。

所有确认页都要告诉用户影响范围、可恢复性和是否会影响其他设备。普通“删除 host”不应直接删除用户账号下其他 Moonlight 主机。

## 9. 全用户流程和生命周期

### 9.1 生命周期总览

~~~mermaid
sequenceDiagram
  participant U as 用户
  participant A as ArkUI
  participant S as SessionService
  participant N as Native Moonlight
  participant H as Sunshine/GameStream
  participant C as CloudSync

  U->>A: 新增 Moonlight
  A->>S: discover 或 manualAdd
  S->>N: hostReachability
  N->>H: serverinfo
  H-->>N: identity/capabilities
  N-->>S: hostInfo 或 pairingRequired
  U->>A: 输入 PIN 并确认指纹
  A->>S: pair
  S->>N: pairing challenge
  N->>H: pair
  H-->>N: client identity/certificate
  N-->>S: paired
  S->>C: 同步 host/profile/settings
  U->>A: 选择应用并启动
  A->>S: startProfile
  S->>N: launch + LiStartConnection
  N->>H: RTSP/ENet/RTP
  H-->>N: video/audio/input streams
  N-->>S: firstFrame/audioReady/inputReady
  S-->>A: streaming
  U->>A: PIP/切后台/返回前台
  A->>S: detach 或 rebindSurface
  S->>N: pause/resume/rebind/requestIDR
  U->>A: 停止
  A->>S: stop
  S->>N: release input/media/control/RTSP
  N->>H: quit/cancel
  N-->>S: cleanup complete
  S-->>A: idle
~~~

### 9.2 安装、升级和首次打开

安装或升级时：

1. 不迁移到现有 RDP/RustDesk/VNC 记录；没有 Moonlight 数据时不创建空 host。
2. 只做本地 schema/version probe 和 cloud table capability probe，不主动上传默认 settings。
3. 在设置中显示 Moonlight 为“实验/待启用”或正式能力，取决于 P9 release gate。
4. 首次进入时只询问必要的通知/后台/网络相关权限；不为了 mDNS 误申请相机、蓝牙或位置权限。
5. 如果系统不提供某项能力，页面直接说明影响，例如“可看视频但不能使用实体手柄”，而不是在启动后才失败。
6. App 升级不自动删除配对身份；如果安全策略需要重新配对，必须在升级说明中告知，并保留可恢复的 host/profile 元数据。

### 9.3 主机添加、配对和目录

添加过程的持久化顺序：

1. 用户输入通过本地校验；
2. 创建 host 草稿，只写本地；
3. serverinfo 成功后补齐 serverUuid 和 hostType；
4. 配对成功后写 trust 和 secure identity；
5. 目录成功后写本地 app cache；
6. 用户确认保存后写 profile；
7. 云同步按 recordType 和用户授权异步执行。

任何中途取消都应删除草稿和临时 PIN，不删除已存在的其他主机。配对失败超过重试预算时，保留 host 草稿但标记 unpaired，允许用户稍后继续。

### 9.4 启动串流

启动前检查顺序：

1. host record 完整且地址可解析；
2. trust record 存在且证书 fingerprint 未变化；
3. secure identity 可用，或者用户选择重新配对；
4. appId 仍在最近目录中，目录过期时先刷新或明确允许使用缓存；
5. 设备 codec/audio/input capability 已探测；
6. profile override 与 host/device capability 合并；
7. 计算最终 StreamConfig，并向用户展示必要的降级；
8. 创建 sessionId/generation，锁定输入 owner；
9. 调用 host launch，再进入 common-c connection stages；
10. 直到首个视频关键帧和音频状态已经判定，才把主页面标成 streaming。

启动过程中用户可以取消。取消必须可打断 DNS、HTTP、PIN 等待、RTSP、UDP 建流和解码队列，不应等固定超时后才响应。

### 9.5 前台、后台、PIP、锁屏和设备旋转

前台：

- Surface attach 后才允许渲染；
- surface generation 变化时停止向旧 surface 提交；
- 请求关键帧而不是复用旧帧；
- 保留网络连接的前提是系统后台和用户设置允许。

PIP：

- 只有首帧成功、decoder ready、尺寸有效、系统 PIP capability 通过时才进入；
- HUD 只保留暂停/返回/停止等有限动作；
- 页面侧边手势和游戏触摸不应在 PIP 小窗口内误发给远端。

切后台：

- 背景任务服务只能保留被系统允许的任务；
- 视频没有可见 Surface 时采用暂停/丢弃策略，不能无限堆帧；
- 音频是否继续由后台音频设置、AVSession、系统焦点和功耗策略共同决定；
- 如果系统即将终止任务，先发送输入释放和 best-effort stop，再保存 snapshot。

回前台：

1. 绑定新 Surface；
2. 清空旧 video queue；
3. 重新检查 codec/surface；
4. 请求 IDR；
5. 等首帧；
6. 恢复输入捕获和 HUD；
7. 若失败则转 Reconnecting 或 Failed，并保留退出路径。

锁屏、电话、系统音频抢占、用户旋转和进程重建都要进入同一生命周期状态机，不能在页面 onAppear/onDisappear 中各自写一套隐式逻辑。

### 9.6 网络切换和异常

无线切换、蜂窝切换、IPv4/IPv6 地址变化时：

- 记录 network generation；
- 暂停新输入，发送按键/控制器释放；
- 判断现有 socket 是否仍有效，不在旧 socket 上盲目重试；
- 进入可恢复重连，重新做地址/端口/RTSP 协商；
- 让主机应用保持运行的时间受设置和重试预算限制；
- 恢复后以关键帧重新开始，不显示旧帧和新帧混杂。

异常主机退出时：

- 先停止 native session；
- 读取可选 quit/cancel 结果；
- 清理本地 decoder/audio/input；
- 标记 profile 的 lastExitReason；
- 返回 app catalog，允许用户再次启动，不自动重复 launch。

### 9.7 停止、删除、退出账号和卸载

正常停止顺序：

1. 禁止新的键鼠/触摸/手柄事件；
2. 对所有 down 状态发送安全 up/cancel；
3. 停止输入反馈；
4. 停止音频接收、flush Opus/OHAudio；
5. 停止视频接收、等待 in-flight decode callback；
6. 停止控制流和 RTSP；
7. 请求主机 quit/cancel，设置超时；
8. 解除 Surface、销毁 decoder、audio renderer、NAPI references；
9. 写 session metrics 和 lastUsed/lastExit；
10. 将 session 状态变为 idle。

删除 host 的级联规则：

- 删除 host 时同时处理 profile、trust、secret 的关联记录；
- app cache 和图标缓存按 hostId 清理；
- 正在串流时先阻止删除或要求先停止；
- 云端生成 tombstone，本地先隐藏；
- 如果 secret 正在被其他 profile 使用，先显示影响范围；
- 删除失败时保留待删除状态和重试入口，不把 UI 假装成已完成。

账号退出：

- 停止所有 Moonlight session；
- 清除云令牌、上传队列和待恢复 cloud secret；
- 按用户选择保留本地 host/profile，或清除包括私钥在内的本地数据；
- 下一账号不可读取上一账号的 ownerId 记录。

卸载/清除数据：

- 由系统生命周期负责本地文件清理；
- 发布文档说明云端 moonlightrecord 不会因卸载自动消失；
- 提供账号内删除云数据的明确入口；
- 任何导出文件都必须不包含明文私钥/PIN，且导入需要二次确认。

## 10. 测试、性能和诊断计划

### 10.1 单元、契约和 fuzz

native 层必须先建立不依赖真机 UI 的测试：

| 类别 | 测试内容 |
| --- | --- |
| Host API | serverinfo/applist/launch/quit 的 XML/HTTP 响应、未知字段、超时、证书错误 |
| Pairing | 现代 SHA-256、legacy SHA-1 开关、salt/PIN 边界、挑战失败、证书 pin |
| RTSP/SDP | 合法/截断/超长/重复 header、未知 codec、异常端口、重入和取消 |
| RTP/FEC | 顺序包、乱序包、重复包、丢包、FEC 恢复、reorder timeout、timestamp rollover |
| Decode unit | SPS/PPS/VPS 链、关键帧、配置变更、空 buffer、超大 frame、生命周期复制 |
| Audio | Opus stereo/multistream、坏包、时钟漂移、重采样、欠载、flush/restart |
| Input | key down/up 配对、触摸 id、鼠标溢出、控制器轴范围、断开释放、rumble 限流 |
| Session | 每个 stage 的取消、重复 stop、旧 generation 事件、线程退出和 callback gate |
| Security | 日志脱敏、私钥不可读、AAD mismatch、hash mismatch、secret sync 权限 |

RTSP parser、SDP parser、HTTP pairing parser 和 RTP/FEC 边界都应接入 fuzz。历史上 Moonlight common-c 曾出现 RTSP parser buffer overflow 安全公告，必须参考 [GHSA-4927-23jw-rq62](https://github.com/moonlight-stream/moonlight-common-c/security/advisories/GHSA-4927-23jw-rq62)，锁定包含修复的版本，并把该类输入加入持续 fuzz。

ArkTS 层测试：

- capability policy 的交集/降级；
- HostProtocolPicker、ResourceFabPicker、route 和返回栈；
- host/profile/trust/secret record validator；
- resetEpoch/syncVersion 冲突选择；
- malformed cloud row quarantine；
- background/PIP stage 的可见 UI；
- 取消、重试、删除、账号退出的状态转移。

### 10.2 真实主机矩阵

最低主机矩阵：

| 主机 | 目的 | 首版要求 |
| --- | --- | --- |
| Sunshine + NVIDIA | 主流硬编码和完整 Moonlight 兼容路径 | 必测 |
| Sunshine + AMD | 编码器、HDR/HEVC差异和 serverinfo | 必测或明确不支持 |
| Sunshine + Intel | 编码器 profile、AV1/HEVC差异 | 后续矩阵 |
| Sunshine Linux/Windows | OS 和服务端配置差异 | 至少各一台 |
| legacy GeForce Experience/GameStream | 旧 SHA-1、旧 serverinfo/配对和端口差异 | 仅在 legacy flag 开启时测试 |
| Sunshine 自定义应用 | launch 参数、退出和 appId 稳定性 | 必测 |
| 无应用/应用变更主机 | 空目录、删除应用、缓存失效 | 必测 |

每台测试主机要记录 Sunshine/GameStream 版本、操作系统、GPU、编码器、分辨率、开放端口、IPv4/IPv6、配对时间和日志摘要。不能只用一个开发者本机写“兼容 Sunshine”。

### 10.3 鸿蒙设备矩阵

最低设备矩阵：

- ARM64 手机：1080p60 H.264、旋转、后台、PIP、系统音频抢占；
- ARM64 平板/2in1：大屏布局、键鼠、实体手柄、外接显示或窗口变化；
- 至少两种不同芯片/系统补丁设备：codec profile、热管理和 OHAudio 差异；
- x86_64 开发环境：只作为编译/单元测试，不作为发布性能证据；
- 至少两类真实手柄和一类鼠标/键盘；
- 有能力和无能力设备都要记录 capability reason。

每次真机测试包含冷启动、warm start、进程被系统回收后的恢复、PIP、锁屏、切网、旋转、快速重复连接和用户取消。

### 10.4 网络和协议矩阵

| 维度 | 测试值 |
| --- | --- |
| 地址族 | IPv4、IPv6、双栈、NAT64、IPv4-only host、IPv6-only host |
| 发现 | mDNS 成功、mDNS 禁止、跨子网失败、手动地址 |
| RTT | 10、50、100、200 ms |
| 丢包 | 0%、1%、3%、5%、10% burst loss |
| 抖动 | 0、5、20、50 ms |
| MTU | 正常、低 MTU、IPv4/IPv6 分片风险 |
| 网络变化 | Wi-Fi AP 切换、Wi-Fi/蜂窝切换、地址刷新、临时断网 |
| 端口 | TCP 只通、UDP 只部分可达、全部可达、错误端口 |
| 主机负载 | 编码器满载、应用切换、主机睡眠/唤醒、主机退出 |

必须验证“TCP 能连接但 UDP 无包”这一最容易误判的情形，并让诊断页清楚显示：控制面可达、媒体面不可达、建议检查哪些端口。

### 10.5 性能和稳定性目标

以下是首版目标，不是当前已达成的数据：

- 局域网 H.264 1080p60 连续 30 分钟，视频无不可恢复黑屏/花屏；
- 稳定网络下视频帧率接近协商值，解码队列不持续增长；
- 局域网输入到显示的 p95 目标不高于 80 ms，具体以目标设备测量能力校准；
- 音频连续播放无持续 underrun，视频音频漂移在产品可接受范围内；
- 100 次启动/停止、Surface detach/attach、PIP/前后台循环无 native crash、句柄泄漏或旧画面；
- 应用目录和主机卡片操作不阻塞 UI；
- 在明确网络上限和设备温度上限内，内存、CPU、电量和温度曲线平台化；
- 丢包恢复时 CPU 和内存不因 FEC/重排无限增长；
- 诊断统计本身不明显增加渲染延迟，不把完整媒体包写入日志。

性能记录至少包括：glass-to-glass 或输入到显示测量方法、编码时间、网络 RTT/jitter、FEC recovery、decoder latency、render latency、audio queue、underrun、CPU、内存、温度和电量。没有统一测量方法的数据不能用于宣称低延迟。

### 10.6 可观测性和隐私

诊断快照应包括：

- app version、Moonlight/common-c commit、ENet revision、API23/设备型号；
- host type、server version、server UUID 哈希、地址族；
- stage 时间线和错误 code；
- stream codec、resolution、fps、bitrate、audio channels；
- RTT、jitter、loss、FEC、decode/render/audio counters；
- surface/audio/input lifecycle；
- cloud record sync status、schema/crypto version 和冲突计数。

默认不记录 IP 完整值、PIN、证书私钥、客户端证书内容、游戏名称之外的敏感主机配置、音视频包和输入内容。复制诊断信息前展示脱敏预览。

## 11. 开源、安全和发布合规

### 11.1 许可证和来源边界

当前仓库已有合规文档要求 combined app 按 AGPL-3.0-or-later 处理，并要求第三方 notice、SBOM、源代码提供和 exact revision。Moonlight-common-c 使用 GPL-3.0，且依赖固定 ENet 子模块；Moonlight Android/Qt 也包含 GPL 体系代码。实施时应以实际复制/链接的 revision 为准，由项目合规流程确认 AGPL/GPL 组合和发布形式，不因为“官方开源”就跳过审查。

必须执行：

1. 只引入 moonlight-common-c 真正需要的源文件和头文件，保留原始 copyright、LICENSE 和 URL。
2. Android/Qt 中只借鉴协议/业务逻辑；如复制任何源代码，记录 exact revision、文件、修改内容、许可证和 notice。
3. Sunshine 仅作为互操作测试主机，不打包服务端、其运行时或其配置密钥。
4. ENet 使用 upstream 要求的固定 revision，并在 SBOM 中单独列出。
5. 复用现有 Opus/OpenSSL 时核对当前 libs/opus-ohos、OpenSSL 和静态链接 notice；不得另引入无来源二进制。
6. 添加源代码 tag、源码归档、SBOM、第三方清单、许可证文件和构建 manifest。
7. 对外发布 HAP 前验证 clean clone 可按 SOURCE_OFFER 规则获得对应源代码和构建说明。

必须参考的本地规则：

- [LICENSE_DECISION_RECORD.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/LICENSE_DECISION_RECORD.md)
- [OWNERSHIP_AND_RELICENSING.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/OWNERSHIP_AND_RELICENSING.md)
- [THIRD_PARTY_SCOPE.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/THIRD_PARTY_SCOPE.md)
- [AGPL_RELEASE_ACCEPTANCE.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/AGPL_RELEASE_ACCEPTANCE.md)
- [SOURCE_OFFER.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/SOURCE_OFFER.md)
- [DEPENDENCY_UPDATE_POLICY.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/DEPENDENCY_UPDATE_POLICY.md)

### 11.2 安全要求

- 只接受包含已知 RTSP parser 修复的 common-c revision；
- 对 serverinfo、pairing、RTSP、SDP、XML 和 RTP 输入做长度、编码、边界校验；
- TLS 证书 pin 存在且匹配后才允许 launch/stream；
- legacy SHA-1 默认关闭，开启时标记风险、记录用户选择和主机代际；
- secret 永不出普通日志、崩溃报告、云明文 payload、导出文件；
- 配对身份和私钥用设备安全存储，明确删除、备份和恢复；
- 所有输入在网络切换、页面退出、停止、错误时发送释放/cancel；
- 防止恶意主机通过异常 SDP/codec/profile/尺寸造成内存、CPU 或磁盘资源耗尽；
- 诊断页不显示完整 client identity、私钥、PIN、session token；
- 云记录做 AAD/hash/schema 验证，未知版本隔离而非降级解析；
- fuzz、静态分析、ASan/UBSan 或鸿蒙等价工具可用时必须纳入 native 依赖更新验收。

## 12. 排期、并行工作流和阻断项

### 12.1 推荐排期

按一名 native/媒体工程师、一名 ArkTS/产品工程师和一名 QA/设备工程师的并行配置，保守估计 12 至 16 个日历周；如果 API23 Game Controller、硬解或后台能力需要平台适配，增加 2 至 4 周。

| 周期 | 工作 | 并行线 | 里程碑 |
| --- | --- | --- | --- |
| W0-W1 | P0 来源、license、API23 probe、Sunshine 主机准备 | QA 建立设备/网络基线 | Go/No-Go 1 |
| W2-W3 | P1 common-c/platform shim；P2 HTTP/serverinfo/pairing | ArkTS 画流程原型、错误模型 | 可配对可列目录 |
| W4-W5 | P2 launch/quit；P3 RTSP/SDP/端口/IPv6 | 云表 schema review | 真机收到媒体包 |
| W6-W7 | P4 H.264 bridge/Surface/IDR；P5 Opus/OHAudio | UI 主机/目录/配对页 | H.264 + Opus 首帧 |
| W8-W9 | P6 键鼠/触摸/手柄 | 设置和 session HUD | 可玩性闭环 |
| W10 | P7 前后台/PIP/切网/重连 | 诊断页 | 生命周期闭环 |
| W11 | P8 单表 sync、冲突和 secret opt-in | UI 接入真实 service | 双设备同步 |
| W12-W14 | P9 兼容、fuzz、性能、温控、合规 | 发布文档和源码包 | Release candidate |
| W15-W16 | 灰度、外部设备复核、修复和二次门禁 | 仅处理 blocker | 正式开放或继续隐藏 |

如果只有一名工程师，关键路径会明显变长，不建议同时开放 HEVC/AV1/HDR/手柄/云 secret；优先完成 H.264、Opus、键鼠/触摸、本地配对和生命周期。

### 12.2 首版、第二版和长期能力

| 能力 | 首版 | 第二版 | 长期/暂不承诺 |
| --- | --- | --- | --- |
| 主机 | Sunshine 现代版本、手动地址和 mDNS | legacy GameStream | 未验证的第三方服务端 |
| 视频 | H.264、720p/1080p、30/60 fps | HEVC、1440p/4K（设备门控） | AV1、HDR、YUV 4:4:4 |
| 音频 | Opus stereo | 5.1/7.1 降混或真实多声道 | 麦克风/语音回传 |
| 输入 | 键鼠、触摸、两类实体手柄、基础 rumble | 多手柄、LED、motion、高级映射 | 虚拟手柄完整编辑器 |
| 网络 | 局域网、IPv4/IPv6、手动端口 | 公网端口配置和诊断 | 云中继、TURN、自动穿透 |
| 生命周期 | 前台、PIP、受系统允许的后台音频 | 更完整的锁屏/系统恢复 | 不受系统限制的常驻后台 |
| 云 | host/profile/settings 单表同步，trust 可选 | 加密 secret 恢复 | 默认同步私钥 |

### 12.3 必须先解决的阻断项

以下任一项失败，就不能开始公开灰度：

1. API23 没有稳定的 H.264 Surface 解码；
2. common-c/ENet 依赖无法在项目双 ABI 和许可证边界内锁定；
3. 真实 Sunshine 主机无法完成配对和 RTSP/UDP 媒体；
4. native callback 在 Surface/页面销毁后仍能触发崩溃或旧帧；
5. 输入没有可靠的按键释放和控制器断开处理；
6. OHAudio 不能稳定播放 Opus PCM 或后台恢复不符合系统规则；
7. 单云表无法做到 malformed row 隔离、secret opt-in 和确定性冲突；
8. release source offer/SBOM/third-party notice 无法随版本交付。

## 13. 最终验收和仓库门禁

### 13.1 产品验收清单

公开开关前必须逐项打勾并留证据：

- [ ] 新用户能从新增 Moonlight 进入发现/手动添加、serverinfo、配对、指纹确认、应用目录和启动。
- [ ] 已配对用户能离线打开 host/profile，云端暂时不可用时仍可在本地可达网络串流。
- [ ] Sunshine 真实主机完成 H.264 + Opus + 键鼠/触摸/实体手柄闭环。
- [ ] H.264 首帧、关键帧恢复、FEC/丢包、Surface 重建和 PIP 通过。
- [ ] 音频焦点、系统音频抢占、后台、前台、停止不残留播放。
- [ ] 输入捕获、释放、页面返回、网络切换、主机退出无悬挂按键/轴/触摸点。
- [ ] 旧 RDP、RustDesk、SSH、VNC 的连接、渲染、设置和云同步无回归。
- [ ] Moonlight 只使用 moonlightrecord 一张云业务表，secret 默认不上云。
- [ ] 两台设备同时编辑 host/profile/settings 可确定性合并，secret 冲突不静默覆盖。
- [ ] 证书变更、legacy SHA-1、UDP 不通、codec 不支持、音频失败都有可行动文案。
- [ ] 诊断信息脱敏，崩溃和日志不包含 PIN、私钥、session token 或媒体包。
- [ ] 功耗、温度、内存、CPU、延迟和稳定性达到第 10.5 节目标，或明确记录例外。
- [ ] 许可证、SBOM、source offer、third-party notice、exact revision 和源码归档齐全。

### 13.2 仓库构建和审查门禁

本计划本身不修改代码，但一旦后续按计划实施任何代码、ArkTS、native、Rust、测试、配置或流程文件，都必须在交付前执行项目要求的两个 Hvigor 门禁：

~~~sh
cd RemoteDeskHarmonyOS
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
~~~

两项都成功后，才进入 native/ArkTS 测试、子 agent 复核、合规复核和合并。任何 SDK、签名、工具链、网络依赖或设备缺失都必须记为当前 blocker，不能用旧 session 的日志代替。

每个实现阶段还要执行：

- git diff --check；
- 双 ABI/native 构建和测试；
- ArkTS 单元/组件测试；
- 真机证据和测试主机日志；
- 依赖 revision、SHA-256、许可证和 SBOM 更新；
- 用户可见设置与实际 capability 的一致性检查；
- 变更只触及 Moonlight 目标文件及必要公共接口，旧协议回归结果可追溯。

### 13.3 本轮评估的落盘和变更边界

本轮只新增本文档，不修改现有源代码、配置、依赖、云表或测试。工作树中此前已有的 VNC、RustDesk、SSH、ArkTS 变更保持原样；后续实施必须另行立项、按仓库分支门禁推进。

## 14. 参考资料和本地证据

### 14.1 Moonlight/Sunshine 官方源码和文档

- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)
- [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Connection.c)
- [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h)
- [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/VideoStream.c)
- [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/AudioStream.c)
- [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)
- [moonlight-common-c license](https://github.com/moonlight-stream/moonlight-common-c/blob/master/LICENSE.txt)
- [Moonlight Android](https://github.com/moonlight-stream/moonlight-android)
- [Moonlight Android PairingManager](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/nvstream/http/PairingManager.java)
- [Moonlight Android NvHTTP](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java)
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt)
- [Moonlight Qt streaming session](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/session.cpp)
- [Sunshine](https://github.com/LizardByte/Sunshine)
- [Sunshine RTSP source](https://github.com/LizardByte/Sunshine/blob/master/src/rtsp.cpp)
- [Moonlight Setup Guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)
- [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions)
- [Moonlight WOL](https://github.com/moonlight-stream/moonlight-docs/wiki/WOL-%28Wake-On-LAN%29)
- [Moonlight common-c security advisory](https://github.com/moonlight-stream/moonlight-common-c/security/advisories/GHSA-4927-23jw-rq62)

### 14.2 鸿蒙官方能力资料

- [HarmonyOS Developer](https://developer.huawei.com/consumer/cn/develop/)
- [OHAudio playback](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5)
- [HarmonyOS Input Kit C headers](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/input-headerfile-V13)
- [Background Process Manager](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/js-apis-backgroundprocessmanager-V13)
- [HarmonyOS Distributed Database Codelab](https://developer.huawei.com/consumer/en/codelab/HarmonyOS-Distributed-Database/)

### 14.3 本项目代码和规则证据

- [README.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/README.md)
- [protocol_adapter.h](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/extensions/protocol_adapter.h)
- [extension_loader_napi.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/extensions/extension_loader_napi.cpp)
- [hw_decoder.h](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/render/hw_decoder.h)
- [hw_decoder.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/render/hw_decoder.cpp)
- [audio_player.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/audio_player.cpp)
- [input_handler.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/input_handler.cpp)
- [RemoteSessionState.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/RemoteSessionState.ets)
- [NativeSessionHandles.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/NativeSessionHandles.ets)
- [RemoteSessionPipLifecyclePolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/RemoteSessionPipLifecyclePolicy.ets)
- [RemoteSessionBackgroundTaskService.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets)
- [CloudSyncPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncPolicy.ets)
- [CloudSyncCoordinator.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncCoordinator.ets)
- [VncRecord.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/model/VncRecord.ets)
- [VncRecordPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/VncRecordPolicy.ets)
- [CMakeLists.txt](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/CMakeLists.txt)
- [module.json5](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/module.json5)

### 14.4 实施开始前的最终确认

真正开始编码前，负责人必须在计划 issue 或 ADR 中补齐：

1. common-c 和 ENet exact revision；
2. API23 probe 结果和真实设备清单；
3. Sunshine/legacy 主机支持边界；
4. client identity 本地安全存储 API；
5. moonlightrecord 云端 schema migration 版本；
6. secret sync 是否首版完全关闭；
7. PIP/后台的系统准入证明；
8. 发布合规负责人和 source offer 交付物；
9. 性能测量工具、阈值和失败处理；
10. feature flag、灰度用户和回滚开关。

在这些确认完成前，Moonlight 只能保持为本计划中的待立项能力，不能通过 UI 暗示已经可连接或已经兼容全部 Sunshine/GameStream 主机。

<!-- PLAN_BODY_END -->
