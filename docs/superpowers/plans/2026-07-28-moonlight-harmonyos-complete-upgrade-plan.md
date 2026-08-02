# RemoteDeskHarmonyOS Moonlight / Sunshine 串流能力完备升级计划

> 文档状态：完成三次深度评估，待后续立项实施
> 首次评估日期：2026-07-28；二次完成性审计日期：2026-07-29；第三次 HarmonyOS 人因/UI 审计日期：2026-08-01
> 当前评估快照：分支 codex/cloud-data-lifecycle-root-fix，HEAD d2f365c32；本地 main 23940521a
> 适用仓库：/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS
> 上游评估快照：moonlight-common-c e41355ea01670fd4c830b384009d31dd0339a705；Moonlight Android f10085f552b367cf7203007693d91c322a0a2936；Moonlight Qt 546cb72e32e5ac04bbc7e0b3a254176e5696685a；Sunshine 3893c5bcdadc5f0beaa127670531afbfd60519ea；MoonlightOH a48821e2d309c4282d79a053e6a85245eb438a7b
> 本轮变更边界：只更新本计划文件；不修改 ArkTS、C/C++、Rust、配置、依赖、云表、测试或构建流程代码。

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

二次完成性审计收口时工作区位于 `codex/cloud-data-lifecycle-root-fix`，HEAD 为 `d2f365c32`（`fix: persist cloud sync lifecycle state`），本地 `main` 为 `23940521a`，`origin/main` 为 `bfae6ef30`。评估期间现有活动任务先后落入账户作用域隔离和云同步生命周期持久化，覆盖本计划依赖的 account session、sensitive barrier、cloud-first/retry 状态和相关测试；工作树仍有多项用户已有修改/未跟踪文件，且数量可能随并行活动任务变化。本计划不接管、不覆盖、不整理这些变化，也不要求 stash、reset、切换分支或新建任务分支。

本轮只允许修改一个既有计划文件：

- /Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md

该快照用于证明本次评估确实结合了当前源码；它不是未来实施必须使用的代码基线。正式立项时必须重新记录当时的分支、HEAD、`main`、工作树和 API/依赖版本，并对本计划中的所有文件名和公共接口做一次漂移审计。

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
| 云同步 | entry/src/main/ets/services/CloudStore.ets、CloudSyncCoordinator.ets、CloudSyncLifecyclePolicy.ets | 显式表选择、持久生命周期状态、云优先启动、重试、journal、冲突阻断 | Moonlight 必须新增独立 physical table 和 logical record type，不可被普通 selectedTables 无上下文上传 |
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

### 1.5 二次完成性审计矩阵

本次二次审计不是只检查“是否提到某个主题”，而是检查每个主题是否同时具备现状证据、目标合同、实施顺序、失败策略、用户体验和验收门槛：

| 审计面 | 当前代码/官方证据 | 本计划必须形成的可执行结论 |
| --- | --- | --- |
| Moonlight 协议 | common-c、Android 配对/HTTP、Qt 产品能力、Sunshine 服务端 | exact revision、端口/加密/会话阶段、线程关闭顺序、兼容边界 |
| 媒体底层 | 当前 OH_AVCodec、NativeImage/Surface、OHAudio；API 23 SDK 头文件/库 | decode unit 桥、音视频加密、FEC、首帧、IDR、音频焦点、功耗和降级 |
| 输入 | 当前键鼠/触摸路径；API 23 Game Controller Kit | 多输入 owner、全量释放、实体手柄映射、虚拟控制、系统快捷键保护 |
| 生命周期 | 当前 RemoteSessionState、PIP、后台任务、NativeSessionHandles | 前后台、PIP、锁屏、旋转、切网、进程重建、停止和账户切换顺序 |
| 云和账户 | 当前 AccountScopePolicy、AccountSessionCoordinator、SensitiveDataBarrier、CloudStore/Coordinator | 单物理表、账户隔离、lease/generation、cloud-first、迁移隔离、secret 默认不上云 |
| UI 一致性 | Theme、BreakpointUtil、HostProtocolPicker、ResourceFabPicker、HostListPage、设置路由 | 复用现有 token、卡片、单 sheet、断点和动效；覆盖所有空/错/离线/同步状态 |
| 用户全生命周期 | 安装、首次使用、升级、跨设备、删除、退出、卸载 | 每个阶段的数据、权限、提示、恢复、隐私、失败和可撤销行为 |
| 发布质量 | 仓库构建门禁、合规文档、上游安全公告 | 双 ABI、真机/主机/网络矩阵、fuzz、SBOM、源码提供、灰度与回滚 |

只有本表所有行都能在后续章节找到明确合同和验收项，才可将本文件视为可执行升级计划。

## 2. Moonlight 官方实现与协议栈评估

### 2.1 代码边界：只取客户端核心，不搬运整套客户端

推荐的上游边界是官方 moonlight-common-c。它是 Moonlight 多平台客户端共享的 C 核心，已经包含连接编排、RTSP、控制流、视频流、音频流、输入流、FEC、重排、统计和回调接口；它不是完整的 ArkUI 客户端，也不是 Sunshine 服务端。实现时应锁定一个具体 commit，并把该 commit 使用的 ENet 子模块一并锁定，不能直接用系统 ENet 或任意版本的 vendored ENet。官方 README 明确指出其 ENet API/ABI 和 IPv6/可靠传输行为存在版本约束。

推荐直接采用的上游材料：

- [moonlight-common-c README](https://github.com/moonlight-stream/moonlight-common-c)
- [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Connection.c)
- [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Limelight.h)
- [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/VideoStream.c)
- [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/AudioStream.c)
- [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/InputStream.c)
- [moonlight-common-c CMakeLists.txt](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/CMakeLists.txt)

不建议直接移植以下部分：

| 来源 | 不直接移植的原因 | 可借鉴内容 |
| --- | --- | --- |
| Moonlight Android | Java/Android Surface、MediaCodec、Android Input、Activity 和 JNI 生命周期与 HarmonyOS 不同 | PairingManager、NvHTTP、JNI 回调的分层方式和错误语义 |
| Moonlight Qt | Qt、SDL、桌面窗口、Linux/Windows/macOS 输入和渲染路径与 ArkUI/XComponent 不同 | session 编排、设置分层、键鼠/手柄 UX、能力提示 |
| Sunshine | 它是服务端，不应打包进手机客户端 | serverinfo、配对、应用目录、RTSP/编码器兼容测试对象 |
| 任意第三方 Moonlight fork | 可能混入过时协议、不同许可证或未审计补丁 | 仅作为问题对照，不作为默认依赖 |

#### 本次实际审计的上游快照

| 项目 | 审计 revision/日期 | 本计划使用方式 |
| --- | --- | --- |
| moonlight-common-c | `e41355ea01670fd4c830b384009d31dd0339a705` | 协议、线程、媒体和输入的主要实现证据 |
| common-c ENet submodule | `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`，来源 `cgutman/enet` | 必须与 common-c 一起锁定；禁止替换成系统/任意 ENet |
| Moonlight Android | `f10085f552b367cf7203007693d91c322a0a2936` | 配对、NvHTTP、证书 pin、launch 参数和移动端生命周期参考 |
| Moonlight Qt | `546cb72e32e5ac04bbc7e0b3a254176e5696685a` | 设置能力、桌面输入、HDR/高阶 codec、产品诊断参考 |
| Sunshine | `3893c5bcdadc5f0beaa127670531afbfd60519ea` | 现代服务端互操作和测试环境参考；不打包 |
| MoonlightOH | `a48821e2d309c4282d79a053e6a85245eb438a7b`（2026-08-01 审计） | HarmonyOS 原生页面、输入、媒体和生命周期的人因/UI 可行性对照；不作为协议依赖或视觉资产来源 |

这些 revision 是“本计划评估过的证据快照”，不是未来实施时可无条件直接合入的依赖版本。P0 必须先比较新旧 revision、检查 security advisory、submodule、ABI/API、许可证和协议变化，再决定继续使用本快照还是升级；任何升级都要重新跑 parser/fuzz/真机/合规门禁。

#### 2.1.1 成熟 HarmonyOS Moonlight 项目的人因/UI 审计

第三次审计以 [MoonlightOH](https://gitee.com/smdsbz/moonlight-ohos) revision `a48821e2d309c4282d79a053e6a85245eb438a7b` 为主要 HarmonyOS 原生参考，并以 [likuai2010/moonlight-harmonyos](https://github.com/likuai2010/moonlight-harmonyos) 为历史对照。前者在 2026-04 仍有维护记录，使用 ArkUI、Navigation、XComponent、OH_AVCodec/OHAudio 和 native common-c 路径，公开源码/截图覆盖主机发现、手动添加、PIN 配对、应用目录、global→server→app 分层配置、连接阶段、触控/触控板、虚拟键盘、HDR/硬解和性能统计；后者公开进展主要集中在 2023–2024 年，适合作为早期 HarmonyOS 移植可行性证据，不作为当前交互基线。

本审计只吸收被源码和截图证明的鸿蒙交互模式，不复制其页面代码、视觉资产或产品声明：

| 参考能力 | 审计结论 | 本项目处理 |
| --- | --- | --- |
| mDNS 扫描 + 手动 IP/域名 | 原生鸿蒙可行，符合首次添加的两种心理模型 | 保留双入口，但进入本项目分步 Sheet，并增加权限解释、去重、地址族、端口、取消和错误就地恢复 |
| 主机→应用封面目录 | 符合 Moonlight 用户“先选主机，再选游戏/桌面”的任务模型 | 采用响应式目录；点击 app 先开启动确认/本次设置 Sheet，不直接发起不可撤销 launch |
| global→server→app 分层配置 | 与本计划 settings/host/profile 作用域一致 | 保留分层，增加来源标签、继承摘要、单项重置和“仅本次”临时覆盖，避免用户忘记当前修改作用域 |
| Touch / Trackpad 分段切换 | 经原生项目证明可用，且与本项目 VNC/RustDesk 控制模式一致 | 作为连接内一级快捷控制；模式切换后给出短文字反馈并清理旧手势状态 |
| 连接内虚拟键盘与性能统计 | 原生可行，也与本项目 RemoteModifierPanel/DiagnosticsHud 能力重叠 | 复用本项目键盘、修饰键、组合键和可拖动诊断 owner，避免再造第二套全屏键盘/统计浮层 |
| 固定黑底、`#111` 卡片和大量原始 Slider | 视觉只适合单一深色演示，参数密度和可发现性不足 | 拒绝照搬；全部使用 Theme/AppTheme、预设优先、能力裁剪、说明副标题和高级折叠 |
| 点击 app 立即串流 | 对熟练用户快，但容易在蜂窝网络、主机忙或 profile 变化时误启动 | 默认进入可一眼确认的 launch Sheet；可提供用户显式开启的“受信任局域网快速启动”偏好 |
| StageStarting/网络差均使用阻塞 LoadingDialog | 遮挡上下文、无法表达阶段、取消和降级 | 改成非模态阶段卡/遮罩；首帧前可取消，网络差只显示节流 banner，媒体中断才进入重连遮罩 |
| 侧滑删除、长按 app 才能配置 | 对触控发现性弱，鼠标/键盘也不一致 | 主动作可见，次要动作进入显式“更多”；长按/右键仅作为冗余快捷方式，不是唯一入口 |
| 返回键打开串流操作 Sheet | 能防止误退出 | 保留其意图，但与本项目规则统一：先释放鼠标捕获，再展开控制条，再显示断开确认；实体停止入口始终可见 |
| 后台隐藏后中断、显示后自动 resume | 能节省资源，但自动恢复可能重新发送媒体/输入 | 不直接采用；由 foreground/PIP/用户设置和 session generation 决定，恢复前输入保持锁定并请求新关键帧 |

HarmonyOS 设计依据以华为官方[设计指南](https://developer.huawei.com/consumer/cn/design/?catalogVersion=V1)、[设计入门](https://developer.huawei.com/consumer/cn/design/devstart/)、[焦点导航](https://developer.huawei.com/consumer/cn/doc/design-guides/hmi-focus-0000001748650376)、[光标交互](https://developer.huawei.com/consumer/cn/doc/design-guides/hmi-cursor-0000001795531205)和[应用 UX 体验标准](https://developer.huawei.com/consumer/cn/doc/design-guides/ux-guidelines-overview-0000001760867048)为准。MoonlightOH 只证明具体能力在 HarmonyOS 上有成熟先例，不覆盖本项目 API 23、主题、多账号、云同步、单 Sheet owner、无障碍和多协议一致性门禁。

### 2.2 主机发现、控制和可达性

Moonlight 的控制面不是单一长连接。目标流程应拆成以下可观测阶段：

1. 发现：局域网 mDNS/主机发现，或用户手动输入 IPv4、IPv6、域名和端口。
2. 可达性：按地址族和端口探测 HTTP/HTTPS、RTSP 和 UDP 可能性；不得把 TCP 可达误判成媒体可达。
3. 主机信息：读取 serverinfo，得到服务器 UUID、协议代际、主机名、应用目录能力、编码能力和配对状态。
4. 配对：客户端生成四位 PIN 并展示，用户把 PIN 输入 Sunshine/GFE 主机端；客户端等待主机返回、执行挑战响应、提交客户端证书并 pin 服务器证书。
5. 目录：读取可启动应用，显示应用名称、图标、应用 ID、可用分辨率或主机能力。
6. 启动：根据所选应用和流配置发起 launch，等待主机返回可用的串流控制信息。
7. 串流：完成 RTSP/SDP 和 common-c 的媒体、控制、输入流建立。
8. 停止：默认只断开本地串流并回收输入、媒体和 native 资源；“退出主机应用”是独立、显式、可失败的主机控制动作，不能作为默认断开的一部分。

端口和传输必须在设置和诊断中可解释：

| 用途 | 默认端口/协议 | 产品处理 |
| --- | --- | --- |
| 主机发现 | UDP 5353，mDNS/局域网 | 默认自动发现；失败时保留手动添加 |
| GameStream HTTP 控制 | TCP 47989 | serverinfo/配对/目录等；端口可配置并以主机响应校验 |
| GameStream HTTPS 控制 | TCP 47984 | 后续控制请求做服务器证书 pin；不能因自签证书关闭验证 |
| RTSP | TCP 48010 | 优先使用 launch/session URL 给出的端口；缺失时按 common-c 规则回退 |
| 视频 RTP | UDP 47998（常见默认） | 由 RTSP/会话参数确定，不能在 UI 固定成单端口 |
| 控制/音频/可选麦克风/输入 | UDP 47999、48000、48002、48010（常见默认） | 由协议协商和主机实现决定；MVP 不启用麦克风 |
| Wake-on-LAN | UDP 广播或定向 magic packet | 仅作为可选唤醒，不承诺公网唤醒 |

以上端口来自 [Moonlight Setup Guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)。本次 common-c 审计还确认名称解析/可达性会涉及 47984、47989、48010，RTSP 缺省回退为 48010；这些探测顺序不等于把所有流固定到一个端口。产品须把“自动发现”“手动地址”“端口转发/公网访问”“IPv6”分别建模。Moonlight 原生依赖 TCP+UDP，不能用浏览器式 WebSocket 代理替代完整媒体通道；FAQ 也明确浏览器不能直接承载 GameStream 的原始传输，参见 [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions)。

公网路线的最低设计边界：

- MVP 只保证用户明确配置、端口可达的网络；不做自建 TURN、反向代理或云中继。
- 不把云同步表误包装成穿透服务；云只同步配置和可选凭据，不转发视频。
- IPv6、NAT64、双栈地址排序必须由网络层根据系统实际解析结果和失败结果动态处理。
- 多地址主机需要记录地址族、最近成功地址、失败原因和下次探测退避时间。
- WOL 只在本地二层网络或用户明确配置的网关可用时显示，参见 [WOL 文档](https://github.com/moonlight-stream/moonlight-docs/wiki/WOL-%28Wake-On-LAN%29)。

`MoonlightHostApi` 的控制面合同至少覆盖 `serverinfo`、应用列表、配对/解除配对、app asset、launch、resume、cancel/quit。HTTPS 默认路径使用 47984、携带已配对的客户端身份并执行 server certificate pin；launch/resume 必须带与当前 session 匹配的 `rikey`/`rikeyid` 和 common-c query 参数。

`uniqueid` 必须拆成不同概念，禁止用设备隐私标识替代协议字段：

- `protocolCompatUniqueId`：按官方 NvHTTP 兼容行为使用经过 exact-revision 验证的固定协议值，使 resume/quit 能识别其他 Moonlight 客户端启动的应用；它不是用户/设备标识，不进云。
- `requestId`：每次 HTTP/配对/launch 的随机请求关联 ID，只用于当前操作和脱敏诊断。
- `installationId`：本地随机安装 ID，只用于安装级缓存/诊断关联，清除数据或重装后重建；不发送给主机、不写 moonlightrecord、不直接作为冲突 origin。
- `originDeviceId`：每个 owner-store 首次写 Moonlight 数据时独立生成的随机同步 origin，只在该 owner 的记录间可关联；同一安装的账号 A、账号 B 和 device-local 使用不同值，不从 installationId、UnionID 或硬件 ID 派生。
- `ownerScopeId`：华为账号/设备本地数据边界，只用于本地与云隔离，绝不写入 GameStream `uniqueid`。

P0 必须用 Sunshine 的 launch/resume/cancel 和“由另一官方 Moonlight 客户端启动”场景验证固定协议值；未通过前不开放跨客户端 quit。

### 2.3 配对、TLS 和信任

配对不能复用 RDP/VNC 的 username/password 表单。Moonlight Android 的 [PairingManager](https://github.com/moonlight-stream/moonlight-android/blob/f10085f552b367cf7203007693d91c322a0a2936/app/src/main/java/com/limelight/nvstream/http/PairingManager.java) 和 [NvHTTP](https://github.com/moonlight-stream/moonlight-android/blob/f10085f552b367cf7203007693d91c322a0a2936/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java) 展示了以下业务事实：

- 客户端用安全随机数生成四位 PIN 并在客户端展示；用户把 PIN 输入主机端。PIN 只在配对会话内存在，不落日志、不进云、不写 host payload，超时/取消后立即清理。
- 现代主机使用 SHA-256，旧主机存在 SHA-1 兼容路径；兼容路径必须标为 legacy，并受版本/安全策略控制。
- 配对使用 16 字节随机 salt、由 PIN 派生的 16 字节 AES 密钥和主机挑战响应。
- 客户端必须用配对返回的服务器证书验证 challenge 签名，并在用户确认后建立后续 HTTPS 的精确证书 pin；不能套用“任意系统 CA 或任意自签证书均可信”。任一步失败执行 best-effort unpair、清理临时身份和 PIN，不能留下半配对状态。
- 客户端证书/私钥在发起配对前由客户端生成并持有；配对请求发送客户端 PEM 公钥证书，主机返回服务器证书。后续 HTTPS 使用客户端身份，并做服务器证书 pin，而不是任意信任新证书。
- 证书变更应进入“信任变更”流程：展示旧/新指纹、要求用户重新确认或重新配对，不能静默替换。

客户端身份的目标合同：

- 兼容基线与 exact Android `AndroidCryptoProvider` 一致：RSA-2048、自签名 X.509、SHA256withRSA、约 20 年有效期，subject/CN 使用经互操作验证的 `NVIDIA GameStream Client` 兼容值；serial 由安全随机数生成且为正。有效期长不等于忽略 notBefore/notAfter，任何身份轮换都会要求受影响主机重新配对。
- 作用域选择为 `ownerScopeId + installationId`：同一账户/设备安装下的 Moonlight 主机共享一个 client identity；账号 A、账号 B 和 device-local 分离，避免跨账户复用私钥。
- 首选 HUKS 中不可导出的签名/密钥能力；但 OpenSSL mTLS 是否能直接使用 HUKS key 必须 P0 验证。若不能，采用 HUKS wrapping key 加密保存 PKCS#8，私钥只在配对/HTTPS session 内短暂解封到锁定内存并清零；禁止明文 key 文件。
- 证书 PEM 可导出发送给主机，私钥永不发送。secure-store alias、证书指纹、创建版本和 owner 写本地元数据，私钥材料默认不进便携备份/云。
- 删除 identity 前列出所有受影响主机；“重新生成身份”“解除某主机配对”“删除主机”是三个独立动作。
- mTLS/HUKS/OpenSSL 集成、RSA 签名、证书序列化、私钥清零和账号切换 barrier 任一探针失败，P2 配对不得进入产品 UI。

安全数据边界：

| 数据 | 默认位置 | 云同步默认值 | 处理 |
| --- | --- | --- | --- |
| server UUID、主机名、地址、端口 | 本地加密记录 | 同步 | 用于发现和主机卡片 |
| 服务器证书指纹 | 本地 trust 记录 | 可同步 | 同步后仍需显示指纹变更 |
| 客户端证书公钥 | owner-scoped 本地 identity/trust 记录 | 默认不同步 | 配对前已生成；发送给主机不等于允许跨账号复用 |
| 客户端私钥/配对身份 | owner-scoped 本机安全存储 | 默认不同步 | 只有端到端加密恢复另行通过安全评审后才允许 |
| PIN | 临时内存 | 永不同步 | 配对失败后立即清理 |
| 访问令牌、HTTP 会话缓存 | 本地短期缓存 | 永不同步 | 过期、切换账号或撤销时清理 |

配对界面必须展示客户端生成的 PIN、清晰说明“请在主机端输入”、等待状态、取消、超时、重试、重置配对和证书变更确认。配对身份属于当前 owner，不能提供会造成半配对的“成功后不保存身份”；可以“只保存未配对主机”。在所有错误文案中区分主机端 PIN 未输入/输入错误、主机已有其他配对事务、证书变更、TCP 可达但 UDP 不通、主机正在运行其他会话。

### 2.4 端到端串流加密和会话密钥合同

除 TLS 控制面和配对信任外，现代 common-c 还定义了流级加密能力。实施不能只写“视频包加密”，而要把协商、密钥、性能和失败策略建模完整：

- `encryptionFlags` 使用 `ENCFLG_NONE`、`ENCFLG_AUDIO`、`ENCFLG_VIDEO`、`ENCFLG_ALL` 表达音视频流加密请求；输入流始终按协议加密。
- launch/resume 生成的 `rikey`/`rikeyid` 是会话级材料，必须与 common-c `remoteInputAesKey`/IV 及主机参数一致；它们只存在于当前 session owner 的安全内存中。
- `rikey`、`rikeyid`、派生 key、IV、认证 tag 不写日志、不进诊断快照、不进 `moonlightrecord`、不进入崩溃上报；停止、失败、账户切换和进程退出时清零。
- 现代 Sunshine 首选音频+视频全流加密；只有在设备 AES 性能探针显示全流加密会破坏目标帧率/温控时，才允许根据产品策略降级。
- 设置项只提供“自动（推荐）”“要求全流加密”“兼容模式”三态；“要求全流加密”协商失败必须 fail closed，不能静默退回未加密。
- “兼容模式”仅面向明确识别的旧主机，显示风险、作用域和本次/长期选择；不得把 legacy SHA-1 配对和媒体不加密混成一个总开关。
- 视频流遵循 exact revision：只允许在不修改可信状态的前提下用未认证 frame number 做廉价过期预筛，然后先做 AES-GCM 认证解密，再把明文 RTP 交给 Rtpv FEC/重排/去包；tag 失败或篡改包不得进入 FEC/decoder，认证成功后的重复/重放由 RTP queue 丢弃，连续失败升级为会话安全错误。
- 音频流先进入 RTP queue/FEC/重排，再按协议执行 AES-CBC 解密；CBC 本身不提供 packet authentication，不能把“长度/块边界/序号/解码合理性校验”写成 GCM 式真实性保证。异常音频包丢弃并计数，持续异常触发音频流错误，TLS、配对信任和会话协商承担端点身份边界。
- 性能门禁分别测试 none/audio/video/all 四类协商结果，记录 AES CPU 占用、帧率、温度、丢包和延迟，确保 UI 显示的安全模式与实际协商结果一致。

Moonlight Android 只在设备具备足够快的 AES 时主动请求全部可用加密能力；Moonlight Qt/Sunshine 的现代版本也支持完整端到端流加密。HarmonyOS 版本不得把“本机支持 AES 指令”直接等同于“1080p60/4K 场景性能达标”，必须真机测量。

### 2.5 common-c 的连接阶段和线程边界

官方 [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Connection.c) 的启动顺序不是可选的 UI 步骤，而是 native session 的状态机边界。计划中的事件顺序如下：

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

本次 exact revision 还要求保留以下协议不变量：

- `LiStartConnection` 非线程安全；同一进程内多个 Moonlight session 必须由单一 native coordinator 串行 start/stop，不能从两个 NAPI worker 并发启动。
- `STREAM_CFG_LOCAL`、`STREAM_CFG_REMOTE`、`STREAM_CFG_AUTO` 影响包长和网络策略；AUTO 必须由可达性/地址结果决定，不由 UI 猜测“是否同一 Wi-Fi”。
- 远端包长上限按 common-c 当前逻辑在 IPv4/NAT64 路径约 1024、原生 IPv6 路径约 1184；实际实现仍需 path-MTU/分片测试，不能擅自提高到普通以太网 MTU。
- 视频宽高、音频配置和 packet size 在进入 common-c 前做边界校验；当前代码要求相关 packet size 满足 16 字节约束并对奇数高度做安全处理。
- 码率包含 FEC 开销；以约 20% FEC 场景估算时，编码器实际视频码率会低于 UI 标称总码率。UI、主机 launch 参数和诊断必须明确使用同一口径。
- 超过 4K 的 H.264、超过 8K 的任意配置视为高风险/异常输入，除非 P0 明确验证，否则 capability policy 直接拒绝。

### 2.6 视频：RTP、加密、FEC、解码和首帧

视频面至少要保留以下信息，才能和现有 H.264/H.265/AV1 硬解管线正确衔接：

- RTP sequence number、timestamp、payload type、frame boundary；
- 视频包加密状态、会话密钥和包序；
- FEC 数据包、丢包恢复结果、重排窗口和 reorder timeout；
- frame type、frame number、reference frame 标志；
- H.264 SPS/PPS、HEVC VPS/SPS/PPS、AV1 sequence/header 等 codec configuration；
- decode unit 的 bufferType、buffer链、长度、presentation timestamp；
- 最近成功关键帧、待请求 IDR、连续丢帧计数、解码器 flush/reconfigure 状态。

官方 [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/VideoStream.c) 会将 RTP 包经过视频解密、FEC、重排和帧组装，再通过 DECODE_UNIT 回调交给客户端。项目当前 hw_decoder.cpp 已有 OH_AVCodec、Surface、队列上限和恢复逻辑，但其输入假设是一个 encoded frame buffer。两者之间应新增 MoonlightVideoBridge：

1. 将 LENTRY 链复制或引用到 session-owned buffer，不能引用 common-c 将要复用的包内存。
2. 记录配置帧，遇到解码器首次启动、Surface 重建或 codec change 时先补齐配置。
3. 按 codec 将多个片段合并成 OH_AVCodec 可接受的 access unit，并保留关键帧标志。
4. 视频队列满时优先丢弃尚未开始解码的非关键帧，不丢失最近关键帧和配置帧。
5. 首帧超时或 Surface 重绑后主动请求 IDR；不能无限等待旧帧。
6. 将 packet loss、FEC recovery、decode queue、decode latency、render latency 作为诊断指标。

视频流的安全/恢复细节必须保持 common-c 行为：启用时先做 AES-GCM 认证解密，再把通过认证的明文 RTP 交给 FEC/重排/去包；未认证 header 只能用于无副作用的过期预筛，不能推进 frame/sequence 状态。认证失败/篡改包不进入 FEC，认证后的重复/重放不进入解码器；首包/完整帧超时要变成明确 stage error；decoder 返回 `DR_NEED_IDR` 或队列恢复失败时向主机请求关键帧，而不是无限 flush。

common-c decoder capability 不能全部照抄为 true：

| capability | 首版策略 | 开放证据 |
| --- | --- | --- |
| `CAPABILITY_DIRECT_SUBMIT` | 默认关闭 | callback 不阻塞网络线程、OH_AVCodec backpressure 和 buffer 生命周期已证明 |
| AVC/HEVC/AV1 reference-frame invalidation | 仅对 H.264 已验证路径开放或全部关闭 | 丢包后参考帧恢复正确；否则统一请求 IDR |
| `CAPABILITY_SLOW_OPUS_DECODER` | 由真实 Opus decode budget 决定 | 最差多声道配置仍满足音频回调期限 |
| arbitrary audio duration | 默认关闭 | OHAudio buffer/时钟/PLC 对所有协商时长通过 |
| `CAPABILITY_PULL_RENDERER` | 默认关闭 | 专用 pull queue、取消和 Surface rebind 无死锁/旧帧 |

主机 codec mask 与设备能力取交集：H.264、HEVC/Main10、AV1、Sunshine YUV444 分开建模；色彩空间保留 Rec.601/709/2020 和 limited/full，不能把“支持 HEVC”推导为“支持 Main10/HDR/YUV444”。

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

### 2.7 音频：Opus、时钟和 OHAudio

官方 [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/AudioStream.c) 的回调输出是经过 common-c 网络处理后的音频样本/配置，客户端需要提供 renderer/decoder 逻辑。计划的音频链路是：

Moonlight RTP audio → common-c RTP audio queue/FEC/重排 → AES-CBC 解密（启用时）→ Opus 或 Opus multistream decoder → PCM 48 kHz → 重采样/声道映射 → OHAudio renderer → 音频焦点/AVSession。

项目已有 [audio_player.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/audio_player.cpp:70) 使用 OHAudio 播放 48 kHz、双声道、S16LE PCM，并有队列和欠载统计。这条链可复用，但必须新增：

- 每个 Moonlight session 独立的 Opus decoder owner；
- channel count、sample rate、sample format 的动态协商；
- 5.1/7.1 的能力探测与明确降混到 stereo；
- audio timestamp 与视频/本地时钟的漂移监控；
- buffer target、underrun、late packet、decoder reset、focus loss 的处理；
- 断连、后台、PIP、电话/系统音频抢占时的 pause/flush/resume。

音频流启用加密时按当前协议走 AES-CBC；RTP queue 完成 FEC/重排并给出连续 packet 后执行 CBC 解密，随后才送 Opus。丢失帧使用 Opus null decode 做 packet-loss concealment，而不是简单复制上一段 PCM；开始阶段约 500ms 的重同步/过期包丢弃策略必须保留并可观测，避免把旧音频追赶播放。音频关闭或降级时仍要消费/关闭对应网络资源，不能留下接收线程。

鸿蒙侧应以官方 [OHAudio 播放指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5) 和 API23 本地头文件为准。当前 `audio_player.cpp` 实际使用 `AUDIOSTREAM_USAGE_MUSIC`，不能在计划中误写成已经具备游戏用途。P0 必须编译探测 API 23 的实际 usage 枚举和设备路由行为，再决定游戏音频用途；低时延模式要求设备支持且通常以 48 kHz 为基础。第一版不把录音、麦克风回传或语音聊天混入 MVP；如果未来需要麦克风，必须另做权限、回声消除、隐私指示和云端策略评估。

### 2.8 控制流、输入和反馈

控制与输入不能仅调用现有 sendKey/sendMouse。计划分成四层：

| 层 | 事件 | 可靠性/顺序 |
| --- | --- | --- |
| 键盘 | key down/up、unicode/text、组合键、系统快捷键 | 按 common-c 语义发送；页面失焦时 flush 所有按键 |
| 鼠标 | 相对移动、绝对移动、左中右键、滚轮、抓取/释放 | 相对移动允许合并；按钮 down/up 必须成对 |
| 触摸 | 多点 id、down/move/up/cancel、pressure/尺寸 | 保留触摸点生命周期；页面退出统一 cancel |
| 手柄 | 设备槽位、按钮、轴、扳机、帽子开关、运动 | 按控制器协议和设备能力映射；控制器断开先发送安全释放 |
| 反馈 | rumble、低频/高频、LED、可能的 motion | 只对真实设备能力开放；失败不影响视频会话 |

官方 [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/InputStream.c) 和 [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Limelight.h) 提供了键盘、鼠标、多点触摸、控制器和反馈接口。项目的 [input_handler.cpp](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/audio/input_handler.cpp:20) 目前以进程级 activeAdapter 路由，Moonlight 必须使用 session-owned InputBridge，避免旧 VNC/RDP 会话接收新手柄事件。

输入流还要保持协议代际差异：现代代际使用 AES-GCM，旧代际兼容 AES-CBC；关键按钮、触摸生命周期和控制器状态走可靠 ENet/有序路径，高频鼠标移动可批处理/合并，但不能越过按键边界。控制器 index 上限以主机代际和 common-c 能力为准：exact revision 规定 Sunshine 最大 index 15（16 个槽位），GFE 最大 index 3（4 个槽位），更老 generation 还可能全部映射到 0；UI 不因 API 能枚举多设备就宣称主机支持同样数量。

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
| OHAudio | 48 kHz stereo S16LE、低时延、音频焦点、后台 | 连续 2 小时达到第 10.5 节 gap/underrun/A-V drift 门，焦点丢失可恢复 |
| Input Kit 基础事件 | 键盘、鼠标、触摸事件、key code、多点生命周期 | 页面切换、旋转、取消、系统返回时无悬挂按键/触摸点 |
| 相对鼠标与捕获 | 未加速 raw relative delta、光标隐藏/约束/捕获、窗口失焦、跨窗口和重新捕获 | 真机全屏/自由窗口下相对位移无边缘钳制；失焦 250ms 内释放全部状态 |
| 系统快捷键 | Alt+Tab、Win/Meta、Ctrl+Alt+Del、Home/返回等组合能否被应用拦截/转发，以及系统保留优先级 | 逐项形成支持矩阵；永远保留本地逃生键，无法安全拦截的组合不出现在可用设置 |
| Game Controller Kit | 多控制器、button/axis/trigger、device id、断开；反馈输出另立探针 | 至少两类真实手柄每个轴/按钮映射正确；无官方反馈 API 时 rumble/LED/motion 设置保持隐藏 |
| AVSession/后台 | 游戏音频、播放控制、后台任务、锁屏/切应用 | 系统允许的后台范围内可继续音频/必要媒体，不虚报无限后台 |
| PIP | 画面尺寸、解码器持续输出、返回前台 | PIP 和普通页面互切无黑屏/花屏/旧会话画面 |
| 无障碍系统状态 | 字号/对比度、屏幕朗读、减少动效、减少透明度是否有 API 23 稳定公开读取/订阅接口 | 每项独立记录 supported/unsupported；变化可重排 UI 且不重启串流 |
| 网络 | IPv4/IPv6、mDNS、TCP/UDP、蜂窝/无线切换、NAT64 | 发现失败可手动连接，地址族回退可解释 |
| 安全存储 | 设备级密钥、证书私钥、删除和账号切换 | 私钥不出安全边界；账号退出后按策略清理 |

官方资料入口：

- [HarmonyOS 开发者中心](https://developer.huawei.com/consumer/cn/develop/)
- [HarmonyOS Input Kit C 头文件](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/input-headerfile-V13)
- [OHAudio 播放指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5)
- [Universal Keystore Kit / HUKS API](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/js-apis-huks-V14)
- [Asset Store Kit 概览](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/asset-store-kit-overview-V14)
- [Background Process Manager 参考](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/js-apis-backgroundprocessmanager-V13)
- [HarmonyOS 分布式数据库 Codelab](https://developer.huawei.com/consumer/en/codelab/HarmonyOS-Distributed-Database/)

2026-07-29 对本机 `/Users/mydestiny/Library/OpenHarmony/Sdk/23` 的只读审计确认：

- 存在 `GameControllerKit/game_device.h`、`game_pad.h`、`game_pad_event.h` 和 `libohgame_controller.z.so`，头文件标注 API 21 起，提供设备上下线、按钮、扳机、方向键和双摇杆轴事件；
- 当前这组 Game Controller Kit 头文件没有发现 rumble、LED、运动传感器或自适应扳机输出接口，因此首版只能承诺“可验证的输入”，反馈能力必须另找官方能力并单独探针，不能从 Moonlight 协议有回调反推鸿蒙设备一定能执行；
- 存在 `native_avcodec_videodecoder.h` 及 Surface 输出/flush/reset/input/output buffer API，说明编译接口存在，但 codec/profile、零拷贝、帧率和重绑稳定性仍须真机证明；
- 存在 OHAudio renderer、audio session manager，且 API 23 头文件含 `AUDIOSTREAM_USAGE_GAME` 和 `AUDIOSTREAM_LATENCY_MODE_FAST`；当前项目仍使用 MUSIC usage，升级需要独立回归音频焦点、路由和低时延；
- 存在 `libohavsession.so` 及 native AVSession 头文件，以及 ArkTS AVSession 声明；是否适合游戏串流后台状态必须按系统准入和产品行为验证；
- 存在 `arkui/native_interface_accessibility.h`，可为 XComponent/自定义控制建立语义节点、焦点、动作和播报；这不替代 ArkUI 普通组件的 accessibility 属性。

因此，Game Controller Kit 和媒体接口的“SDK 可见性”已经从方向性判断升级为本地证据，但任何第三方 API 摘要都不能直接写进生产调用约定，且“有头文件/能链接”仍不等于目标设备驱动和性能达标。

相对鼠标和系统快捷键属于 P0 Go/No-Go 项，不得凭普通 pointer event 推断可用。能力模型必须把 `relativePointer`、`pointerConstraint`、`keyboardCapture`、`systemShortcutForwarding` 分开记录；设置页只展示真机探针通过的项。相对鼠标失败时降级为绝对鼠标/触摸，系统快捷键失败时保留远端软键盘/组合键面板，但本地 Esc/返回/停止路径始终有效。

### 3.2 UI、多设备和无障碍能力边界

鸿蒙官方设计中心强调多设备连续体验、响应式布局、画中画和折叠屏左右布局；焦点导航规范要求键盘、方向键/摇杆/手柄可遍历可交互控件，并区分选中态与获焦态。当前工程已经有自己的稳定设计系统，应以“项目 token 为实现合同，鸿蒙设计规范为体验校验”：

- `BreakpointUtil.ets` 的 sm/md/lg/xl 和折叠态规则继续作为唯一断点来源，不新建 Moonlight 私有 breakpoint。
- `Theme.ets` 的颜色、字号、圆角、间距、按钮高度、动效和 HarmonyOS Sans 继续作为唯一视觉 token 来源。
- 手机、折叠屏、平板、PC/2in1、自由窗口和横竖屏变化必须保持当前任务、输入捕获和串流会话连续；布局重排不能重建 Moonlight native session。
- 所有可交互元素支持触控、鼠标和键盘焦点；Tab/Shift+Tab、方向键、Enter/Space、Esc 的行为与鸿蒙焦点规范一致。
- 自定义串流画面和虚拟控制要提供可读名称、角色、状态、值、动作和焦点顺序；仅有图标、颜色或振动不能成为唯一信息通道。
- 对 API23 有稳定公开接口的字号、深浅色、关怀/无障碍和减少动效状态跟随系统；放大后重要按钮不能被裁掉，短屏场景必须可滚动。某个系统状态不可读时，不伪称“跟随系统”，改用 App 内“减少动效/使用实色界面”开关，并让非必要持续动效默认关闭。

官方资料：

- [HarmonyOS 设计中心](https://developer.huawei.com/consumer/cn/design)
- [焦点导航规范](https://developer.huawei.com/consumer/cn/doc/design-guides/hmi-focus-0000001748650376)
- [HarmonyOS 电脑应用开发入门](https://developer.huawei.com/consumer/cn/multidevice/pc/get-started/)
- [设备兼容规则](https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/device-compatible)
- [HarmonyOS 文档中心：ArkUI、Accessibility、AVCodec、AVSession、Game Controller Kit](https://developer.huawei.com/consumer/cn/doc/)

### 3.3 当前代码对应的鸿蒙复用判断

| 当前实现 | Moonlight 复用策略 |
| --- | --- |
| hw_decoder.cpp 中 OH_VideoDecoder_CreateByMime、SetSurface 和已有 codec 枚举 | 抽出通用 decoder owner；Moonlight 只负责把 DECODE_UNIT 变成 access unit |
| GLRenderer 的 XComponent/NativeImage | 复用渲染表面管理，但用 session generation 阻止旧回调绘制 |
| audio_player.cpp 的 OHAudio 48 kHz stereo | 复用 renderer；前面增加 Opus decoder、时钟和声道降混 |
| RemoteSessionBackgroundTaskService 的 multiDeviceConnection/audioPlayback | 复用生命周期服务；新增 Moonlight 的 media-ready、input-ready、pause/resume 条件 |
| RemoteSessionPipLifecyclePolicy 的 decoderReady/source dimensions | 复用 PIP 决策接口；Moonlight 首帧和关键帧恢复必须成为显式条件 |
| Input Kit 的现有键鼠/触摸桥 | 复用底层事件读取；Moonlight 增加相对鼠标、触摸 id、手柄和按键释放 |
| CloudStore/CloudSyncCoordinator/VncRecordPolicy | 复用 envelope、冲突和 journal 机制；新建 Moonlight namespace，不复制 VNC 业务逻辑 |

### 3.4 能力降级原则

能力结果要分为 supported、unsupported、temporarilyUnavailable、permissionDenied、unknown 五种，不允许把“未探测”当作“支持”。建议按以下优先级降级：

1. 先保证视频解码和输入安全；
2. 音频不可用时允许用户选择无音频串流；
3. HEVC/AV1 不可用时回退 H.264，但要重新协商主机编码；
4. 7.1 回退 stereo；
5. 触觉/LED/motion 失败不影响核心会话；
6. PIP/后台不满足系统条件时回到前台并显示原因；
7. UDP 媒体不可达时结束会话或提示网络配置，不把它伪装成 RDP 式 TCP 串流。

所有能力结果都应同时记录在诊断快照中，便于区分“主机不支持”“设备不支持”“网络不支持”和“应用没有权限”。

### 3.5 权限、后台模式和数据声明差异

当前 `module.json5` 已声明 `ohos.permission.INTERNET`、`ohos.permission.KEEP_BACKGROUND_RUNNING`，Ability 已有 `dataTransfer`、`multiDeviceConnection`、`audioPlayback` backgroundModes，设备类型覆盖 phone/tablet/2in1。Moonlight 接入前要做最小权限评审：

- 局域网发现、HTTP/RTSP/UDP 串流先证明只需现有网络权限；不因“发现设备”顺手申请位置、蓝牙、相机或通讯录。
- 实体 USB/蓝牙手柄通过 Game Controller Kit 暴露时，优先使用系统已授权的输入设备通道；只有官方文档和编译错误证明需要新增权限才申请。
- 当前 manifest 没有 `ohos.permission.VIBRATE`；手机触觉不等于实体手柄 rumble。反馈功能关闭时不得为了未来可能性新增权限。
- PIP、后台音频和多设备连接必须复核后台类型与实际业务相符，并向用户说明系统可随时停止；不能用 dataTransfer 掩盖持续串流。
- 配对证书、主机地址、WOL MAC、诊断网络元数据、云 secret 都进入隐私清单/数据删除/导出说明；PIN 和流会话密钥标为只在内存短暂处理。
- 若后续加入麦克风回传，作为独立立项新增麦克风权限、系统隐私指示、前后台禁用、回声消除和主机端提示；本计划 MVP 不预申请。

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
- pairingPinGenerated：displayPin、expiresAt、legacyCrypto；该事件仅投递到当前配对 route，PIN 不进入普通 state snapshot、日志或 analytics；
- pairingProvisional：serverCertificateSha256、hostName、legacyCrypto、mustConfirm；只有当前用户确认并成功持久化 trust 后才发出 paired；
- appCatalog：apps、catalogVersion、updatedAt；
- streamNegotiated：codec、width、height、fps、bitrateKbps、audioChannels、hdr、colorSpace；
- firstFrame、audioReady、inputReady；
- stats：rttMs、jitterMs、packetLoss、fecRecovered、decodeQueue、audioUnderrun、bitrate；
- inputState：keyboardCaptured、mouseCaptured、gamepads；
- surfaceState：attached、detached、rebindRequired；
- recoverableError、fatalError；
- stopped：reason、cleanupSummary。

所有事件携带 sessionId、generation、monotonicTimestamp。ArkTS 收到旧 generation 事件时静默丢弃并记录计数，不回滚当前 UI。

### 4.5 账户作用域、敏感数据屏障和两类 generation

当前分支已经把账户/数据库切换收敛到 `AccountSessionCoordinator`，并以 `AccountScopeToken`、`AccountSessionLease`、`SensitiveDataBarrier` 保护跨账户数据。Moonlight 不能建立旁路，必须同时遵守两种 generation：

| generation | 所有者 | 保护对象 | 回调接受条件 |
| --- | --- | --- | --- |
| account/store generation | AccountSessionCoordinator | 当前用户、数据库实例、云绑定和本地 mirror | ownerScopeId、storeIdentity、storeInstanceId、generation 全部匹配当前 lease |
| Moonlight session generation | MoonlightSessionService/native owner | 当前主机串流、Surface、音频、输入和网络线程 | sessionId、session generation、对应 media/input generation 全部匹配 |

任何 Moonlight 持久化、云回调或 secret 恢复必须先通过账户 lease，再通过 Moonlight session generation；任意一层过期都静默丢弃结果、递增 stale-callback 诊断计数，且不得重开 mutation gate。

Moonlight 还必须作为 `SensitiveDataBarrier` 的正式参与者：

1. 账户切换/退出开始，关闭 Moonlight 的新建、编辑、配对、secret 恢复和串流启动入口。
2. 停止 PIP/后台/实况窗等所有外部可见会话，并要求终态回执。
3. 停止所有 Moonlight native session，释放输入、音频、视频、控制/RTSP/HTTP 和在途回调。
4. 清零 PIN、`rikey`/`rikeyid`、session token 和解密中间态，撤销当前 secure-store lease。
5. 等 Moonlight journal/CloudStore mutation 归零，才能让 Coordinator quiesce 旧 store。
6. 新账户/设备本地作用域绑定成功后，只加载新 owner 的 host/profile/trust/secret 元数据；旧回调不能触发 UI 或写新 store。

Moonlight 的“连接仍在运行”不能成为账户切换的软提示后继续执行。若安全停止失败，账户切换必须 fail closed，并给用户提供“重试停止”或“返回当前账户”的明确路径。

### 4.6 跨协议会话仲裁

当前工程的解码、音频和输入底座仍含进程级资源与 active owner，因此 MVP 明确采用“整个 App 同一时刻只允许一个活动远程媒体会话”的合同，Moonlight 不得另建私有全局锁：

- [ActiveRemoteSessionRegistry.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets) 是 RDP、RustDesk、VNC、Moonlight 和后续媒体协议的唯一仲裁入口；SSH 等非媒体会话是否互斥也由该 registry 的协议能力规则决定。
- 开始 Moonlight 时若另一远程媒体会话处于 connecting、connected、PIP、background-preserved 或 stopping，先显示协议、主机和未保存状态影响；用户确认后停止旧会话，等待输入释放、Surface/audio/native callback gate 的终态回执，再创建新 session。
- 旧会话停止失败、超时或 registry owner 未释放时，新 Moonlight 会话 fail closed；禁止“新会话先启动、旧会话后台慢慢清理”。
- 从 Moonlight 启动其他协议遵循同一规则；PIP 仍算活动会话，不能借 PIP 绕过仲裁。
- 主机发现、serverinfo 和只读应用目录可在没有敏感事务时并行缓存；配对、launch/resume、媒体建立和 quit 必须按活动 owner 串行。
- 在 common-c 全局状态、decoder/audio/input owner 全部实例化并通过多会话压力测试前，不承诺并行 Moonlight 会话；这属于未来独立架构升级，不在首版范围。

回归必须覆盖“RDP→Moonlight、VNC→Moonlight、Moonlight→RDP、Moonlight PIP→其他协议、旧会话卡在 stopping”五组切换；任何路径都不能出现旧帧、串音、输入串会话、错误主机被 quit 或旧 generation 回写 UI。

## 5. 分阶段实施路线

### 5.1 依赖顺序和交付物

下表是可以实际排期和验收的升级路线。每一阶段都必须先满足退出条件，才允许下一阶段把能力暴露给用户。

| 阶段 | 目标 | 主要交付物 | 前置条件 | 退出条件 |
| --- | --- | --- | --- | --- |
| P0 方案与探针 | 锁定上游、许可证、API23 能力和测试主机 | 上游 commit/ENet lock、合规清单、OH_AVCodec/OHAudio/Input/Game Controller 探针报告 | 无 | 双 ABI 编译；至少一台真机完成能力矩阵；阻断项明确 |
| P1 native 基座 | 把 common-c 接入现有 NAPI 而不污染旧协议 | moonlight 静态目标、平台回调、session owner、callback gate、feature flag | P0 通过 | 无 Moonlight 时旧 RDP/VNC/RustDesk/SSH 编译和测试结果不回退 |
| P2 主机控制面 | 完成发现、serverinfo、配对、目录、启动/停止 | HostApi、TLS pin、PIN flow、app catalog、可达性诊断 | P1 | Sunshine 真实主机完成配对、列出应用、启动和停止 |
| P3 串流控制面 | 完成 RTSP/SDP、端口、能力协商和 common-c 流启动 | StreamConfig、阶段事件、IPv4/IPv6、TCP/UDP 探测、取消/重试 | P2 | 收到合法首个视频/音频/控制流；所有错误能回到明确 stage |
| P4 视频 MVP | H.264 1080p60 硬解和 Surface 生命周期 | DECODE_UNIT bridge、配置帧、FEC/丢包统计、IDR 恢复、PIP rebind | P3 | 连续 2 小时达到第 10.5 节帧率/黑屏门；页面重建/PIP/后台切换后可恢复首帧 |
| P5 音频 MVP | Opus stereo 低时延播放 | Opus decoder、PCM adapter、OHAudio、音频焦点、underrun 统计 | P3 | 视频音频同步稳定；焦点丢失、后台、断连不残留播放 |
| P6 输入 MVP | 键鼠、触摸和实体手柄输入；反馈默认关闭 | InputBridge、按键释放保险、控制器映射、反馈 capability fail-closed 门 | P3、Game Controller probe | 至少两类手柄、触摸多点、键鼠在真实主机可用；页面退出无悬挂输入；无反馈 API 时 UI 不暴露 |
| P7 会话产品化 | 做好前后台、网络切换、重连、退出和资源回收 | lifecycle state、PIP、后台任务、reconnect policy、诊断页 | P4-P6 | 20 次 connect/disconnect/rebind 循环无 native 崩溃和旧画面 |
| P8 数据和 UI | 加入独立主机、应用、设置和单云表 | Moonlight model/policy/pages、moonlightrecord、owner/lease/barrier、迁移隔离、云冲突、UI/无障碍和功能开关 | P2、P7 的接口稳定；云生命周期总门具备 | 新/老/多设备/切账号用户完成全流程；云开关关闭时零上传；旧协议 UI 无回归 |
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
9. manifest 权限/backgroundModes 的差异表、申请时机、拒绝降级和隐私声明更新。
10. 当前 Theme/Breakpoint/sheet/settings route 的 UI 基线截图与无障碍基线。
11. raw relative mouse、pointer capture/constraint、焦点丢失释放和每个系统快捷键的真机支持矩阵。
12. Sunshine 最低安全版本/advisory 结果，以及 `moonlightrecord` 22 列 schema、长度、索引和云环境审批。
13. ActiveRemoteSessionRegistry 的跨协议互斥和进程异常退出 SessionRecoveryMarker 的架构评审。

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
- `CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED`、`REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED`、`PORTABLE_BACKUP_V3_WRITE_ENABLED`、`LEGACY_CLOUD_REST_TRANSFER_ENABLED` 等总门保持 fail closed；Moonlight 子开关不得越权打开上层能力。
- 远端 feature flag 只决定入口/启动/子能力是否可用，不能远端删除数据、变更信任或上传 secret。关闭能力后仍保留查看、导出和删除数据的路径。

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
  PairingRequired --> Pairing: 客户端生成并展示 PIN
  Pairing --> TrustConfirming: challenge/服务器证书校验成功
  Pairing --> PairingRequired: 主机未输入/输入错误或超时
  TrustConfirming --> Paired: 用户确认首次指纹并持久化 trust
  TrustConfirming --> PairingRequired: 用户拒绝；best-effort unpair 并清临时态
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
| PAIRING_REJECTED | 主机端未输入/输入错误、主机未确认 | 保留主机，清理临时 PIN，重新生成后允许重试 |
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

以当前 VNC 的 19 列 envelope 为兼容基线，再为真实双设备并发增加 `baseversion`、`mutationid`、`origindeviceid` 三列；最终云表固定为 22 列。三列属于同一 `moonlightrecord`，不是第二张冲突表。云数据库控制台 schema、ArkTS row model、validator、migration 和本地 mirror 必须使用完全相同的列名与整数语义。

云端/分布式表的规范 DDL 形状如下；实际建表由项目既有 CloudStore/云控制台迁移通道执行，不允许客户端在生产环境临时建云表：

~~~sql
CREATE TABLE moonlightrecord (
  id TEXT PRIMARY KEY,
  userid TEXT,
  recordtype TEXT,
  ownerid TEXT,
  ownertype TEXT,
  secretkind TEXT,
  payload TEXT,
  ciphertext TEXT,
  envelopeversion INTEGER,
  cryptoversion INTEGER,
  keyversion INTEGER,
  aadversion INTEGER,
  payloadhashsha256 TEXT,
  syncversion INTEGER,
  baseversion INTEGER,
  mutationid TEXT,
  origindeviceid TEXT,
  schemaversion INTEGER,
  resetepoch INTEGER,
  createdat INTEGER,
  updatedat INTEGER,
  deletedat INTEGER
);
~~~

本地 mirror 是当前 owner 专属数据库内的缓存/队列表，不注册到 `selectedTables` 或云 schema：

~~~sql
CREATE TABLE moonlightlocalrecords (
  id TEXT PRIMARY KEY,
  userid TEXT,
  recordtype TEXT,
  ownerid TEXT,
  ownertype TEXT,
  secretkind TEXT,
  payload TEXT,
  ciphertext TEXT,
  envelopeversion INTEGER,
  cryptoversion INTEGER,
  keyversion INTEGER,
  aadversion INTEGER,
  payloadhashsha256 TEXT,
  syncversion INTEGER,
  baseversion INTEGER,
  mutationid TEXT,
  origindeviceid TEXT,
  schemaversion INTEGER,
  resetepoch INTEGER,
  createdat INTEGER,
  updatedat INTEGER,
  deletedat INTEGER,
  localonly INTEGER
);
~~~

列合同：

| 列 | 应用层合同 |
| --- | --- |
| id | 全局唯一、不透明、稳定 ID，最多 128 字符；唯一数据库主键，不使用主机名/IP，owner 不参与物理复合主键 |
| userid | 已验证 owner 的不可逆作用域值，最多 128 字符；device-local row 不得上传 |
| recordtype | `settings`、`host`、`profile`、`trust`、`secret` 之一，最多 16 字符 |
| ownerid | 业务 owner ID，最多 128 字符；与 userid/store lease 一起校验 |
| ownertype | `user`、`device`、`host`、`profile` 之一，最多 16 字符 |
| secretkind | `none`、`serverTrust`、`clientIdentityEnvelope` 之一，最多 32 字符；session token/PIN/rikey 永不成为云记录 |
| payload | UTF-8 规范化 JSON，最多 64 KiB；secret 仅放非敏感 envelope 元数据 |
| ciphertext | 端到端加密 envelope，最多 128 KiB；非 secret 为空字符串 |
| envelopeversion/cryptoversion/keyversion/aadversion | 非负整数；不支持的较新版本隔离 |
| payloadhashsha256 | 按第 7.4 节逐 recordType 字节合同计算的 SHA-256，小写 64 位十六进制；历史列名不代表 secret 只 hash payload |
| syncversion | 当前记录逻辑版本，非负整数；写入时等于 `baseversion + 1` |
| baseversion | 写者开始编辑时观察到的 syncversion，非负整数，用于识别并发分支 |
| mutationid | 每次持久 mutation 的安全随机 ID，最多 64 字符；重试复用同一个值以保证幂等 |
| origindeviceid | owner-store 内随机、不可反推硬件/账号的 origin ID，最多 64 字符；不是 OAID、UDID、序列号或原始 installationId |
| schemaversion/resetepoch | 非负整数；resetepoch 只在明确重置/复活操作递增 |
| createdat/updatedat | Unix epoch milliseconds 非负整数；服务端规范化时间优先，本机时间不单独决定胜负 |
| deletedat | `0` 表示存活，正整数表示 tombstone 时间；全链路禁止一处用 null、一处用 0 |
| localonly | 仅本地 mirror 使用，`0/1`；为 1 的记录不会被云 adapter 枚举 |

云服务为兼容性可能不支持列级 NOT NULL/CHECK，因此“DDL 可空”不代表业务可空。写入、拉取、恢复、迁移四条路径都必须运行同一个 validator；字段缺失、越界、非法枚举、负数、hash 格式错误或 live/tombstone 语义冲突全部隔离，不用默认值悄悄修复。单行总体积、云端列类型、索引数和 TEXT 上限必须在 P0 云环境实测，若平台上限更小，只能收紧本计划上限，不能拆成第二张云表规避。

初始迁移标识定为 `moonlightrecord_schema_v1_22col`，业务 row 的 `schemaversion=1`。云端 22 列和授权规则先部署并通过空表/回滚演练，客户端 feature flag 才可识别；不允许 19 列实验 row 与 22 列正式 row 混写。未来加列必须先保持旧 reader 可隔离/只读，再提升 migration/schemaVersion，不能复用 v1 原地改变列语义。

`originDeviceId` 的生命周期也固定：账号切换复用该 owner-store 已有随机值；清除该 owner 本地数据、卸载/重装或创建新 device-local store 后生成新值；便携备份不把当前 writer origin 作为独立设备配置导出。导入/云拉取时保留历史 row 自带的 origin 以验证旧 mutation，但用户在当前设备产生的下一次 mutation 必须写当前 owner-store 的新 origin。

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
    "enableRumble": false
  },
  "network": {
    "discovery": "manualOrMdns",
    "streamEncryption": "auto",
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
  "sourceOriginId": "random-install-origin-id"
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
- resetEpoch；
- syncVersion、baseVersion、mutationId 和 originDeviceId；
- deletedAt。

`payloadhashsha256` 的输入不得由各端自行 `JSON.stringify`。v1 固定以下规范：

1. 所有用户可见字符串在写入模型时先转 Unicode NFC；JSON 使用 RFC 8785 JSON Canonicalization Scheme（JCS），UTF-8、无 BOM，禁止 NaN/Infinity/重复 key。数据库 `payload` 必须等于这段 canonical JSON 文本。
2. live settings/host/profile/trust：`SHA-256(ASCII("moonlight-live-v1") || 0x00 || UTF8(recordType) || 0x00 || JCS(payload))`。
3. live secret：`ciphertext` 是 DataCrypto binary envelope 原始 bytes 的 Base64url 无 padding 编码；reader 必须 decode 后按同一形式 re-encode，不规范编码隔离。hash 为 `SHA-256(ASCII("moonlight-secret-v1") || 0x00 || JCS(nonSecretMetadataPayload) || 0x00 || decodedEnvelopeBytes)`。
4. tombstone：payload 固定为 canonical `{}`、ciphertext 为空，hash 为 `SHA-256(ASCII("moonlight-tombstone-v1") || 0x00 || UTF8(id) || 0x00 || bigEndian64(resetEpoch) || bigEndian64(syncVersion) || bigEndian64(deletedAt))`；不能携带已删除对象的旧敏感 payload。
5. `payloadhashsha256` 是一致性/冲突字段，不替代 secret AEAD tag、AAD、TLS 或云端授权。hash 校验在合并前完成；无法规范化、Base64url 非 canonical、hash 不匹配或 tombstone 仍带业务内容均进入 quarantine。

建议规则：

1. settings、host、profile：规范化 JSON 放 payload，使用 payload hash 做完整性校验；地址、server UUID 等仍按项目整体数据保护策略决定是否整体加密。
2. trust：至少对记录做完整性保护；证书指纹不作为私钥处理，但证书变更必须可审计。
3. secret：私钥材料只写 ciphertext；payload 仅含不可用来取出其他 owner 密钥的 secure-store alias 元信息、随机 source origin 和恢复状态，不含硬件设备 ID。
4. 禁止把任何密码、PIN、私钥、access token、调试抓包数据写入普通 payload。
5. 密钥轮换只改变 keyVersion/cryptoVersion，不改变 record ID；迁移失败时保留旧 ciphertext 并标记待迁移。
6. 用户关闭 secret sync 时，先停止新 secret 上传，再按当前云数据删除/撤销策略生成 tombstone，不直接删除本地仍在使用的私钥。

#### 并发写入和确定性合并

每个 writer 读取记录时捕获 `baseVersion = observed.syncVersion`，一次用户 mutation 使用新的随机 `mutationId` 和本安装随机 `originDeviceId`，提交 `syncVersion = baseVersion + 1`。网络重试必须复用原 mutationId；同一 mutationId 不同 payload/hash 视为数据损坏而隔离。相同 id、相同 baseVersion、不同 mutationId 且 payload/hash 不同即为并发分支，不能用简单 last-write-wins 吞掉。

确定性总序只用于需要选出可继续同步的 canonical row，优先级固定为：

1. `resetEpoch` 较大；
2. `syncVersion` 较大；
3. 服务端规范化 `updatedAt` 较大；仅有不可信客户端时间时此项不得单独裁决；
4. `mutationId` UTF-8 字节序较大；
5. `payloadHashSha256` 字节序较大。

同一记录的 id 相同，禁止把 id 当最后 tie-breaker。五项仍完全相同但内容不同属于 invariant violation，双方都隔离并阻断上传。合并后生成新 mutation，`baseVersion` 指向已消费 canonical 版本，不能原样回写某一分支伪装成已合并。

recordType 合并合同：

| recordType | 并发处理 |
| --- | --- |
| settings | payload 内维护按 JSON path 的 field version map；不重叠路径可三方合并，同一字段冲突按总序选 canonical，并在同步详情中保留“另一设备设置未采用”的可见记录 |
| host | 地址集合可按规范化地址 key 合并；displayName/lastSeen 等低风险字段按 field version；serverUuid、host identity、证书关联冲突必须阻断并重新验证，不能把两个主机拼接 |
| profile | 不重叠的 stream/input override key 可三方合并；同一 key 按总序；appId/hostId 并发变化进入用户选择，禁止启动含糊 profile |
| trust | 相同 server certificate fingerprint 可合并更新时间；不同 fingerprint 永不自动选择，标记 `TRUST_CONFLICT` 并要求重新验证/配对 |
| secret | 第 7.4 节 `moonlight-secret-v1` canonical hash 相同可幂等合并；不同有效 secret 永不自动恢复或覆盖，隔离双方并要求用户选择来源或重新配对 |

tombstone 对“基于同一或更旧 baseVersion”的普通 mutation 获胜，阻止离线旧设备把已删对象复活。复活只能由用户明确执行，创建更高 `resetEpoch` 的新 mutation，并重新经过 owner、trust/secret 和云授权确认。客户端墙上时钟不参与安全决策；离线并发、时钟回拨、重试乱序和 tombstone race 都必须进入双设备测试。

### 7.5 云同步生命周期

| 时点 | 行为 |
| --- | --- |
| 登录/打开云同步 | 拉取 moonlightrecord schema，验证 envelope/hash，创建本地镜像 |
| 打开 Moonlight 页面 | 只读取账户级已物化的本地快照，并向集中式 CloudSyncCoordinator 请求/观察刷新；页面不得自行启动第二套 cloud-first/merge。secure secret 由本机优先，云 secret 只呈现待恢复状态 |
| 添加/编辑主机 | 先写本地 journal，再按 selectedTables 和用户授权上传 |
| 配对成功 | 默认只更新本地 secret/trust；若用户开启 secret sync，显示明确确认后才上传 |
| 主机目录刷新 | 更新本地 app cache，不自动刷新云 profile 的 titleSnapshot，避免无意义写放大 |
| 删除主机 | host、profile、trust 按关联关系生成 tombstone；secret 先撤销使用再处理 |
| 账号退出 | 停止上传、清理 session token、解除本机云密钥；用户选择保留还是删除本地配对身份 |
| 多设备冲突 | 先合并非 secret；secret 冲突阻断使用并要求重新配对或选择版本 |
| 云端异常 | 保持本地可用，显示待同步；不得因为云失败阻断已配对的局域网串流 |

Malformed row、未知 recordType、schema 过新、hash 不匹配和 AAD 不匹配都应进入隔离队列，不能被当作空记录覆盖。CloudSyncCoordinator 必须能报告每类计数和最近错误。

### 7.6 账户作用域和存储身份

`userid` 不能只当作一列过滤条件；Moonlight 数据的物理数据库、内存 cache、journal、selection 和 callback 都必须绑定当前 `AccountScopeToken`：

- 华为账号作用域：由已验证 UnionID 的不可逆 SHA-256 派生 `ownerScopeId`，使用该 owner 对应的独立数据库身份。
- 设备本地作用域：使用独立的 device-local owner 和 `remotedesktop_device_local.db`，不得伪造云账号 userid。
- 每个本地 `moonlightlocalrecords` 行、journal、quarantine、migration receipt 都写入 owner 证据或受 owner 专属数据库隔离。
- MoonlightService 不长期缓存裸 `CloudStore`；每次 mutation/snapshot 获得短期 lease，并在完成前验证 lease 仍为 current。
- 账号处于 authenticating、switching、locked、blocked 或 cloud binding 不一致时，允许只读显示已安全加载的当前 owner 数据，但禁止配对 secret 恢复、云 mutation 和跨 owner 合并。
- UI 上的“本地”“已同步”“待上传”“仅此设备”“待恢复”状态来自当前 owner 的真实记录，不从全局布尔值推断。

同一主机在两个账号下可以有相同 server UUID，但必须是两个 owner 隔离的逻辑记录。去重键至少包含 ownerScopeId + recordType + stable business id，禁止跨账号以 server UUID 合并。

### 7.7 mutation gate、云回调和 bootstrap

Moonlight 接入当前 CloudStore/Coordinator 时必须遵守以下顺序：

1. App/账户启动先解析 owner 和 store identity，完成 schema 检查，再创建 Moonlight repository。
2. 首次启用云同步时执行 cloud-first snapshot；只有第一次完整、可验证的成功快照才能写 durable bootstrap marker。
3. bootstrap 前不得把本地数据自动当成云端真相上传；已有本地 Moonlight 数据需要用户确认“合并到此账号”或作为 legacy migration 处理。
4. 如果云返回空 snapshot，而本地/历史统计证明该 owner 曾有行，视为 suspicious empty，阻断覆盖并进入可重试错误。
5. 版本冲突、可疑空快照、tombstone 清理属于 blocking failure；按当前协调器策略最多 3 次，退避 1s/5s/30s，仍失败则保留本地和明确提示。
6. 云任务只接受当前 `AccountSessionLease`；完成/进度/统计/异常回调必须带 table + operation + lease，旧 store 回调不能更新新账号页面。
7. 账户切换先关闭 mutation gate，等待 Moonlight journal、secret restore、pairing persistence、table snapshot 全部 drain，再 quiesce 旧 store。
8. restore/import 期间 `restore quarantine` 阻断普通 Moonlight 写入；完成验证并原子切换后才重开 gate。
9. 页面层只能订阅 repository/materialized snapshot 和请求 Coordinator refresh，不能持有 CloudStore、直接拉表、写 bootstrap marker 或在每次 onAppear 做云合并。

当前 `CloudLifecycleSafetyPolicy` 的云生命周期 v2、远端加密生命周期 v2、portable backup v3 write 和 legacy REST transfer 开关均为 fail-closed 状态。Moonlight 不得为了赶进度绕过这些总门；P8 的退出条件必须包含相应策略已具备、灰度开关明确且关闭时零上传。

~~~mermaid
flowchart TD
  Begin["账号切换/退出开始"] --> Gate["关闭 Moonlight mutation 与启动入口"]
  Gate --> Barrier["SensitiveDataBarrier 停止 PIP/后台/native/输入/媒体/secret restore"]
  Barrier -->|失败| Block["切换 fail closed；保留当前 owner；用户重试或返回"]
  Barrier -->|完成| Drain["等待 journal、云任务与旧回调归零"]
  Drain --> Quiesce["quiesce 旧 CloudStore；撤销旧 lease"]
  Quiesce --> Bind["绑定新 ownerScopeId/storeIdentity/storeInstance"]
  Bind --> Schema["schema + cloud-first/bootstrap 检查"]
  Schema -->|异常/可疑空快照| Quarantine["阻断写入；重试或隔离"]
  Schema -->|成功| Load["只加载新 owner 的 host/profile/trust/secret 状态"]
  Load --> Open["重开 mutation gate 和 Moonlight 入口"]
~~~

### 7.8 旧共享库迁移和隔离

未来如果已有实验版 Moonlight 数据、手工导入或旧共享 store，迁移必须复用当前 `LegacySharedStoreMigrationPolicy` 的所有权原则：

- 行内 owner 缺失、owner 冲突、UnionID 无法验证、secret owner 不唯一：进入 `migrationquarantine`，不猜测归属。
- 只有已验证 UnionID 与目标账号一致，才可迁入账号 store；只有明确 device-local 的记录才可迁入设备本地 store。
- host/profile/settings 可在完整校验后迁移；trust/secret 还需 secure-store owner 和加密 envelope 证据，无法证明则要求重新配对。
- 每次迁移写 receipt，包含来源 store、来源行 hash、目标 owner、结果、原因、时间和版本；重复运行幂等。
- 隔离数据不出现在普通主机列表；仅在“数据修复”页显示数量、来源和“导出脱敏诊断/删除/重新配对”动作。
- 绝不因为重新安装、静默登录或账号切换，把旧 device-local 配对身份自动提升成云账号身份。

### 7.9 单表选择、逻辑记录选择和删除语义

普通云同步选择器只暴露一个物理项“Moonlight（主机、配置与设置）”，对应 `moonlightrecord`。表被选中后仍需按 recordType 和敏感度二次授权：

当前 [CloudSyncSelectionPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncSelectionPolicy.ets) 的新安装默认是空数组，因此 `moonlightrecord` 的有效默认必须是“未选择/不上传”。下表的“表选中后默认”只描述用户显式勾选这张物理表、账号与 store 已 ready、`CloudLifecycleSafetyPolicy` 总门通过之后的 recordType 行为，不能被实现为安装默认打开。

| recordType | 表选中后默认 | 用户额外选择 | 关闭/删除行为 |
| --- | --- | --- | --- |
| settings | 同步 | 无 | 停止上传，按用户选择保留本地或生成 tombstone |
| host | 同步 | 无 | 级联 profile/trust 的影响预览 |
| profile | 同步 | 无 | 保留本地 app cache，不删除主机应用 |
| trust | 不自动跨设备启用 | “同步信任摘要” | 新设备仍需确认；删除不等同于删除 secret |
| secret | 关闭 | “同步配对身份”+端到端加密就绪+再次确认 | 先撤销恢复/上传，再 tombstone；本机私钥是否删除另行确认 |

用户不能在 cloud selector 中看到五张逻辑表，也不能因为勾选 `moonlightrecord` 就自动上传 secret。删除云数据、删除当前设备数据、从主机解除配对、删除某一 profile 是四个不同动作，确认页必须分别说明影响设备、可恢复性和主机端状态。

### 7.10 单表容量、索引、留存和服务端安全

- `id` 是唯一物理主键；owner/recordType 是必须校验的业务隔离维度，不宣称 RDB 中存在并未定义的 `owner + id` 复合主键。
- 目标二级索引固定为 `(userid, recordtype, deletedat)`、`(ownerid, recordtype)`、`(updatedat)`；P0 必须在云数据库验证允许的联合索引、排序和分布式表限制。若平台不支持某索引，需记录替代查询/分页成本和数据上限，不得静默全表扫描。
- `payload`/`ciphertext` 设置明确长度上限；应用图标、日志、媒体包、性能时间序列不进入表，避免单行/总容量失控。
- app catalog 仅本地缓存并设过期时间；profile 只存 titleSnapshot 和 appId。
- tombstone 有最短跨设备传播窗口，清理必须确认所有 active device generation 已观察到或达到服务端留存策略；不能本地删除后立即物理清除云行。
- 服务端规则按已认证用户限制 `userid`，客户端仍做 owner/envelope/hash 校验；任何客户端字段都不能替代服务端授权。
- 设置和非敏感记录也遵守数据最小化；IP/域名、MAC/WOL、主机名可能构成个人网络信息，应在隐私说明、导出和诊断中脱敏。
- 给用户提供账户级“删除所有 Moonlight 云数据”流程：先阻止新写、生成/确认删除集、等待云终态、清理本地 bootstrap/selection，失败时可重试且不谎报完成。

### 7.11 本地便携备份、导出和恢复

当前 `PORTABLE_BACKUP_V3_WRITE_ENABLED` 为 fail-closed。Moonlight 在该总门、格式版本、恢复事务和安全评审全部通过前不得被加入便携备份写入；不能因为云表已存在就被当前 [LocalBackupService.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LocalBackupService.ets) 的通用表遍历意外导出。

首版普通便携备份的合同：

- Moonlight 首次出现于 `LOCAL_BACKUP_VERSION=3`；v1/v2 reader 不认识 Moonlight 时必须明确拒绝过新文件，v3 reader 对 v1/v2 文件按“没有 Moonlight 数据”处理，不生成默认行。
- 只包含经过当前 owner 验证的 host/profile/settings，以及脱敏 trust 摘要；不包含 secret/client private key、PIN、rikey/rikeyid、session/access token、完整客户端证书内容。
- 不包含 `moonlightlocalrecords` mirror、journal、quarantine、migration receipt、bootstrap marker、图标/应用目录缓存、诊断或 recovery marker；这些都是可重建或设备专属状态。
- manifest 记录备份格式/版本、App 和 Moonlight schema 版本、创建时间、recordType 计数、规范化内容 hash、来源 owner kind 和不可逆短标识；不保存原始 UnionID、硬件 ID 或 installationId。
- 导出前展示包含范围和明确排除项；文件生成成功、hash 校验和系统分享目标接管分别是不同终态，取消分享不谎报“备份失败”。

“带配对身份的加密备份”是未来独立功能，不借普通备份夹带 secret。它必须另行通过端到端 KDF/密钥托管、恢复身份确认、吊销、HUKS wrapping 可移植性和威胁模型评审；未通过时唯一跨设备路径是恢复 host/profile 后重新配对。

恢复必须由 `AccountSessionCoordinator` 串行执行：

1. 解析到 restore quarantine，不接触当前 live 表；
2. 验证 manifest/hash、版本、所有 row validator、owner kind、AAD 和引用完整性；
3. 显示新增/覆盖/冲突/忽略/隔离计数，用户确认目标 owner；
4. 对同 id 使用第 7.4 节 baseVersion/mutation 合同，host identity/trust 冲突阻断；不按导入文件时间覆盖；
5. 已登录且该表启用云同步时，先完成 cloud-first/bootstrap，再决定导入数据是否可排队上传；
6. 在当前 `AccountSessionLease` 内原子提交，任何失败整批回滚；切换账号、锁屏或取消立即撤销 restore lease；
7. device-local 备份默认仍恢复为 device-local；迁入账号 scope 必须经过单独、逐类的数据迁移确认，secret 永不随普通迁移。

测试矩阵覆盖旧备份→新 App、新备份→同版本、过新版本拒绝、损坏 hash、重复导入幂等、账号 A 文件导入 B、device-local→账号、恢复中杀进程/切账号、与云端 tombstone/并发 mutation 冲突，以及磁盘不足时当前数据保持不变。

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

在功能正式开放前，现代“添加主机”FAB 的协议选择器应先展示 Moonlight 占位入口：使用 Moonlight 官方品牌图标和 `Moonlight` 名称，整项采用禁用态，并显示“即将支持”；点击不得触发 `onSelect`、创建草稿、打开路由、写入设置或产生云记录。占位入口只是产品预告，不得让用户误认为当前版本已经具备配对或串流能力。功能开关与 P0-P8 门禁全部通过后，才可移除禁用态并接入新增主机流程。

不要把 Moonlight 的应用目录塞进通用 HostListPage 的“连接主机”按钮里。HostListPage 只显示主机摘要和最近使用的 profile；点击 Moonlight 主机进入其 app catalog，点击 app profile 先进入第 8.14.6 节的启动确认 Sheet，再由用户明确开始串流。

### 8.2 新增主机完整流程

1. 用户点击新增资源，选择 Moonlight。
2. 页面展示“自动发现”和“手动输入地址”两个入口，并说明需要主机运行 Sunshine 或兼容 GameStream 服务。
3. 自动发现显示主机名、局域网地址、最近发现时间和可达性；发现结果必须去重 serverUuid。
4. 手动添加校验地址、端口、IPv4/IPv6 格式，并提供网络测试，不直接保存错误地址。
5. 读取 serverinfo；若未配对，进入配对说明页，提示用户在主机端确认 PIN。
6. 配对页以四个大号只读数字展示客户端生成的 PIN，提供“重新生成”“按需朗读”“取消”和倒计时，并持续显示“请在 Sunshine/GFE 主机端输入”；App 内没有 PIN 输入、粘贴、自动提交或默认写系统剪贴板。
7. challenge 与服务器证书校验成功后、正式标记 paired 前，展示服务器证书指纹摘要、主机名和“信任此主机”确认；用户拒绝则 best-effort unpair 并清理临时配对态。
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
| 串流基础 | 会话结束行为 | 只断开 | “同时退出主机应用”是单次显式动作，不能默认杀主机游戏 |
| 视频 | HDR | 关闭 | 仅 capability 全链路通过后显示 |
| 视频 | YUV 4:4:4 | 关闭 | 仅专业/验证设备显示 |
| 视频 | 低延迟/平滑 | 低延迟 | 影响 jitter buffer 和 decoder queue；显示取舍 |
| 视频 | 画面缩放 | 保持比例 | 可选铺满/原始尺寸；触摸映射必须使用实际 content rect |
| 视频 | 帧节奏 | Auto | 根据协商 fps/显示刷新率选择；不提供未经验证的强制高刷 |
| 视频 | 色彩范围/色域 | Auto | 使用 Rec.601/709/2020 与 limited/full 协商；HDR 未通过时不伪造 |
| 视频 | 性能优先级 | 平衡 | 可选低延迟/画质/省电，映射到明确参数组合而非神秘开关 |
| 音频 | 音频 | 开启 | 失败可在会话内降级为无音频 |
| 音频 | 声道 | Stereo | 5.1/7.1 只在设备和主机都支持时显示 |
| 音频 | 音量/静音 | 100%/否 | 应受系统音量和 AVSession 控制 |
| 音频 | 延迟策略 | Auto | 低时延路径不可用时回普通路径并解释；不允许无限缩小 buffer |
| 输入 | 键盘捕获 | 手动开启 | 避免打开页面就吞掉系统快捷键 |
| 输入 | 系统快捷键转发 | 关闭 | 只有 P0 逐组合真机探针通过的项才显示；逐项授权并始终保留本地逃生键 |
| 输入 | 鼠标模式 | Auto | raw relative/capture 探针通过时优先相对，否则默认绝对/触摸；不可用模式不显示 |
| 输入 | 远端光标 | Auto | 主机/协议支持时决定本地或远端显示，避免双光标 |
| 输入 | 触摸模式 | 触摸 | 多点触摸保留 id；兼容模式可转鼠标 |
| 输入 | 控制器槽位 | Auto/1 | 多手柄时允许显式选择 |
| 输入 | 死区/反向轴 | 设备默认 | 高级页按设备保存；校准结果仅本地，跨设备不直接套用 |
| 输入 | 虚拟控制 | MVP 仅基础鼠标/键盘 | 完整虚拟手柄按阶段开放；布局覆盖写 profile |
| 输入 | Rumble | 首版隐藏/关闭 | 当前 API 23 Game Controller 头文件未发现反馈输出；独立官方能力和真机探针通过后显示 |
| 网络 | 自动发现 | 开启 | mDNS 失败不影响手动连接 |
| 网络 | 首选地址族 | Auto | IPv4/IPv6 失败后可回退 |
| 网络 | 主机控制端口 | Auto/高级可改 | 分开保存 HTTP/HTTPS/RTSP 或 base-port 策略；显示恢复默认 |
| 网络 | 网络类型 | Auto | local/remote/auto 影响包长；只允许诊断高级页覆盖 |
| 网络 | 计费网络串流 | 每次询问 | 蜂窝/计费网络显示预计码率，不自动长期放行 |
| 网络 | 自动重连 | 开启，有限预算 | 展示 0.5/1/2/4/8s 策略和总预算；用户停止立即取消 |
| 网络 | Wake-on-LAN | 关闭 | 仅校验 MAC/广播地址后显示；不承诺公网 |
| 网络 | 串流加密 | Auto（推荐） | 可选要求全流加密/兼容模式；实际协商结果进入 HUD/诊断 |
| 网络 | 允许 legacy SHA-1 | 关闭 | 用户主动开启并显示风险 |
| 网络 | 公网/非本地连接 | 关闭提示 | 只改变提醒，不提供中继承诺 |
| 后台 | PIP | 开启 | 以系统能力和首帧为前提 |
| 后台 | 后台音频 | 开启 | 需要合法 AVSession/后台准入 |
| 后台 | 无可见 Surface 时视频 | 丢弃并保活/系统决定 | 不缓存无限视频帧；回前台请求 IDR |
| 安全 | 证书变更 | 阻断 | 不提供“永远信任” |
| 安全 | 保存配对身份 | 仅本机 | 使用安全存储；删除主机时二次确认 |
| 云 | 同步 host/profile/settings | 关闭（新安装有效默认） | 用户显式选择 moonlightrecord、账号/store ready、cloud-first 和生命周期总门全部通过后才生效 |
| 云 | 同步 trust | 关闭；表选中后可确认 | 跨设备仍需本地信任确认，不能因 host/profile 同步自动开启 |
| 云 | 同步配对身份 | 关闭 | 需要端到端加密和单独确认 |
| 界面 | 减少动效 | 跟随系统；不可读时 App 内手动 | 关闭持续 halo/循环动画和 HUD 缩放，不影响状态反馈 |
| 界面 | 使用实色界面 | 跟随减少透明度；不可读时 App 内手动 | 将 blur/material 降级为 Theme 实色 surface，保持对比度 |
| 诊断 | 统计 overlay | 关闭 | 开启后展示 RTT、丢包、FEC、decode 和 underrun |
| 诊断 | 日志级别 | Error | Debug 需要明确提示可能包含网络元数据 |

UI 必须根据 capability 隐藏或禁用设置，并显示原因。例如“AV1：设备解码器不可用”“7.1：当前输出设备只有双声道”，不能让用户保存一个永远失败的组合。

### 8.6 配对、云同步和删除的用户确认

需要确认的高影响动作：

- “重新配对此主机”只重建该主机的 pairing/trust 关系；“重新生成当前 owner 的 client identity”会影响使用该身份的全部主机，必须展示完整影响清单；
- 信任新证书会改变后续 TLS 验证对象；
- 同步配对身份会把高敏感凭据复制到云端；
- 删除主机会同时删除 profile、trust 和可选 secret；
- 关闭云同步是否保留本地记录；
- 清除应用数据是否包括本地私钥。

所有确认页都要告诉用户影响范围、可恢复性和是否会影响其他设备。普通“删除 host”不应直接删除用户账号下其他 Moonlight 主机。

### 8.7 与当前应用一致的视觉设计合同

Moonlight 不建立独立皮肤。所有页面和浮层必须直接消费 `Theme.ets`/`AppTheme` 语义 token，并随系统深浅色、用户 accent、壁纸和 halo 策略变化：

| 设计维度 | 当前项目合同 | Moonlight 使用规则 |
| --- | --- | --- |
| 字体 | HarmonyOS Sans；caption 12、body 15、bodyLarge 17、subtitle 19、title 24、headline 30、display 34 | 正文/状态/标题只从 token 取值；串流统计可使用等宽数字特性，但不引入新字体 |
| 间距 | xs 4、sm 8、md 12、lg 16、xl 20、xxl 32 | 页面、卡片、分组和 HUD 以 4vp 网格组合；不散落 13/17/23 等私有值 |
| 圆角 | xs 4、sm 8、md 12、lg 16、xl 20、xxl 24、full 100 | 主机卡片保持现有约 14/16 的视觉尺度；按钮、标签、sheet 和 HUD 用现有语义圆角 |
| 控件高度 | btnSm 36、btnMd 44、btnLg 56；navHeight 56 | 主要动作至少 44vp；串流内紧凑图标视觉可小，但命中区仍不低于 44vp |
| 动效 | fast 100、normal 300、slow 500 ms | 普通状态 100/300ms；页面/sheet 服从系统；实时画面不做模糊/缩放重动画 |
| 色彩 | bg、card、sheetBg、cardBorder、surface、divider、text/text2/text3、accent、success/warning/error 等语义色 | 禁止硬编码浅色/深色；在线、警告、失败除颜色外必须有文字/图标 |
| 材质 | HostListPage 已有 card、blur、wallpaper、halo 和 immersive material | 主列表沿用；串流画面上 HUD 使用低不透明 surface + 必要模糊，性能不足或减少透明度时降级为实色 |

具体组件基线：

- `HostProtocolPicker` 保持现有协议选项结构：选项约 68vp、左右 18vp、图标视觉尺寸约 24vp、标题 16、副标题 12、圆角 16、间隔 10。Moonlight 位于 VNC 之后；预告阶段整行使用现有禁用透明度/语义色，右侧以文字 badge 显示“即将支持”，不能只依赖灰色表达不可用。`ResourceFabPicker` 只承载 SSH 密钥、2FA 和中继等资源添加方式，不为 Moonlight 重复增加主机协议入口。
- Moonlight 协议身份图标使用官方项目实际发布的品牌图形，不使用通用游戏手柄、月亮、显示器或第三方重绘图替代。首选来源固定为本计划已审计 Moonlight Qt revision `546cb72e32e5ac04bbc7e0b3a254176e5696685a` 的 [`app/res/moonlight.svg`](https://github.com/moonlight-stream/moonlight-qt/blob/546cb72e32e5ac04bbc7e0b3a254176e5696685a/app/res/moonlight.svg)；实施 P0 仍需确认当时官方仓库是否已更新品牌资产或使用规则。
- 官方图形应作为本地资源随 HAP 打包，禁止运行时热链 GitHub/CDN，也禁止从搜索引擎、图标站或第三方 fork 下载。若 HarmonyOS 资源管线需要把 SVG 转为 PNG/WebP，必须保留原始 256×256 viewBox、圆形边界、白色内圆和八向放射图形的比例与留白，只做确定性的格式/尺寸转换，不重绘、不裁切、不改变品牌构图；原始上游文件、转换脚本/参数和输出 SHA-256 一并留档。
- 官方图标由 `Image`/项目品牌资源策略渲染，不强行塞入只返回系统 `Resource` Symbol 的 `ProtocolIconPolicy`。可为协议图标策略增加“system symbol / branded asset”两类明确返回值，但不得让其他页面自行硬编码路径。Host picker、主机卡片、详情页、设置页和诊断页必须消费同一个 Moonlight 品牌资源 owner。
- 禁用占位态通过整行 opacity 和项目语义色实现，不修改官方素材文件来制作“灰色版”；浅色、深色、accent、减少透明度和高对比度下都要验证图标边界清楚。图标提供 `accessibilityText="Moonlight"`，不可用状态另行播报“即将支持”，不能把品牌图形本身当作唯一状态信息。
- 主机卡片沿用 `HostListPage` 的 card palette、边框/blur、约 14vp 圆角和 66/80vp 紧凑/常规高度；Moonlight 的在线、配对、同步信息通过现有 secondary/tertiary 文本和状态 badge 表达。
- 空间不足时先隐藏诊断摘要和最近 codec，不隐藏主机名、配对警告、主动作和可访问名称。

### 8.8 导航、sheet 和设置路由

当前 `HostListPage` 使用单个 mounted `bindSheet` 承载资源/安全选择和设置叶页。Moonlight 必须进入这个既有 owner：

1. `sm` 使用带 drag bar 的底部 sheet；`md/lg/xl` 使用居中 sheet；mask 和 dismiss 行为保持当前实现。
2. 不在 Moonlight sheet 内再弹第二个 bindSheet；需要深层流程时先关闭 owner sheet，等待现有 360ms 路由节奏，再进入下一个 leaf/page。
3. PIN、证书变更、secret 云同步和删除属于不能误触关闭的事务页：支持系统返回，但有未提交敏感状态时使用 dirty-dismiss 确认。
4. `SettingsAccordionPolicy` 中 Moonlight 作为独立协议分组放在 VNC 之后，保持 RDP → RustDesk → SSH → VNC → Moonlight 的既有认知顺序。
5. `SettingsSheetRoutePolicy` 为 Moonlight 分配独立连续 mode 范围和 owner；不得复用 VNC 12–22 或通过布尔值组合路由。
6. 手机/平板沿用浮动 HDS Tabs；PC/2in1 `xl` 沿用 sidebar。进入串流后临时隐藏主导航，但退出后恢复原 tab/sidebar、滚动位置和焦点。
7. 任何异步结果只更新当前 route owner；用户关闭配对/诊断页后，旧请求不得重新打开 sheet。

### 8.9 多设备响应式布局

唯一断点来自 `BreakpointUtil.ets`：sm `[320,600)`、md `[600,840)`、lg `[840,1440)`、xl `>=1440`；折叠态强制 sm，展开/半折叠使用 md/lg，折叠设备不升级到 xl。

| 场景 | 列表/目录 | 添加、详情和设置 | 串流内 |
| --- | --- | --- | --- |
| sm 手机/折叠态 | 单列卡片；底部主动作；搜索收起 | 单列、底部 sheet、表单可滚动 | 横屏优先但不强制；HUD 上下/边缘布局；虚拟控件避开安全区 |
| md 平板/展开折叠 | 2 列目录或主列表+轻详情 | 居中 sheet/双栏表单；PIN 和说明并排可选 | 画面主区 + 可收起侧栏；手柄/键鼠提示不遮首要内容 |
| lg 大平板/横屏 | 主机/应用 2–3 列，详情可常驻 | 左摘要右设置；危险动作固定底部 | 画面 + 诊断/控制侧栏；侧栏关闭后画面占满 |
| xl PC/2in1 | 现有 sidebar + 内容区；多列卡片 | 独立详情 pane；鼠标 hover/右键和键盘完整支持 | 自由窗口/全屏；鼠标捕获条；Esc 先释放捕获再处理返回 |

窗口、折叠和旋转变化必须只重排 ArkUI，不隐式停止/重启串流。短屏、软键盘、分屏和自由窗口下，PIN、停止、信任确认等关键动作始终可见或可滚动到达。安全区、圆角屏、打孔区和系统手势区统一由窗口 inset 驱动，禁止用固定状态栏高度定位实时控制。

### 8.10 串流 HUD、输入模式和虚拟控制

HUD 分三层，避免一次性铺满画面：

- 常驻最小层：仅在需要时显示连接质量点、重连/安全阻断和输入捕获提示。
- 单击快捷层：返回/停止、键盘、鼠标捕获、控制器、音频、PIP；3–5 秒无交互自动隐藏。
- 侧边控制中心：画面/音频/输入/网络/诊断的当前会话临时设置，并提供“保存为此应用默认”。

体验规则：

- “停止串流”始终可达，危险动作与“返回应用目录”区分；主机 quit 失败不阻塞本地清理。
- 鼠标捕获前给出一次性说明；PC 上第一次 Esc 只释放捕获，第二次才打开返回/停止逻辑。
- 软键盘打开时暂停手势型虚拟鼠标区域，防止触摸穿透；关闭键盘要补发所有远端 key-up。
- 网络提示按严重度节流：轻微抖动只更新质量指示，持续丢包显示非模态行动建议，媒体中断才覆盖重连卡片。
- 重连遮罩保留最近一帧但明确显示“画面已暂停”和最后更新时间；不能让静止画面看起来仍在线。

虚拟控制分阶段：

1. MVP：最小触摸鼠标区、左右键/滚轮、键盘入口、停止/释放，满足无实体外设时的基础操作。
2. 第二版：系统化虚拟手柄，含双摇杆、方向键、ABXY、肩键/扳机、菜单键、透明度/大小/位置、左右手布局和安全区自动避让。
3. 长期：按 profile 保存布局、导入/导出、组合键和宏；宏涉及安全/反作弊风险，默认不进入首版。

虚拟手柄的控制区域必须有视觉按下态、可访问标签和可关闭入口；按钮位置变化要先退出编辑模式再影响输入。实体手柄连接时默认收起虚拟手柄，并允许用户选择混合输入。

### 8.11 无障碍、焦点、文本和多输入

- 所有图标按钮提供 `accessibilityText/Description`；动态状态用合适的 live announcement 节流播报，不能每帧朗读延迟。
- PIN 可用四格视觉展示，但语义上是一个只读的“4 位主机配对码”；默认朗读“已生成配对码，请在主机端输入”，只有用户明确触发“朗读配对码”才逐位播报，避免旁观泄露；离开页面、超时或取消后立即清空。
- 主机卡片、应用卡片、设置、确认页和 HUD 都有确定性焦点顺序；选中态、获焦态、按下态和禁用态可同时正确表达。
- XComponent 串流画面本身标为“远程串流画面”；虚拟控件建立独立语义节点，不让读屏焦点落入不可操作的视频像素。
- 支持系统字体放大；两行副标题可换行，主动作不因 2 倍字体消失。串流统计 overlay 可横向/纵向滚动，不压缩关键停止按钮。
- 普通正文对背景的目标对比度至少 4.5:1，大字和重要非文本控件至少 3:1；深浅色、壁纸/halo 打开和关闭都要测。
- `btnMd 44` 作为最小触控命中合同；相邻虚拟按键保留防误触间距。触控、鼠标、触控板、键盘和手柄焦点都能完成“添加—配对—启动—停止”。
- API 23 探针支持时尊重系统“减少动效/减少透明度”；不支持读取时提供 App 内同名替代设置，并把持续 halo/循环动画默认关闭。启用后关闭自动 HUD 淡入缩放和非必要模糊，实色 surface 仍保持状态可见。
- 错误、在线、云状态和 codec 能力不可只靠红绿、图标或震动，必须有文字或读屏状态。

### 8.12 所有页面状态和文案合同

每个异步页面都必须显式覆盖：

| 状态 | UI | 用户动作 | 禁止行为 |
| --- | --- | --- | --- |
| 初始/空 | 说明 Sunshine 前置、自动发现/手动添加 | 开始发现、查看帮助 | 空白页或自动申请无关权限 |
| 加载 | 阶段名称、可取消、超过阈值显示已等待时间 | 取消、转手动 | 无限 spinner |
| 离线缓存 | 显示数据时间和“离线” | 使用已配对本地主机、重试 | 把缓存写成实时在线 |
| 部分成功 | serverinfo/目录/媒体哪一层成功 | 继续可用部分、诊断 | 用一个“连接失败”吞掉原因 |
| 空目录 | 主机在线但无 app | 刷新、去主机配置 | 删除 host/profile |
| 能力降级 | 原设置、实际协商值、原因 | 本次接受、保存新默认 | 静默改设置 |
| 配对/信任阻断 | PIN/指纹/风险/影响范围 | 重试、重新配对、取消 | 自动信任新证书 |
| 同步中/待同步 | 当前 owner、记录类型、队列状态 | 查看详情、稍后重试 | 阻断本地局域网串流 |
| 云冲突/隔离 | 冲突对象、两端摘要、secret 特殊风险 | 选择、重新配对、保留本地 | secret last-write-wins |
| 恢复/迁移 | 数据来源、目标账号、隔离数 | 确认合并、导出诊断、删除隔离 | 猜 owner |
| 重连 | 断线时间、attempt/预算、画面暂停 | 立即重试、退出 | 无限后台重试 |
| 致命错误 | 用户可行动文案 + 脱敏技术码 | 重试、诊断、返回目录 | 显示私钥/IP/PIN |

文案使用项目现有简洁、非技术化语气。主文案说明“发生了什么”和“用户现在能做什么”，技术码放在展开的诊断区域。所有成功 toast 都基于真实终态，不在仅写入本地 journal 或仅发起云请求时宣称“已同步/已删除”。

### 8.13 UI 验收资产

实施时必须产出可审查的页面状态清单和截图矩阵，覆盖：

- light/dark、默认/自定义 accent、壁纸/halo 开关；
- sm/md/lg/xl、手机横竖屏、折叠/展开、平板、PC/2in1 自由窗口；
- 默认字号和大字号、屏幕朗读、键盘焦点、减少动效/透明度；
- 无主机、发现中、未配对、证书变化、空目录、离线缓存、能力降级、串流、PIP、重连、云冲突、迁移隔离和删除；
- 触控、鼠标、键盘、实体手柄和虚拟控制；
- 旧 RDP/RustDesk/SSH/VNC 入口、设置顺序、卡片高度和 sheet 路由无视觉/交互回归。

截图只能证明布局；配对、焦点、输入释放、旋转连续性和屏幕朗读还必须有录屏/自动化/真机操作证据。

### 8.14 第三次审计后的完备页面与人因设计合同

本节是 Moonlight UI/UX 的实施级合同；如与 8.1–8.13 的概括性描述存在粒度差异，以本节更具体的页面、交互、浮层和验收规则为准，但不得放宽前述安全、云同步、生命周期和能力门禁。

#### 8.14.1 人因目标与统一原则

Moonlight 同时面对“只想立即开玩”的熟练用户和“不理解主机、PIN、codec、码率”的首次用户。设计以识别优于回忆、渐进披露、就地反馈、防误触、最小视觉遮挡和跨输入一致为核心：

1. **任务优先而非参数优先**：主路径只回答“连接哪台主机、启动哪个应用、是否现在开始”；codec、色域、包长等放入有默认值的高级层。
2. **分阶段减少选择压力**：单屏不同时暴露发现、配对、应用选择和全部串流参数。每个步骤只保留一个主动作、一个次动作和必要的取消/返回。
3. **Fitts 命中合同**：普通触控热区不低于 44×44vp；串流内高频键盘/控制模式/停止入口不低于 48×48vp；相邻危险与普通动作至少间隔 12vp，危险动作不放在用户连续滑动/点击的末端。
4. **Hick 选择合同**：一级快捷操作最多 5 个，超出进入“更多”；同一设置行默认提供不超过 4 个常用预设，更多值进入二级选择或自定义。
5. **错误预防优先**：不允许点击应用卡片后无确认地占用计费网络、强退主机现有应用或覆盖 profile；地址、证书、能力和网络问题在对应字段/阶段就地显示。
6. **控制—反馈邻近**：用户改变模式后 100ms 内出现按下/选中反馈；需要网络/native 的动作立即进入 pending 状态，400ms 后展示阶段，3s 后展示已等待时长，10s 后提供诊断/取消，不出现无限 spinner。
7. **沉浸与安全并存**：串流画面默认无永久大工具栏，但边缘控制柄、系统返回逻辑和键盘/手柄可达路径保证停止不依赖隐藏手势。
8. **同协议内一致、跨协议可迁移**：添加页沿用 VNC `VncSheetScaffold` 的固定 header/滚动 body/固定 footer；设置沿用 HostListPage accordion + leaf Sheet；连接内沿用 VNC 紧凑工具栏、RustDesk 自动收起顶栏、RemoteModifierPanel 和 DiagnosticsHud 的交互语法。
9. **模式状态可见**：触控、触控板、相对鼠标、键盘捕获、控制器槽位、静音、HDR/降级、PIP 和重连都必须同时有图标、短文本和无障碍状态，不能只改变颜色。
10. **中断可恢复**：来电、锁屏、切网、旋转、折叠、PIP、软键盘、鼠标捕获和焦点变化均先完成输入 release，再改变媒体/Surface；UI 不用“页面还在”推断 native 会话仍有效。

#### 8.14.2 信息架构与页面地图

~~~text
添加主机 FAB
  └─ 协议选择（Moonlight 预告期禁用；开放后进入添加流程）
      └─ Moonlight 添加主机 Sheet
          ├─ 1/4 查找主机：自动发现 / 手动地址
          ├─ 2/4 验证主机：身份、地址、可达性、命名
          ├─ 3/4 配对与信任：PIN、证书指纹、失败恢复
          └─ 4/4 完成：目录摘要、默认 app/profile、保存/保存并打开

Moonlight 主机卡片
  └─ 主机详情页
      ├─ 应用目录（默认 tab）
      ├─ 主机状态与网络诊断
      ├─ 主机级设置
      ├─ 配对/证书管理
      └─ 删除/重新配对

应用卡片
  └─ 启动确认 Sheet
      ├─ 有效设置摘要与本次覆盖
      ├─ 网络/主机忙/能力降级提示
      └─ 开始串流
          └─ 连接阶段页/遮罩
              └─ 串流页面
                  ├─ 最小状态层
                  ├─ 快捷控制条
                  ├─ 控制中心 Sheet
                  ├─ 键盘/修饰键/虚拟控制器
                  ├─ 诊断浮窗
                  └─ 重连/安全/停止事务层
~~~

用户从已配对主机再次启动最近应用时，主路径应不超过“主机卡片→应用卡片→开始串流”三次明确动作；首次添加的四步不是四张独立页面栈，而是一个可回退、保留草稿且由单一 Sheet owner 承载的事务流。

#### 8.14.3 Moonlight 添加主机 Sheet

整体外观使用 Moonlight 版共享 Sheet scaffold：最大宽度 620vp，手机 `SheetType.BOTTOM`、其他断点 `CENTER`；header 显示官方 Moonlight 图标、标题、“n/4 + 步骤名”和返回；body 独立滚动；footer 固定放返回/下一步/保存。软键盘采用 `RESIZE_ONLY`，不把 footer 顶出可视区。退出时若已有手输地址、已选主机或已生成临时 identity，弹出“继续添加 / 丢弃草稿”，但扫描结果本身不算脏数据。

**1/4 查找主机**

- 顶部双选项卡为“自动发现”和“手动输入”，默认自动发现；切换不清空另一页输入。
- 自动发现先显示 2–3 行 Sunshine 前置说明，再按“已保存”“新发现”分组展示主机卡片。卡片包含主机名、局域网地址脱敏摘要、在线/已配对状态、最近发现时间和选择圆点。
- 扫描区必须有“正在发现（已找到 n 台）”“暂停”“重新扫描”和“改用手动输入”，不能只有旋转指示器。只有用户进入自动发现时才申请/解释所需局域网发现能力；拒绝权限后手动输入仍完全可用。
- 多地址按 server UUID 合并成一张卡，展开后显示 IPv4/IPv6/域名候选和 RTT；不以主机名或 IP 单独去重。
- 手动页包含“主机地址”一个主要输入和折叠的“自定义端口”。支持域名、IPv4、带方括号 IPv6 和粘贴 `host:port`；解析结果在输入框下实时显示，不在提交后才报格式错误。
- footer 主按钮为“验证主机”，未选中/地址非法时禁用并有说明；返回回协议选择。

**2/4 验证主机**

- 顶部状态卡同时显示“正在联系主机 / 已找到 Sunshine / 兼容 GameStream / 无法验证”，并列出当前尝试的地址族和可取消进度。
- 成功后显示服务器名称、server UUID 短指纹、服务端类型/版本、配对状态、应用目录能力和媒体端口检查摘要；地址与端口可展开编辑。
- 用户填写“显示名称”，默认取服务器名称但不自动覆盖用户已编辑值；可选 Wake-on-LAN 信息折叠在高级区域。
- TCP 控制面成功但 UDP 尚未验证时允许继续，明确写“可以保存主机，启动前仍会检查媒体网络”；服务端版本命中安全阻断时禁止下一步并给出升级说明。
- 若同 owner 已存在相同 server UUID，主动作改为“查看已有主机”，可选择“更新地址”；不创建重复记录。
- footer 为“上一步 / 继续配对”或已配对时“上一步 / 检查信任”。

**3/4 配对与信任**

- 未配对时使用独立事务卡显示四位 PIN：视觉上四个大号数字格，语义上一个只读敏感值；主说明固定为“请在主机端输入此 PIN”，并显示主机名、倒计时和当前阶段。
- 操作为“重新生成”“按需朗读”“取消配对”；默认不复制 PIN、不自动朗读、不允许输入框编辑。PIN 超时后立即变为不可用并清除内存，页面明确要求重新生成。
- 配对网络等待期间保留取消；失败在卡内显示“主机未确认 / PIN 错误 / 连接中断 / 版本不兼容”，分别提供重新生成、检查 Sunshine、网络诊断，不用一个通用 toast。
- challenge 成功后切换到证书信任卡，展示主机名、SHA-256 指纹分组摘要、首次见到时间和“该指纹将用于识别这台主机”；主按钮“信任并继续”，次按钮“拒绝并取消配对”。
- 已配对且指纹匹配时不重复展示 PIN，只显示“身份已验证”；证书变化必须红色阻断，不能在添加流程内默认覆盖旧 trust。

**4/4 完成与复核**

- 摘要卡显示名称、主机类型、首选地址、配对/信任、网络检查和数据保存范围；地址仅显示必要摘要。
- 拉取应用目录并展示最多 3 个最近/推荐 app 缩略图与“共 n 个应用”；目录失败不丢弃已完成配对，提供“稍后刷新”。
- “默认打开”可选“应用目录”或一个 app；不强迫创建 app profile。选中 app 后只生成继承全局设置的轻量 profile。
- 高级折叠只提供“为此主机覆盖串流默认值”入口，不在完成页复制完整设置表。
- footer 为“保存”和主强调“保存并打开应用目录”；只有用户已选择 app 且通过启动前检查时才可出现“保存并启动”，避免首次添加后意外占用网络。
- 保存成功必须以 owner store 持久终态为准；云同步排队只显示“已保存，等待同步”，不能写“已同步”。

#### 8.14.4 主机详情与应用目录

主机详情页在 sm 为纵向页面，在 md/lg 为主机摘要 + 应用网格，在 xl 为 HostList sidebar + 常驻详情 pane。顶部主机摘要不使用独立品牌皮肤，沿用 `Palette.card/surface/cardBorder`、HarmonyOS Sans 和当前 accent：

- 左侧官方 Moonlight 图标与主机名；次行显示“在线 / 未知 / 离线 / 需重新配对”、最近成功地址和最后在线时间。
- 右侧主动作“启动最近应用”仅在存在最近 profile 且预检可用时显示；其他动作进入“更多”。
- 状态 chips 包括“已配对”“证书变化”“待同步”“主机忙”“目录缓存”，每项有文字；颜色只是增强。
- 快捷区为“唤醒”“刷新目录”“网络诊断”“主机设置”，不可用时保留位置并解释原因，避免布局跳动。

应用目录页面：

- 顶部固定搜索、筛选（全部/最近/收藏/隐藏）和刷新；刷新时保留旧目录并在顶部显示进度，不清空网格。
- app 卡使用 3:4 封面、标题、主机运行状态和 profile 摘要；封面缺失时使用统一占位图，不拉伸低分辨率图片。
- 触控单击 app 打开启动确认 Sheet；鼠标双击/Enter 仍默认打开同一确认，只有用户显式启用“受信任局域网快速启动”后才可直接开始。
- 每张卡有可见“更多”按钮：编辑此应用设置、收藏、隐藏、查看详情；长按/右键提供同样菜单作为冗余。
- 主机已有应用运行时，在目录顶部显示“主机正在运行：X”；提供“继续当前会话”“启动所选应用”“结束主机应用”三个语义清晰的动作，最后一项为危险操作并独立确认，禁止自动 cancel 后重试。
- 空目录显示 Sunshine 配置引导、刷新和诊断；离线时展示目录缓存时间，允许编辑 profile，但“开始串流”禁用并说明主机离线。

#### 8.14.5 设置首页、作用域与完整设置项

Settings accordion 在 VNC 后加入 Moonlight，摘要为“串流、音频、输入、网络、安全、后台和云同步”。展开后使用与 VNC 相同的卡片和 `protocolActionRow`，包含以下叶页：

1. **快速设置**：体验预设、有效配置摘要、恢复推荐值。
2. **视频与画面**：分辨率、帧率、码率、codec、HDR、色彩、帧节奏和缩放。
3. **音频**：启用、声道、主机同时播放、音量和焦点行为。
4. **输入与控制器**：触控/触控板/鼠标、键盘捕获、控制器、虚拟控制和反馈。
5. **网络与安全**：地址策略、计费网络、重连、加密、legacy 兼容和 Wake-on-LAN。
6. **后台与画中画**：PIP、后台音频、锁屏/无 Surface 行为。
7. **性能监视与诊断**：HUD、采样、日志和脱敏导出。
8. **Moonlight 云同步范围**：唯一 `moonlightrecord` 的 settings/host/profile/trust/secret 选择。
9. **配对身份与 Trust**：当前 client identity、主机证书、重新配对和本机清理。
10. **管理 Moonlight 主机**：主机、profile、缓存和删除状态。

全局、主机和 app profile 使用同一套叶页组件，但顶部必须有固定的“当前作用域”卡：

- `全局默认`：修改所有未覆盖主机/app 的默认值。
- `此主机`：默认显示“继承全局”；打开“为此主机覆盖”后才允许编辑。
- `此应用`：逐组或逐项继承，值旁显示来源 badge（全局/主机/此应用）。
- `仅本次`：只在启动确认/连接控制中心出现，离开会话自动丢弃；用户可显式“保存为此应用默认”。
- 每个叶页提供“重置本页覆盖”，每一行提供“恢复继承”；不以清空整个 profile 代替单项恢复。

设置控件合同如下：

| 分组 | 首层呈现 | 二级/高级设计 | 防错与即时说明 |
| --- | --- | --- | --- |
| 体验预设 | 平衡（推荐）/低延迟/高画质/省电 | 展开查看映射到的分辨率、fps、码率、codec | 用户改任一映射值后标记“自定义”，不神秘覆盖 |
| 分辨率 | 自动/设备原生/1080p/更多 | 720p、1440p、4K、16:10 和自定义宽高 | 只展示 host+device 可用项；预计缩放与比例在下方预览 |
| 帧率 | 自动/30/60/更多 | 90/120/自定义仅能力通过后出现 | 显示设备刷新率、主机上限与实际协商可能回退 |
| 码率 | 自动（推荐）+ 质量三档 | 自定义 Slider + 数字输入，范围随分辨率/fps 变化 | 同时显示预计每小时流量和当前网络建议；不以固定 10–100Mbps 套所有场景 |
| Codec | 自动/H.264/HEVC/AV1 | 10-bit、YUV444 进入专业项 | 每项显示主机/设备支持；不可用不是可保存选项 |
| HDR/色彩 | HDR 开关，默认关 | Rec.601/709/2020、limited/full 仅高级 | HDR 打开时自动展示必要条件，不静默改 codec/色域 |
| 帧节奏 | 自动/低延迟/平滑 | jitter/queue 只在诊断实验项 | 用一句话说明延迟与稳定性取舍 |
| 音频 | 音频开关、Stereo | 5.1/7.1、主机同时播放、焦点策略 | 输出设备不支持时禁用并说明；音频失败可无音频继续 |
| 触控 | 直接触控/触控板/绝对鼠标/相对鼠标 | 移动/滚动速度、轻点超时、死区放在“灵敏度”Sheet | 预设低/标准/高优先；高级 Slider 有重置和实时试用区 |
| 键盘 | 手动捕获、显示本地快捷键提示 | 系统快捷键逐项转发 | 始终保留本地逃生键；改变捕获先 release 当前按键 |
| 控制器 | 自动槽位、实体优先 | 映射、死区、反向轴、虚拟布局 | 只显示系统已枚举设备；反馈/运动能力 fail closed |
| 网络 | 自动地址、自动重连、计费网络每次询问 | 地址族、base port、local/remote、包长进入高级诊断 | 改端口先测试；公网提示不宣称提供中继 |
| 安全 | 串流加密 Auto（推荐） | 要求全加密、legacy SHA-1 例外 | 当前主机不支持时显示影响；高危选项需要风险确认 |
| 后台 | PIP、后台音频 | 无 Surface 视频策略只读展示实际行为 | 系统不允许时显示入口和原因，不假开关 |
| 诊断 | HUD 关/简洁/详细 | 采样间隔、日志级别、导出 | Debug 显示隐私提示；导出前脱敏预览 |

设置不在滑杆拖动每一帧持久化；拖动结束/选择确认后写 draft，用户离开叶页时原子提交。保存失败保持 draft 和错误，不回滚 UI 到看似成功的值。能力变化导致旧值失效时保留“原值 + 当前实际值 + 原因”，由用户选择采用推荐值或继续保留待设备可用。

#### 8.14.6 启动确认与连接阶段页面

点击应用后打开单一启动确认 Sheet，避免 MoonlightOH 式点击即 launch：

- header 显示 app 封面、标题、主机名和在线状态。
- “本次串流”摘要以四个可扫读 chips 显示分辨率、fps、codec/HDR、预计码率；点“调整”进入本次覆盖，不写 profile。
- 网络卡显示局域网/计费网络、控制面/UDP 预检和预计流量。计费网络按用户策略要求单次确认。
- 输入卡显示当前模式和实体控制器数量；没有控制器不阻止桌面 app，但游戏型 profile 可提示虚拟/实体控制方案。
- 主机忙时默认“继续当前会话”或返回目录；“结束现有应用并启动”必须独立危险确认。
- 主按钮“开始串流”，次动作“保存本次设置为此应用默认”；后者只有实际变更时出现。

开始后进入连接阶段页/全屏遮罩，而不是连续弹 LoadingDialog。背景使用 app 封面模糊/主题实色，中央阶段卡按顺序显示：联系主机→启动/恢复应用→协商 RTSP→建立视频→建立音频→建立输入→等待首帧。已完成阶段打勾，当前阶段有进度，未开始阶段弱化；底部始终有“取消”。

- 0–400ms 不闪现加载卡，避免快速局域网连接的视觉抖动。
- 400ms 后显示当前阶段；3s 后显示已等待时长；10s 后增加“查看网络诊断”。
- 视频首帧前不宣称“已连接”；音频失败时阶段卡提供“无音频继续 / 返回设置”；输入失败时提供“只观看继续 / 重试输入”。
- 用户取消先冻结新输入、取消 HTTP/RTSP/common-c，再回目录；迟到成功事件因 generation 不匹配被丢弃。
- 失败页保留 app/主机上下文，主文案为可行动原因，技术码折叠；动作按错误类型提供“重试”“降低设置重试”“网络诊断”“返回目录”。

#### 8.14.7 串流页面层级与 Z-order

串流页不建立新的全局视觉语言。画面背景固定黑色；浮层使用 `rgba(14,18,28,0.72–0.90)`、白色主文本、当前 accent 和轻边框，确保在任意游戏画面上可读；减少透明度时改为不透明深色 surface。层级固定如下：

| 层级 | 内容 | 输入规则 |
| --- | --- | --- |
| L0 远端画面 | XComponent/Surface、letterbox、远端光标 | 默认接收远端输入；几何变化由 content rect 驱动 |
| L1 虚拟输入 | 触摸区域、虚拟鼠标/手柄、按键按下态 | 只在相应模式启用；与系统手势安全区和 HUD 热区互斥 |
| L2 最小状态 | 边缘控制柄、连接质量、捕获/只读/PIP 状态 | 控制柄热区≥44vp；状态本身不拦截画面输入 |
| L3 快捷工具与辅助浮窗 | 快捷控制条、修饰键、诊断 dock、控制器提示 | 打开时进入 `overlayInteraction`，阻止触摸穿透并先结束远端手势 |
| L4 事务遮罩 | 重连、证书变化、音视频致命错误、停止确认 | 模态；冻结所有远端输入并保持本地退出可用 |
| L5 系统 owner | 单一 bindSheet、系统权限/输入法/PIP | 同时最多一个 App Sheet；关闭完成后才打开下一个 |

进入任何 L3/L4 交互前发送当前 touch cancel、mouse up、key up/controller neutral；关闭后不重放旧事件。浮层拖动位置按设备/方向/profile 保存，但旋转、折叠或窗口缩小时先 clamp 到安全区，不能留在屏幕外。

#### 8.14.8 最小状态层与快捷工具条

**边缘控制柄**是永远可发现的入口：默认吸附握持手相反侧的中部安全区，视觉为 28–32vp 宽胶囊，但命中区至少 44×56vp；显示 Moonlight 星芒/“控”短标识和连接质量点。可拖动换侧，不响应双击危险动作。首次串流用一次非模态气泡说明“点此打开控制，系统返回也可打开”。

**连接质量 chip**默认仅在状态变化后显示 3s：`良好 / 波动 / 较差 / 正在重连`，不以实时数字持续吸引注意。持续较差超过阈值才保留，点击打开网络诊断。安全/输入捕获状态可与其并列，但一行最多两个 chip。

**快捷工具条**由单击画面空白、边缘控制柄、三指轻点或系统返回（未捕获时）打开；3s 无交互自动收起，触控板/鼠标 hover 或焦点在条内时暂停计时，用户可固定：

- sm：底部/侧边 5 项——控制模式、键盘、控制器、更多、断开。
- md/lg：最多 7 项——增加音频、画面/PIP；不足项进入更多。
- xl：顶部居中，沿用 RustDesk 自动收起语法，支持鼠标 hover、快捷键和固定。
- 每项为图标 + 8–10fp 短标签，热区至少 48vp；当前模式使用 accent + 文本，不用纯色判断。
- “断开”使用危险色并与其他按钮隔 12vp；不能把“退出主机应用”放在工具条一级。
- 工具条展开不会改变画面缩放；落在画面上的区域由 overlay hit map 排除远端输入。

#### 8.14.9 控制中心 Sheet 的完整功能

“更多”打开唯一控制中心。sm 为底部 Sheet，md/lg/xl 为居中/右侧控制 pane；顶部显示 app、主机、串流时间和实际协商摘要。分组不超过六个，最近使用分组可记忆但危险动作位置固定：

| 分组 | 一级功能 | 二级/行为 |
| --- | --- | --- |
| 会话 | 返回画面、PIP、断开本地串流 | “退出主机应用”单独放底部危险区；显示主机响应成功/失败/未知 |
| 控制 | Touch/触控板/绝对鼠标/相对鼠标、键盘、修饰键、控制器 | 触控板灵敏度与映射进二级；模式切换即时生效并可保存到 profile |
| 画面 | 适应/填充/1:1、低延迟/平滑、亮度/HDR 实际状态 | codec/分辨率/fps 如需重连则标“下次连接”，不伪装为实时生效 |
| 音频 | 静音、音量、输出设备摘要、主机同时播放 | 声道/codec 需要重连时进入下次连接草稿；焦点丢失显示原因 |
| 网络 | 质量、RTT/丢包/FEC 摘要、立即重连、地址 | 切换地址先冻结输入并重建 generation；不允许叠加第二会话 |
| 诊断 | 简洁/详细 HUD、复制脱敏诊断、日志 | 默认用户只看可行动摘要；专业指标进入可拖动 dock |

任何当前会话修改都显示 `仅本次` badge；存在变更时控制中心底部出现“保存为此应用默认”，并列出将保存的项目。关闭 Sheet 不自动持久化临时设置。

#### 8.14.10 连接中的全部辅助浮窗/功能

| 浮窗/功能 | 默认状态与位置 | 内容和动作 | 人因/安全合同 |
| --- | --- | --- | --- |
| 鼠标捕获提示 | PC 首次捕获时顶部 chip，3s 后缩成图标 | “已捕获鼠标 · Esc 释放” | 第一次 Esc 只释放，第二次 Esc 打开工具条；永远不吞系统保留逃生键 |
| 触控模式提示 | 模式切换后画面中央下方 1.2s | 模式名 + 一句手势摘要 | 不阻塞输入；读屏只在用户触发切换时播报一次 |
| 虚拟键盘 | 底部，跟随输入法/横竖屏 | 文本输入、Esc/Tab/Ctrl/Alt/Shift/Win、Fn、方向/Del/Enter | 打开前 cancel 画面手势；关闭/失焦/退出补发全部 key-up；不允许触摸穿透 |
| 修饰键面板 | 复用 RemoteModifierPanel，可吸附拖动 | 单击一次、长按锁定、Fn 层、组合键 | once/locked 有文字/边框双重状态；会话终止全部归零 |
| 快捷键面板 | 从修饰键/控制中心打开 | Ctrl+Alt+Del、Alt+Tab、Win、复制粘贴等能力允许项 | 高风险组合需明确标签；不支持项置灰并说明，不发送半套按键 |
| 虚拟鼠标条 | 无实体鼠标且选择触控板时按需显示 | 左/右/中键、滚轮、拖拽锁 | 热区≥48vp；拖拽锁有常驻状态和一键释放；实体鼠标接入可自动收起 |
| 虚拟控制器 | MVP 默认关闭；第二版按 profile | 摇杆、方向键、ABXY、肩键/扳机、菜单、布局编辑 | 实体手柄接入默认收起；编辑布局期间不发送游戏输入；退出/切后台发送 neutral frame |
| 控制器设备 chip | 手柄连接/断开后显示 3s | 设备名、槽位、电量/能力、重新映射 | 不暴露系统未提供能力；断开时远端槽位立即 neutral |
| 音频焦点 banner | 焦点丢失时顶部非模态 | “音频已暂停：其他应用正在播放” + 恢复 | 不反复抢焦点；恢复由策略/用户操作决定 |
| 网络质量 banner | 持续劣化后顶部 | 原因摘要、降低码率/诊断 | 节流，轻微抖动不遮画面；建议动作先作为本次设置 |
| 性能 HUD | 默认关；简洁模式为可拖动 76×38 chip | FPS/延迟/质量；点击展开 | 复用 DiagnosticsHud 拖动阈值、吸附和安全区；不每帧触发 ArkUI 重排 |
| 详细诊断 dock | 用户主动打开 | 实际 codec、分辨率/fps、码率、RTT、丢包/FEC、解码/渲染 p50/p95、音频 underrun、输入丢弃 | 指标采样节流；专业值不可用显示“—”，不造 0；支持脱敏复制 |
| PIP 控制 | 系统 PIP | 播放/暂停语义、返回、断开 | PIP 不提供危险“退出主机应用”；无 Surface 输入全部锁定 |
| 重连遮罩 | 媒体中断才出现 | 最近一帧 + “画面已暂停”、attempt/预算、立即重试、退出 | 禁止把旧静帧当在线；输入冻结；超预算进入失败终态 |
| 安全阻断卡 | 证书变化/加密降级 | 指纹变化、影响、重新配对/退出 | 位于 L4，不允许“一直忽略”；技术细节可展开 |
| 错误恢复 Sheet | 解码/音频/输入可降级或失败 | 降低画质重试、无音频继续、只观看继续、诊断 | 只提供真实可执行动作；错误码折叠且脱敏 |
| 停止确认 Sheet | 点断开/第二次返回 | 默认“仅断开并保留主机应用”、危险“同时退出主机应用”、取消 | 默认焦点在仅断开；主机 quit 失败不得阻塞本地 cleanup；结果分成功/失败/未知 |
| 系统/应用 toast | 短暂完成反馈 | 已切换模式、已保存 profile 等 | 只有真实终态才宣称成功；错误不用瞬时 toast 承载全部说明 |

#### 8.14.11 输入、手势与误触防护

- 画面单击默认只负责远端点击；“单击显示 HUD”只在用户轻点边缘空白/控制柄或显式开启时生效，不能和直接触控模式争用同一手势。三指轻点可以作为快捷入口，但控制柄/返回键必须提供等价可发现路径。
- Touch 模式一指/多点透传；触控板模式一指移动、单击左键、双指滚动、双指轻点右键、长按拖拽。所有手势在设置页提供动画/文字示例，可关闭冲突手势。
- 直接触控与画面 pinch/pan 的优先级按模式决定；开始缩放前 cancel 远端触点，缩放结束后不把最后触点重放给远端。
- 工具条、浮窗和虚拟键盘出现时建立明确 hit map；“半透明”不意味着点击可穿透。
- 控制模式改变、旋转、Surface 重绑、PIP、后台、锁屏、失焦、手柄断开和会话 generation 变化都必须调用统一 input flush。
- 触控板高级项采用“低/标准/高”预设 + 可选高级 Slider；实时试用区只移动本地示意光标，不向主机发送测试动作。
- 长按只用于增强动作（修饰键锁定、卡片更多），不得作为添加、设置、停止、释放捕获的唯一入口。

#### 8.14.12 响应式、握姿和多输入适配

| 场景 | 关键布局 | 高频操作位置 | 特殊规则 |
| --- | --- | --- | --- |
| sm 竖屏添加/设置 | 单列 Sheet、固定 footer | 主按钮靠下，返回在 header | 软键盘不遮主动作；大字号时预设自动换行 |
| sm 横屏串流 | 画面全屏、边缘柄、底部 5 项工具条 | 根据握姿把柄吸附到非主握侧 | 左右系统返回区、打孔/圆角和虚拟手柄保留安全间距 |
| md 折叠展开/平板 | 主机摘要 + 两列目录；控制中心居中/侧栏 | 边缘柄靠近当前握持侧但不遮内容 | 半折叠不跨铰链放关键按钮；旋转只重排不重连 |
| lg 大平板 | 2–3 列目录、详情/设置双栏 | 画面侧边控制中心 | 虚拟键盘可缩放，不能覆盖停止入口 |
| xl PC/2in1 | sidebar + 详情 pane；串流自由窗口/全屏 | 顶部自动收起工具条、键盘快捷键、右键菜单 | hover/focus/pressed/disabled 完整；鼠标捕获与窗口失焦规则明确 |
| 手柄主导 | app grid 有焦点环，A 选择/B 返回 | 快捷控制可由保留组合键打开 | 焦点不进入纯视频像素；停止需可通过手柄完成但防单键误触 |

握姿自适应只改变控制柄/常用控件对齐，不改变危险动作语义或步骤顺序。用户拖动后的显式位置优先于自动握姿；窗口尺寸显著变化时按归一化边缘/比例恢复并 clamp。

#### 8.14.13 组件 owner 与复用边界

后续实现建议形成以下 owner；名称是计划合同，不代表本轮创建文件：

| 组件/页面 owner | 职责 | 复用来源 |
| --- | --- | --- |
| `MoonlightHostAddFlow` | 四步添加、草稿、异步 generation、保存/打开 | VncAddFlow + VncSheetScaffold + RustDesk discovery |
| `MoonlightHostDetailPage` | 主机摘要、状态、目录 owner 和详情动作 | HostCard/HostList 响应式布局 |
| `MoonlightAppCatalog` | 搜索/筛选/封面/缓存/更多菜单 | MoonlightOH app grid 的任务模型，不复制视觉代码 |
| `MoonlightLaunchSheet` | 有效配置、计费网络、主机忙、开始串流 | 项目单 bindSheet 路由和连接前置 Sheet |
| `MoonlightConnectStageOverlay` | 阶段进度、取消、降级和失败恢复 | RemoteSessionState + 非模态事务卡 |
| `MoonlightSessionToolbar` | 最多 5/7 项快捷控制、收起、固定 | VncSessionToolbar + RemoteSessionTopBar |
| `MoonlightControlCenter` | 六组本次设置和保存 profile | RemoteDesktop control panel + settings leaf components |
| `MoonlightDiagnosticsHud` | 简洁 chip、详细 dock、拖动/吸附 | RustDesk/VNC DiagnosticsHud；新增 Moonlight 指标 |
| `RemoteModifierPanel` | 修饰键、Fn、组合键 | 原组件直接复用，仅通过 capability 配置 |
| `MoonlightControllerOverlay` | 虚拟控制器、布局编辑、实体手柄状态 | 独立 owner，不混进键盘/鼠标面板 |

Moonlight 不复用 RustDesk/VNC 的协议状态或设置存储，只复用无状态视觉构件和通用输入/浮层基础设施。所有 owner 读取同一个 sessionId/generation/capability snapshot；浮窗不得各自直接查询 native 全局状态。

#### 8.14.14 人因与任务验收指标

除视觉截图外，P8/P9 必须用真机录屏、可访问性检查和事件日志验证：

- 已配对回访用户从主机详情启动最近 app 不超过 3 次明确动作；从沉浸画面执行“仅断开”不超过 2 次动作。
- 首次用户不阅读外部文档也能找到自动发现、手动添加、PIN 所在位置、返回和取消；5 名内部走查者中至少 4 名一次完成，失败点必须回灌设计。
- 所有常用/危险触控热区达到本节尺寸；用触控边界可视化验证相邻热区无重叠，危险动作不存在滑动穿越触发。
- 地址错误、主机重复、PIN 超时、证书变化、计费网络、codec 不支持、音频失败、输入失败和 UDP 不通均在对应任务上下文内恢复，不要求用户返回首页重来。
- 工具条打开/关闭、控制模式切换和浮窗拖动不产生远端幽灵点击；每条路径都有 input flush/neutral 事件证据。
- 连接阶段在 400ms/3s/10s 阈值行为正确；取消后无迟到路由，首帧前不显示“已连接”。
- light/dark、自定义 accent、减少透明度、大字号和屏幕朗读下，官方品牌图标、状态、badge 和危险动作均可辨认；图标无文字时必须有 accessibilityText。
- 方向键/键盘/手柄焦点可遍历所有可交互元素，不进入 disabled/纯装饰节点；焦点离开并返回页面后恢复到合理对象。
- sm/md/lg/xl、旋转、折叠/展开、自由窗口和 PIP 变化不重启会话、不丢停止入口、不把浮窗留在屏幕外。
- 与 RDP/RustDesk/SSH/VNC 做并排回归：同类主动作、返回、Sheet、设置行、工具条、诊断 dock 和确认文案的视觉/交互语法一致；Moonlight 的游戏特性不反向改变旧协议默认行为。

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
  S->>N: ensure owner-scoped client identity
  N-->>S: client cert ready；private key 留在安全边界
  A->>S: 开始配对
  S->>N: generate PIN + pairing challenge
  N-->>A: 展示短期 PIN 和倒计时
  U->>H: 在主机端输入 PIN
  N->>H: 客户端证书 + pairing request/challenge
  H-->>N: 服务器证书 + challenge response
  N->>N: 校验挑战并临时保留服务器证书
  N-->>A: provisionalPairing + 服务器证书指纹
  U->>A: 确认首次信任
  A->>S: commit trust
  S->>N: persist pin / finalize pairing
  N-->>S: paired
  opt 用户已显式选择 moonlightrecord 且云总门通过
    S->>C: 同步获准的 host/profile/settings
  end
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
  A->>S: stop(disconnect 或 explicit quit)
  S->>N: quiesce input + 全量安全释放
  opt 用户另行选择“退出主机应用”
    S->>N: quitHostApplication(short timeout)
    N->>H: cancel/quit
  end
  S->>N: disconnectLocalStream / release media/control/RTSP
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
- 读取 host app/session end reason；这不是由客户端发起的 quit 成功回执；
- 清理本地 decoder/audio/input；
- 标记 profile 的 lastExitReason；
- 返回 app catalog，允许用户再次启动，不自动重复 launch。

### 9.7 停止、删除、退出账号和卸载

正常停止顺序：

1. 禁止新的键鼠/触摸/手柄事件；
2. 对所有 down 状态发送安全 up/cancel；
3. 默认“只断开”不请求主机 quit/cancel；只有用户本次明确选择“退出主机应用”时，才在 HTTPS/主机控制身份仍可用时 best-effort 请求 cancel/quit 并设置短超时；
4. 无论第 3 步成功、失败或超时，都停止输入反馈；
5. 停止音频接收、flush Opus/OHAudio；
6. 停止视频接收、等待 in-flight decode callback；
7. 停止控制流和 RTSP；
8. 解除 Surface、销毁 decoder、audio renderer、NAPI references；
9. 写 session metrics、主机动作 outcome 和 lastUsed/lastExit；
10. 将 session 状态变为 idle。

产品和实现必须使用两个不同命令，不能让一个布尔参数在底层含糊分支：

- `disconnectLocalStream`：默认动作。停止本地输入、媒体、控制、网络和所有系统资源，主机应用继续运行，完成后可在应用目录显示“主机端仍在运行/可恢复”。
- `quitHostApplication`：用户在停止确认页或目录中单独选择的危险动作。先 quiesce 新输入并补发安全 release，再在控制面可用时发送 best-effort cancel/quit，随后无条件执行 `disconnectLocalStream` 的其余清理；主机拒绝、超时或网络断开只影响 quit 结果，不得阻塞本地资源终态。成功、失败和未知分别记录，UI 不在仅发出请求时宣称“已退出主机应用”。

自动重连预算耗尽、系统回收、App 崩溃和账号安全切换一律按本地断开语义处理，不擅自结束主机游戏；账号 barrier 可以为保护本机敏感状态强制清理本地会话，但不能把远端 quit 当成 barrier 成功条件。

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

### 9.8 账号切换、静默登录和多设备恢复

华为账号静默登录、显式切换账号、退出账号和设备本地模式是四条不同路径，统一由 `AccountSessionCoordinator` 串行执行：

| 场景 | 先停止 | 绑定后加载 | 用户看到的结果 |
| --- | --- | --- | --- |
| device-local → 华为账号 | Moonlight 会话、配对事务、secret restore、云 mutation | 新账号独立 store；device-local 数据不自动合并 | 提示是否审查并迁移本地 host/profile；secret 默认重新配对 |
| 账号 A → 账号 B | A 的 PIP/后台/native/输入/媒体/云回调 | B 的 owner store 和 B 的 selected table | A 数据立即不可见；B 空则显示空，不借用 A 缓存 |
| 账号 → 退出并保留本地 | 同上，并撤销账号云密钥 | 新的 device-local store | 用户明确选择哪些非 secret 元数据可复制；不能保留账号 lease |
| 账号 → 完全退出清除 | 同上 | 空 device-local store | 本机 Moonlight 数据/私钥按确认清除，云端是否删除另问 |
| 同账号静默登录 | 仅在 owner/store identity 发生变化时完整 barrier | 当前 owner store | 无不必要闪屏；仍验证 lease/generation |
| 新设备/重装后同账号 | 无旧本地 session | cloud-first snapshot，host/profile/settings；trust 待确认，secret 待恢复 | 明确区分“已同步主机”与“本机已配对” |

恢复 secret 的用户流程：

1. 完成账户绑定、cloud-first 和 envelope/hash/AAD 校验；
2. 显示来源设备、配对主机、创建/更新时间和风险，不显示私钥内容；
3. 要求设备级身份/用户确认，创建短期 restore lease；
4. 解密到安全存储，验证客户端证书/私钥配对关系和服务器证书指纹；
5. 通过 serverinfo/TLS 验证后才标记为 paired；失败则隔离并建议重新配对；
6. 所有步骤都绑定当前 AccountSessionLease，切换账号/锁屏/取消时清零临时材料；
7. 成功只影响当前设备，不自动撤销其他设备 identity。

### 9.9 长期用户生命周期和产品治理

- 主机更名/换地址：以 server UUID 和证书信任识别，不因 IP 变化新建重复主机；证书变化仍阻断。
- Sunshine 升级/降级：重新探测 server generation、codec、加密和应用目录；已有 profile 保留，实际能力变化显示降级。
- 主机重装/更换证书：进入 trust changed，不把“同名/同 IP”当作同一可信主机。
- 应用目录项删除/改名：profile 保留 appId 和 titleSnapshot，标记 unavailable；用户可重新绑定新 app，不静默改 appId。
- 长期未使用：只清理可再生的图标/目录/诊断缓存；不自动删除 host、trust 或 secret。
- App 升级：schema 迁移先备份/校验，失败保持旧数据只读并阻止新写；不因新版本自动打开 codec、云 secret 或 legacy 开关。
- App 回滚：过新 schema/envelope 进入只读/隔离，不用旧版本解析并重写；为用户保留升级或导出路径。
- 功能下线/依赖安全事件：远程 feature flag 可隐藏新建/启动，但已存数据仍可查看、导出或删除；高危版本阻断时说明原因和更新路径。
- 隐私与授权：首次真正需要时再申请网络/通知/后台等权限；拒绝后保留可用降级和设置入口。诊断分享、云 secret、公网连接、legacy crypto 均单独同意。
- 数据可携带：导出默认只含非 secret host/profile/settings 和脱敏 trust 摘要；加密 secret 导出是独立高风险流程，含版本、KDF 和完整性元数据，不允许明文。
- 用户身故/账号注销/服务终止等账户级删除请求：提供 Moonlight 云记录计数、删除范围、完成状态和失败重试；本地/主机端配对是否仍存在需分别说明。

### 9.10 进程被强杀、系统回收和下次启动恢复

进程被系统直接回收、native crash、设备重启或用户强制停止时，任何 ArkTS/native cleanup callback 都可能不执行，因此不能把 `onDestroy` 当成终态保证。launch 成功前后维护一条 owner-scoped、非 secret 的 `SessionRecoveryMarker`：

| 字段 | 合同 |
| --- | --- |
| markerVersion | 可迁移版本；过新版本只提示并清理本地残留，不盲目解析 |
| ownerScopeShortId/storeIdentityHash | 稳定的当前账户/设备本地 store 归属证据；不记录原始账号标识 |
| storeGenerationAtLaunch | 只用于诊断上次会话；进程重启后 generation 变化是正常情况，不作为 marker 归属匹配条件 |
| sessionId/hostId/profileId/appId | 不透明本地引用；不得跨 owner 查询 |
| protocolCompatUniqueId | 精确兼容值的版本标签，不记录用户/硬件 ID |
| launchedAt/lastStage/lastHeartbeatAt | 单调状态快照，heartbeat 低频写入，避免每帧落盘 |
| hostAppMayStillBeRunning | launch 成功后为 true；明确 quit 成功或主机确认未运行后为 false |
| inputMayBeStuck | 当前会话第一次出现任意 down/non-neutral 输入时置 true，全部释放终态后置 false；不记录具体按键、文本、轴值或触摸内容 |
| lastRequestedTerminalAction | none/disconnect/quit，防止下次启动把“已请求”误写成“已成功” |

marker 不含 PIN、client private key、rikey/rikeyid、HTTP token、完整 IP、媒体/输入内容；它不是云记录、便携备份或自动续流凭证。正常本地断开在所有本地资源终态后清 marker；显式 quit 还记录主机响应结果。强杀发生时 marker 保留，用来承认“主机应用可能仍在运行”。

下次 App 启动的恢复顺序：

1. 先由 `AccountSessionCoordinator` 完成 owner/store 绑定，再用稳定 ownerScope/storeIdentity 匹配当前 owner marker；其他 owner marker 不查询、不展示。`storeGenerationAtLaunch` 不要求与新进程相等，也不触发跨 owner 迁移。
2. 清理上次进程遗留的 UI snapshot、AVSession/PIP/后台通知和 registry owner；这些系统外观状态不能证明 native 会话仍存活。
3. 创建全新的 session/account generation；本地不恢复旧 key-down、axis、touch 或鼠标捕获。`inputMayBeStuck=true` 时保持输入 UI 锁定，直到第 6 步远端复位完成。
4. 使用现有 trust/client identity 做 serverinfo 和“当前运行应用”只读查询；不复用旧 `rikey`/RTSP/UDP socket。
5. 若主机仍运行匹配应用，显示“上次连接意外结束”，提供“重新连接/Resume”“退出主机应用”“忽略”；若主机已停止，只提供清除提示和返回目录。
6. 永不自动 resume 或 quit；用户选 Resume 后重新生成会话密钥并完整协商 RTSP/媒体。新 input stream ready 后、开放用户输入前，发送协议支持的 touch cancel-all、所有允许键码/mouse button 的 key-up sweep、每个可见 controller slot 的全中立状态并等待可靠控制队列边界；host generation 不支持某类 reset 时保持明确警告并要求用户确认重新建立/结束主机应用，不能假装已释放。
7. 用户选 quit 执行独立主机动作；忽略只清本地 marker、不声称结束主机程序。主机不可达时保留一次可重试提醒和诊断；达到留存期限后可隐藏提示，但删除 marker 前说明无法确认主机状态。

`inputMayBeStuck` 只在“无活动输入→存在活动输入”和“全部中立→false”边界落盘，避免高频 I/O；它不替代运行时精确 pressed-set。验收覆盖任意键/鼠标按钮/触摸/手柄非中立时的前台强杀、PIP 强杀、系统内存回收、native crash、设备重启、主机应用仍运行/已停止/换应用、恢复页再次断网、账号切换后启动、marker 损坏/过新、用户选择 Resume/quit/忽略。测试必须在主机端观察全部输入已中立；诊断只记录“上次进程未完成终态”和脱敏 stage，不把系统回收误报为主机错误。

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
| Input | key down/up 配对、触摸 id、鼠标溢出、控制器轴范围、断开释放、反馈能力关闭/开启门 |
| Session | 每个 stage 的取消、重复 stop、旧 generation 事件、线程退出和 callback gate |
| Stream crypto | none/audio/video/all 协商、rikey/rikeyid 生命周期；视频 GCM tag/重放/篡改必须拒绝，音频按 FEC/reorder→CBC 的顺序做块长/序号/解码边界测试且不虚构认证；required fail-closed |
| Security | 日志脱敏、私钥不可读、AAD mismatch、hash mismatch、secret sync 权限 |

RTSP parser、SDP parser、HTTP pairing parser 和 RTP/FEC 边界都应接入 fuzz。历史上 Moonlight common-c 曾出现 RTSP parser buffer overflow 安全公告，必须参考 [GHSA-4927-23jw-rq62](https://github.com/moonlight-stream/moonlight-common-c/security/advisories/GHSA-4927-23jw-rq62)，锁定包含修复的版本，并把该类输入加入持续 fuzz。

ArkTS 层测试：

- capability policy 的交集/降级；
- HostProtocolPicker、ResourceFabPicker、route 和返回栈；
- host/profile/trust/secret record validator；
- baseVersion/mutationId/originDeviceId、resetEpoch 总序、field-level 三方合并、时钟回拨、并发 tombstone/显式复活、trust/secret 冲突阻断；
- malformed cloud row、suspicious empty snapshot、legacy owner 不明和 restore row quarantine；
- AccountSessionLease 过期、账号 A→B、storeInstance 变化、mutation gate/barrier drain 和旧云回调丢弃；
- cloud-first bootstrap、1s/5s/30s blocking retry、tombstone 清理和 selected table + recordType 二次授权；
- background/PIP stage 的可见 UI；
- ActiveRemoteSessionRegistry 的 RDP/VNC/RustDesk↔Moonlight 切换、PIP owner、旧会话 stopping 超时和旧输入/画面/音频隔离；
- SessionRecoveryMarker 的强杀/系统回收/重启/账号错配、Resume/quit/忽略和全新密钥协商；
- 普通便携备份排除 secret/mirror/journal/marker，旧新版本、损坏 hash、重复恢复、restore quarantine/原子回滚和 cloud-first；
- 取消、重试、删除、账号退出的状态转移；
- Theme token、sm/md/lg/xl、单 bindSheet owner、设置 route、焦点顺序、大字号和屏幕朗读语义；
- RDP/RustDesk/SSH/VNC 的入口顺序、卡片、设置和会话回归。

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

以下是首版 H.264 1080p60、Opus stereo、干净局域网基线的 release threshold，不是当前已达成的数据。一次 RC 必须在目标低/中/高三档设备分别报告样本数、p50/p95/p99、最大值和失败样本，不能只给平均数：

| 指标 | 首版通过线 |
| --- | --- |
| 启动到首帧 | 从 host launch 成功响应到可见首帧：p50 ≤ 3s、p95 ≤ 6s；超时必须有 stage 分解 |
| 视频稳定性 | 1080p60 连续 2h，因客户端导致的 rendered-frame drop < 1%；不可恢复黑/花屏为 0，单次不可恢复 stall > 1s 为 0 |
| 输入到显示 | 同一测量装置和主机基线下 p95 ≤ 80ms；同时报告编码、网络、decode、render 分段，不能把估算 RTT 当端到端延迟 |
| 音画同步 | 绝对 A/V drift p95 ≤ 50ms、最大 ≤ 100ms；重连/焦点恢复后 5s 内回到阈值 |
| 音频连续性 | 预热后无 >100ms 可感知 gap；renderer underrun ≤ 1 次/10min，且任何 underrun 不形成持续追帧 |
| 短断网恢复 | 网络恢复后到新关键帧 p95 ≤ 8s（模拟 3s 中断）；进入本地断网/失焦事件后 250ms 内完成所有本地输入状态释放 |
| 内存/队列 | 4h soak 的 RSS 净增长 ≤ 50MiB，video/audio/FEC/reorder/callback 队列无单调增长；达到上限按策略丢弃/重连而非 OOM |
| 生命周期 | 100 次启动/停止、Surface detach/attach、PIP/前后台组合无 crash、旧画面、串音或输入串会话；结束后 handle/RSS 回到冷基线 ±10% |
| 温控/持续帧率 | 2h 场景不得进入系统 severe/critical thermal state；不得因客户端热降频导致实际帧率持续 60s 低于协商 fps 的 90%，否则该设备档位自动降级 |
| 崩溃率 | 100 次生命周期循环和单次 4h soak 中 native/ArkTS crash、ANR/卡死均为 0 |
| UI 响应 | 主机/目录滚动和设置交互不在主线程执行网络/解码；关键操作响应 p95 ≤ 100ms，诊断 overlay 开/关的 render latency 回归 ≤ 5ms |

不同芯片的绝对 CPU、GPU、功耗和温升不能在文档中虚构一个通用数字。P0 用相同主机、网络、亮度、分辨率和采样工具为每个目标设备档锁定 CPU/power/temperature baseline；候选版本相对冻结 baseline 的 CPU 与平均功耗回归均不得超过 10%，否则说明原因、降级或阻断。none/audio/video/all 加密模式分别测量，不能用不加密结果替“要求全流加密”过门。

性能记录至少包括：glass-to-glass/高速相机或等价输入到显示测量方法、样本量、host encoder 时间、网络 RTT/jitter/loss、FEC recovery、decoder/render latency、first-frame stage、audio queue/underrun/drift、RSS/handles/queue high-water marks、CPU/GPU、系统 thermal level、温度、电量和设备电源状态。没有统一测量方法、原始结果和主机/设备 revision 的数据不能用于宣称低延迟或稳定。

### 10.6 可观测性和隐私

诊断快照应包括：

- app version、Moonlight/common-c commit、ENet revision、API23/设备型号；
- host type、server version、server UUID 哈希、地址族；
- stage 时间线和错误 code；
- stream codec、resolution、fps、bitrate、audio channels、协商后的 encryption flags（只记模式，不记密钥）；
- RTT、jitter、loss、FEC、decode/render/audio counters；
- surface/audio/input lifecycle；
- 当前 ownerScopeId 的不可逆短 hash、account/store/session generation、stale callback 计数；
- cloud record sync status、bootstrap/lease、schema/crypto version、冲突、quarantine 和 migration 计数。

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
8. 使用 Moonlight 官方品牌图标时，将上游仓库 URL、exact revision、原始路径、获取日期、原始/转换文件 SHA-256、GPL-3.0 许可证归属和本地资源路径写入第三方素材清单、SBOM/构建 manifest 与发布 notice；保留未修改的上游原件和可复现转换记录。不得以“只是图标”或“官方 Logo”为由跳过许可证、商标/品牌使用复核。

必须参考的本地规则：

- [LICENSE_DECISION_RECORD.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/LICENSE_DECISION_RECORD.md)
- [OWNERSHIP_AND_RELICENSING.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/OWNERSHIP_AND_RELICENSING.md)
- [THIRD_PARTY_SCOPE.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/THIRD_PARTY_SCOPE.md)
- [AGPL_RELEASE_ACCEPTANCE.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/AGPL_RELEASE_ACCEPTANCE.md)
- [SOURCE_OFFER.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/SOURCE_OFFER.md)
- [DEPENDENCY_UPDATE_POLICY.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/compliance/DEPENDENCY_UPDATE_POLICY.md)

### 11.2 安全要求

- 只接受包含已知 RTSP parser 修复的 common-c revision；
- Sunshine 测试/推荐主机最低为 `v2026.516.143833`，因为官方 [GHSA-ph75-mgxh-mv57](https://github.com/LizardByte/Sunshine/security/advisories/GHSA-ph75-mgxh-mv57) 将更早版本列为受严重 client-certificate authentication bypass 影响；本次审计的 `3893c5b...` 已验证为该修复 release commit `14ffa6f...` 的后继，但实施 P0 仍需按当日 advisory/compare 重新确认；
- serverinfo 识别到低于安全下限或命中新的 critical/high host advisory 时，默认阻断配对/launch 并展示版本、风险和升级入口；只有安全评审明确允许的兼容例外才可临时绕过，高危不安全主机不能作为通过互操作验收的证据；
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

首版工作量估算为 70–90 人周，20–24 个日历周是以下已到位团队在依赖及时到位时的 80% 置信区间：

- 2 名 native/媒体工程师：A 负责 common-c/HTTP/RTSP/视频/Surface，B 负责音频/输入/平台生命周期与两者交叉回归；
- 1 名 ArkTS/产品工程师：领域模型、状态机、页面、设计系统、无障碍和诊断；
- 0.5–1 名账户/云数据工程师：单表 schema、owner/lease/barrier、冲突、备份/恢复和云环境；
- 1 名 QA/自动化工程师：主机/设备/网络矩阵、性能、生命周期和截图证据；
- 安全/开源合规负责人各按阶段兼职评审，不可在 RC 才首次介入。

设备采购、Sunshine 多 GPU/OS 主机、云 schema/index/store 审批和安全/发布评审需 W0 同时启动，外部 lead time 预留 2–4 周但不计作可随意压缩的开发缓冲。API 23 解码、相对鼠标、后台或账户/云总门若需平台级修复，日历计划增加 2–6 周。HEVC/AV1/HDR、高阶反馈、加密 secret 跨设备恢复不计入首版工期。

下表的相邻阶段有日历重叠，只允许下游做接口草模、fixture、parser 单测和不接生产资源的预研；真实 Host API 集成必须等 P1 退出门，真实 RTSP/媒体集成必须等 P2 退出门。任何“并行开始”不改变第 5.1 节前置条件，也不能提前暴露 feature flag。

| 周期 | 工作 | 并行线 | 里程碑 |
| --- | --- | --- | --- |
| W0-W2 | P0 来源、license/security、API23 probe、Sunshine 主机准备 | QA 建立设备/网络/视觉/无障碍基线 | Go/No-Go 1 |
| W3-W5 | P1 common-c/platform shim 完成并过门；P2 先做 fixture/模拟器，P1 通过后才接真实 HTTP/serverinfo/pairing | ArkTS 交互原型、错误/数据模型 | P1 gate；随后可配对可列目录 |
| W6-W8 | P2 launch/resume/quit 完成并过门；P3 先做 parser/配置预研，P2 通过后才接真实 RTSP/SDP/加密/端口/IPv6 | 云表与账户 owner/lease 设计评审 | P2 gate；随后真机收到并验证媒体包 |
| W9-W11 | Native A：P4 H.264 bridge/Surface/IDR；Native B：P5 Opus/OHAudio/时钟 | ArkTS：主机/目录/配对/信任页；QA 并行首帧/A-V 基线 | H.264 + Opus 首帧 |
| W12-W13 | P6 键鼠/触摸/实体手柄输入 | 设置、session HUD、最小虚拟控制 | 可玩性闭环 |
| W14-W15 | P7 前后台/PIP/切网/重连/停止 | 诊断和全部异步状态 | 会话生命周期闭环 |
| W16-W18 | P8 单表 sync、bootstrap、迁移隔离、账号切换 barrier | 全断点 UI、屏幕朗读、双设备/重装恢复 | 数据和用户生命周期闭环 |
| W19-W21 | P9 兼容、fuzz、安全、2h/4h 性能与温控、合规 | 发布文档、SBOM、源码包 | Release candidate |
| W22-W24 | 灰度、外部设备/主机/网络复核、修复和二次门禁 | 只处理 blocker，不临时扩范围 | 正式开放或继续隐藏 |

关键路径是“P0 安全/平台探针 → P1 common-c/owner → P2 配对身份与 Host API → P3 RTSP/真实包 → P4/P5 首帧与音频 → P6 输入 → P7 生命周期/互斥 → P8 数据/UI → P9 硬化”。其中 P4 视频与 P5 音频可以由两名 native 并行，但二者都依赖 P3，且 P7 不能在任一未稳定时提前宣称闭环。W22–W24 是 15%–20% 的集成/未知风险缓冲，不得预先填满第二版功能。

若实际只有一名 native/媒体工程师，即使 ArkTS/QA 保持不变，首版应按 28–36 个日历周重排，视频、音频和输入串行推进；若整个项目只有一名工程师，则必须重新估算且不得承诺本表日期。任何资源缩减都不通过减少 security、account isolation、真机或 2h/4h soak 门禁来“追回”时间。

### 12.2 首版、第二版和长期能力

| 能力 | 首版 | 第二版 | 长期/暂不承诺 |
| --- | --- | --- | --- |
| 主机 | Sunshine 现代版本、手动地址和 mDNS | legacy GameStream | 未验证的第三方服务端 |
| 视频 | H.264、720p/1080p、30/60 fps | HEVC、1440p/4K（设备门控） | AV1、HDR、YUV 4:4:4 |
| 音频 | Opus stereo | 5.1/7.1 降混或真实多声道 | 麦克风/语音回传 |
| 输入 | 键鼠、触摸、两类实体手柄输入；反馈关闭 | 最小/系统化虚拟手柄、多手柄；官方反馈探针通过后开放 rumble | LED、motion、自适应扳机、高级映射/宏 |
| 网络 | 局域网、IPv4/IPv6、手动端口 | 公网端口配置和诊断 | 云中继、TURN、自动穿透 |
| 生命周期 | 前台、PIP、受系统允许的后台音频 | 更完整的锁屏/系统恢复 | 不受系统限制的常驻后台 |
| 云 | host/profile/settings 单表同步，trust 摘要需确认；secret 关闭 | 云生命周期 v2 和端到端加密就绪后的 secret 恢复 | 永不默认同步私钥 |

### 12.3 必须先解决的阻断项

以下任一项失败，就不能开始公开灰度：

1. API23 没有稳定的 H.264 Surface 解码；
2. common-c/ENet 依赖无法在项目双 ABI 和许可证边界内锁定；
3. 达到最低安全版本的真实 Sunshine 主机无法完成配对和 RTSP/UDP 媒体，或命中未处置的 critical/high advisory；
4. native callback 在 Surface/页面销毁后仍能触发崩溃或旧帧；
5. 输入没有可靠的按键释放和控制器断开处理；
6. OHAudio 不能稳定播放 Opus PCM 或后台恢复不符合系统规则；
7. 单云表无法做到 malformed row 隔离、secret opt-in 和确定性冲突；
8. 跨协议 ActiveRemoteSessionRegistry 无法阻止并发媒体 owner，或强杀恢复会自动误 quit/resume；
9. release source offer/SBOM/third-party notice 无法随版本交付。

## 13. 最终验收和仓库门禁

### 13.1 产品验收清单

公开开关前必须逐项打勾并留证据：

- [ ] 新用户能从新增 Moonlight 进入发现/手动添加、serverinfo、配对、指纹确认、应用目录和启动。
- [ ] 配对由客户端生成/展示 PIN、用户在主机端输入；客户端身份在配对前生成，主机只返回服务器证书/挑战，App 内不存在错误的 PIN 输入表单。
- [ ] 已配对用户能离线打开 host/profile，云端暂时不可用时仍可在本地可达网络串流。
- [ ] Sunshine 真实主机完成 H.264 + Opus + 键鼠/触摸/实体手柄闭环。
- [ ] 构建/诊断记录 common-c、ENet、Android/Qt 参考和 Sunshine 测试端 exact revision；ENet 与 common-c 要求一致。
- [ ] none/audio/video/all 加密协商和 required fail-closed 通过；rikey/rikeyid、PIN、私钥不会进入日志/云/崩溃报告。
- [ ] 视频 GCM 篡改/重放被认证拒绝；音频严格按 FEC/reorder→CBC 顺序测试且文案不声称 CBC 提供 packet authentication。
- [ ] H.264 首帧、关键帧恢复、FEC/丢包、Surface 重建和 PIP 通过。
- [ ] 音频焦点、系统音频抢占、后台、前台、停止不残留播放。
- [ ] 输入捕获、释放、页面返回、网络切换、主机退出无悬挂按键/轴/触摸点。
- [ ] raw relative mouse、pointer capture 和系统快捷键均按 P0 矩阵裁剪；不支持时可用绝对/触摸/软组合键降级且本地逃生路径始终可达。
- [ ] 旧 RDP、RustDesk、SSH、VNC 的连接、渲染、设置和云同步无回归。
- [ ] ActiveRemoteSessionRegistry 串行仲裁其他协议↔Moonlight/PIP；旧会话未终态时新会话不能获得媒体/输入 owner。
- [ ] API 23 Game Controller 输入与至少两类手柄通过；rumble/LED/motion 未经独立官方能力探针不会出现在可用设置中。
- [ ] Moonlight 只使用 moonlightrecord 一张云业务表，本地 mirror 不注册成云表，secret 默认不上云。
- [ ] 新安装 moonlightrecord 默认未选择；22 列 schema/DDL、长度、三个目标索引、baseVersion/mutationId/originDeviceId 和 `id` 单主键与实现一致。
- [ ] cloud-first bootstrap、可疑空快照、阻断重试、tombstone、malformed/legacy quarantine 和删除终态均有双设备证据。
- [ ] device-local↔账号、账号 A↔B、退出保留/清除、静默登录、重装恢复均不跨 owner；旧 lease/callback 无法写新 store。
- [ ] 账户切换时 SensitiveDataBarrier 能停止 Moonlight PIP/后台/native/输入/媒体/secret restore 并清零会话密钥；失败时切换 fail closed。
- [ ] 两台设备同时编辑 host/profile/settings 可按 field-level/baseVersion 总序确定性合并；trust/secret 身份冲突不静默覆盖，tombstone 不被旧离线写复活。
- [ ] 普通便携备份排除 secret/mirror/journal/recovery marker；恢复经过 owner/restore quarantine/cloud-first/原子回滚矩阵。
- [ ] light/dark/accent/wallpaper/halo、sm/md/lg/xl、折叠屏/平板/PC、单 sheet、焦点、大字号、屏幕朗读和减少动效矩阵通过。
- [ ] “添加主机”FAB 中 Moonlight 位于 VNC 之后；预告阶段使用同一份官方品牌资源、整项灰色禁用、显示“即将支持”且点击零副作用。官方图标的 exact revision、原始路径、SHA-256、转换记录、GPL/品牌复核、SBOM 和 notice 均可追溯。
- [ ] 正式开放后的四步添加流覆盖发现/手动输入、主机验证、PIN/证书信任和完成复核；所有异步步骤可取消，草稿、迟到回调和 owner 隔离符合第 8.14.3 节。
- [ ] 应用卡片默认先进入启动确认 Sheet；计费网络、主机忙、能力降级和仅本次覆盖均可见，不会点击即 launch、自动结束主机应用或静默持久化 profile。
- [ ] 串流 L0-L5 层级、边缘控制柄、快捷工具条、控制中心、键盘/修饰键、虚拟控制、诊断 dock、重连/安全/停止事务层均按第 8.14 节完成互斥、input flush、44/48vp 热区和多断点验收。
- [ ] 从触控、鼠标、键盘和实体手柄都能完成添加/配对/启动/释放/停止；停止与安全阻断始终可达。
- [ ] 默认“只断开”保留主机应用；显式“退出主机应用”单独报告成功/失败/未知，失败不残留本地资源。
- [ ] 前台/PIP 强杀、系统回收和重启后只提示 Resume/quit/忽略，不自动重连或结束主机应用，且使用全新 generation/会话密钥。
- [ ] 证书变更、legacy SHA-1、UDP 不通、codec 不支持、音频失败都有可行动文案。
- [ ] 诊断信息脱敏，崩溃和日志不包含 PIN、私钥、session token 或媒体包。
- [ ] 功耗、温度、内存、CPU、延迟和稳定性达到第 10.5 节目标；未达即阻断对应机型/codec/分辨率/帧率组合，不得仅记录例外后继续宣称支持。
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

本轮只更新本文档，不修改现有源代码、配置、依赖、云表或测试。工作树中此前已有的云数据生命周期、VNC、RustDesk、SSH、ArkTS 等用户变更保持原样；后续实施必须另行立项、按仓库分支门禁推进。

## 14. 参考资料和本地证据

### 14.1 Moonlight/Sunshine 官方源码和文档

- [本次审计的 moonlight-common-c commit e41355e](https://github.com/moonlight-stream/moonlight-common-c/tree/e41355ea01670fd4c830b384009d31dd0339a705)
- [本次审计的 ENet commit aca8784](https://github.com/cgutman/enet/tree/aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1)
- [本次审计的 Moonlight Android commit f10085f](https://github.com/moonlight-stream/moonlight-android/tree/f10085f552b367cf7203007693d91c322a0a2936)
- [本次审计的 Moonlight Qt commit 546cb72](https://github.com/moonlight-stream/moonlight-qt/tree/546cb72e32e5ac04bbc7e0b3a254176e5696685a)
- [本次审计的 Sunshine commit 3893c5b](https://github.com/LizardByte/Sunshine/tree/3893c5bcdadc5f0beaa127670531afbfd60519ea)
- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)
- [Connection.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Connection.c)
- [Limelight.h](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/Limelight.h)
- [VideoStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/VideoStream.c)
- [AudioStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/AudioStream.c)
- [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/src/InputStream.c)
- [moonlight-common-c license](https://github.com/moonlight-stream/moonlight-common-c/blob/e41355ea01670fd4c830b384009d31dd0339a705/LICENSE.txt)
- [Moonlight Android](https://github.com/moonlight-stream/moonlight-android)
- [Moonlight Android PairingManager](https://github.com/moonlight-stream/moonlight-android/blob/f10085f552b367cf7203007693d91c322a0a2936/app/src/main/java/com/limelight/nvstream/http/PairingManager.java)
- [Moonlight Android NvHTTP](https://github.com/moonlight-stream/moonlight-android/blob/f10085f552b367cf7203007693d91c322a0a2936/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java)
- [Moonlight Android AndroidCryptoProvider](https://github.com/moonlight-stream/moonlight-android/blob/f10085f552b367cf7203007693d91c322a0a2936/app/src/main/java/com/limelight/binding/crypto/AndroidCryptoProvider.java)
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt)
- [Moonlight Qt streaming session](https://github.com/moonlight-stream/moonlight-qt/blob/546cb72e32e5ac04bbc7e0b3a254176e5696685a/app/streaming/session.cpp)
- [Sunshine](https://github.com/LizardByte/Sunshine)
- [Sunshine RTSP source](https://github.com/LizardByte/Sunshine/blob/3893c5bcdadc5f0beaa127670531afbfd60519ea/src/rtsp.cpp)
- [Sunshine client-certificate authentication bypass advisory](https://github.com/LizardByte/Sunshine/security/advisories/GHSA-ph75-mgxh-mv57)
- [Sunshine patched release v2026.516.143833](https://github.com/LizardByte/Sunshine/releases/tag/v2026.516.143833)
- [Moonlight Setup Guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)
- [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions)
- [Moonlight WOL](https://github.com/moonlight-stream/moonlight-docs/wiki/WOL-%28Wake-On-LAN%29)
- [Moonlight common-c security advisory](https://github.com/moonlight-stream/moonlight-common-c/security/advisories/GHSA-4927-23jw-rq62)
- [RFC 8785 JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785)

### 14.2 成熟 HarmonyOS Moonlight 项目审计对照

- [MoonlightOH / moonlight-ohos](https://gitee.com/smdsbz/moonlight-ohos)：本轮主要原生参考，审计 revision `a48821e2d309c4282d79a053e6a85245eb438a7b`；用于验证 ArkUI/XComponent、添加/配对、应用目录、分层设置和连接内控制模式，不作为协议实现、视觉资产或许可证结论的替代品。
- [likuai2010/moonlight-harmonyos](https://github.com/likuai2010/moonlight-harmonyos)：历史 HarmonyOS 移植对照；用于核验早期软/硬解、音频、配对和虚拟控制器路线，不作为当前产品交互基线。

### 14.3 鸿蒙官方能力与人因设计资料

- [HarmonyOS Developer](https://developer.huawei.com/consumer/cn/develop/)
- [HarmonyOS 文档中心](https://developer.huawei.com/consumer/cn/doc/)
- [HarmonyOS 设计中心](https://developer.huawei.com/consumer/cn/design/?catalogVersion=V1)
- [HarmonyOS 设计入门](https://developer.huawei.com/consumer/cn/design/devstart/)
- [焦点导航规范](https://developer.huawei.com/consumer/cn/doc/design-guides/hmi-focus-0000001748650376)
- [光标交互规范](https://developer.huawei.com/consumer/cn/doc/design-guides/hmi-cursor-0000001795531205)
- [HarmonyOS 应用 UX 体验标准](https://developer.huawei.com/consumer/cn/doc/design-guides/ux-guidelines-overview-0000001760867048)
- [HarmonyOS 电脑应用开发入门](https://developer.huawei.com/consumer/cn/multidevice/pc/get-started/)
- [设备兼容规则](https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/device-compatible)
- [OHAudio playback](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/using-ohaudio-for-playback-V5)
- [HarmonyOS Input Kit C headers](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/input-headerfile-V13)
- [Universal Keystore Kit / HUKS ArkTS API](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/js-apis-huks-V14)
- [Asset Store Kit 概览](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/asset-store-kit-overview-V14)
- [Background Process Manager](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/js-apis-backgroundprocessmanager-V13)
- [HarmonyOS Distributed Database Codelab](https://developer.huawei.com/consumer/en/codelab/HarmonyOS-Distributed-Database/)
- [Account Kit](https://developer.huawei.com/consumer/cn/sdk/account-kit)
- [云数据库](https://developer.huawei.com/consumer/cn/agconnect/cloud-base)

### 14.4 本项目代码和规则证据

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
- [ActiveRemoteSessionRegistry.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets)
- [Theme.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/common/Theme.ets)
- [BreakpointUtil.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/utils/BreakpointUtil.ets)
- [HostProtocolPicker.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/hostadd/HostProtocolPicker.ets)
- [ResourceFabPicker.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/resourceadd/ResourceFabPicker.ets)
- [ProtocolIconPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/ProtocolIconPolicy.ets)
- [HostListPage.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/pages/HostListPage.ets)
- [SettingsAccordionPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/SettingsAccordionPolicy.ets)
- [SettingsSheetRoutePolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/SettingsSheetRoutePolicy.ets)
- [AccountScopePolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/AccountScopePolicy.ets)
- [AccountSessionCoordinator.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/AccountSessionCoordinator.ets)
- [SensitiveDataBarrier.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/SensitiveDataBarrier.ets)
- [CloudLifecycleSafetyPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudLifecycleSafetyPolicy.ets)
- [CloudSyncPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncPolicy.ets)
- [CloudSyncSelectionPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncSelectionPolicy.ets)
- [CloudSyncCoordinator.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncCoordinator.ets)
- [CloudSyncCoordinatorPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets)
- [CloudSyncLifecyclePolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncLifecyclePolicy.ets)
- [LegacySharedStoreMigrationPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LegacySharedStoreMigrationPolicy.ets)
- [LocalBackupPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LocalBackupPolicy.ets)
- [LocalBackupService.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LocalBackupService.ets)
- [VncRecord.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/model/VncRecord.ets)
- [VncRecordPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/VncRecordPolicy.ets)
- [CMakeLists.txt](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/CMakeLists.txt)
- [module.json5](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/module.json5)

### 14.5 实施开始前的最终确认

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
10. feature flag、灰度用户和回滚开关；
11. AccountSessionLease/SensitiveDataBarrier/legacy migration 的接入评审和账号 A↔B 真机脚本；
12. 单物理云表、索引/长度/留存/服务端规则和 cloud-first bootstrap 的云环境评审；
13. Moonlight 设置 route mode、官方品牌资源/辅助系统 Symbol、sm/md/lg/xl 页面状态稿和无障碍验收人；
14. 流加密策略、AES 性能结果、secret 恢复策略和 rumble/LED/motion 的明确支持结论。
15. 配对 PIN 的主机端输入流程、owner-scoped RSA identity/HUKS-OpenSSL 路线和证书轮换删除语义；
16. 默认只断开与显式 quit 的双命令合同，以及跨官方客户端 launch/resume/quit 的 protocolCompatUniqueId 互操作证据；
17. ActiveRemoteSessionRegistry 跨协议仲裁和 SessionRecoveryMarker 强杀恢复设计；
18. 22 列 moonlightrecord、并发 mutation/tombstone 总序和普通便携备份恢复评审；
19. Sunshine `v2026.516.143833` 或更高安全基线及所有当日未关闭 security advisory 的处置结论。

在这些确认完成前，Moonlight 只能保持为本计划中的待立项能力，不能通过 UI 暗示已经可连接或已经兼容全部 Sunshine/GameStream 主机。

<!-- PLAN_BODY_END -->
