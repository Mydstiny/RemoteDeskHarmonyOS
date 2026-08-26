# RemoteDeskHarmonyOS Moonlight / Sunshine 串流能力完备升级计划

> 文档状态：第四次深度审计完成；已于 2026-08-09 从 G0 开始实施
> 首次评估日期：2026-07-28；二次完成性审计日期：2026-07-29；第三次 HarmonyOS 人因/UI 审计日期：2026-08-01；第四次源码对齐日期：2026-08-08
> 当前实施基线：任务 `moonlight-complete-upgrade`；分支 `codex/moonlight-complete-upgrade`；基线 `main@aeb0cdac5`，与 `origin/main` 一致
> 当前实施进度：分支 HEAD `348b28083`；`9eadb35be`、`326f329f5`、`348b28083` 已形成手柄、Sunshine 串流 runtime 与本地 UI/设置 checkpoint。当前工作树正在完成 owner-store v5、可选第九云表、逐记录下载隔离、selection/reconcile/delete/backup 生命周期和旧八表兼容；真实 Sunshine、实体手柄、ARM64 与长稳回执仍是最终验收门，而不是继续实现云/UI 的前置阻塞。
> 2026-08-19 产品范围覆盖声明：2026-08-10 的“Moonlight 暂不接入云同步”已被用户明确撤销。本文后续所有 `PARKED_CLOUD`、`当前仅本地`、`不得注册 moonlightrecordv1` 文字仅保留为历史决策记录；当前有效合同以第 7.0 节的 2026-08-19 覆盖条款和实施台账最新状态为准。覆盖不改变两条永久边界：`moonlightlocalrecords`/`moonlightappcache` 永不注册为云表，配对私钥、客户端身份、证书与 trust receipt 继续只在设备本地。
> 适用仓库：/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS
> 上游实施锁定：2026-08-09 已只读复核并固定 moonlight-common-c `e41355ea01670fd4c830b384009d31dd0339a705`（ENet `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`、nanors `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a`）、Moonlight Android `f10085f552b367cf7203007693d91c322a0a2936`、Moonlight Qt `2e13ed9977bc31c73caf8428f08f58d793313ece`、Sunshine 测试 pin `v2026.808.164219` / `25c06d79b54f3d092d3fedd5f5ba44989f394692`；完整哈希、许可证和能力证据见 `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`
> 原评估轮次仅更新计划文件；2026-08-09 起的实施变更严格按第 15 节任务 ID、仓库门禁和 fail-closed feature policy 推进。

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
- owner-store 继续以 `moonlightlocalrecords` 作为本地事实覆盖层、`moonlightappcache` 作为可重建缓存；新增且仅新增一张可选云表 `moonlightrecordv1` 承载用户明确选择的 settings/host/profile 公共配置。旧八张云表先注册且保持原语义，第九表只有在 AGC 精确 schema 已部署并写入构建 revision 后才尝试；不把 Moonlight 数据写入 `remotehosts`、`usersettings`、`rustdeskrelays`、`vncrecordv2` 或 SSH 表；
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
| 本地持久化 | 高 | 当前已有 owner-store、MoonlightRepository、20 列 local envelope、app cache、journal、备份/删除基础；本阶段不依赖 CloudStore |
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

第四次审计收口时工作区位于 `codex/ssh-terminal-complete-upgrade`，HEAD 为 `4646fb910`，本地 `main` 为 `d2769ad4b`；状态脚本判定当前存在未完成活动任务、10 项工作树变化和 `REVIEW_REQUIRED`。审计过程中活动 SSH 分支由其他在途工作继续推进，因此这里记录最终收口快照；变化属于当前 SSH、文档和其他用户任务，本计划不接管、不覆盖、不整理，也不要求 stash、reset、切换分支或新建任务分支。第四次审计重新核对了当前 account session、物理 store 隔离、cloud-first/bootstrap、VNC 单表领域、便携备份 V3、设置 sheet router、协议入口、Theme/Breakpoint 和连接会话浮层，以下设计以这批当前源码为准。

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
| ExtensionLoader | entry/src/main/cpp/extensions/extension_loader_napi.cpp | 协议注册、会话激活、native 回调到 ArkTS 的边界；当前 decoder/audio 已具备 owner/generation 回调门 | 仍有进程级 `g_activeConnection` 和 InputHandler active adapter 边界；Moonlight 需要在不回退现有 owner gate 的前提下清除最后的全局输入/活动适配器歧义 |
| 硬解管线 | entry/src/main/cpp/render/hw_decoder.h、hw_decoder.cpp | OH_AVCodec、NativeImage、Surface、GL OES 纹理、关键帧恢复、队列上限 | Moonlight 回调是 DECODE_UNIT 链，不是简单的单 buffer VideoFrame；需要保存 SPS/PPS/VPS 和 frameType |
| GLRenderer | entry/src/main/cpp/render/gl_renderer.h、gl_renderer.cpp | XComponent、GL context、NativeImage texture、重绘和 Surface 生命周期 | 必须把旧会话回调和新会话 generation 隔离，不能把 Moonlight 纹理事件写入全局旧 owner |
| OHAudio | entry/src/main/cpp/audio/audio_player.cpp | S16LE PCM 播放、低时延模式、队列、欠载统计、暂停/恢复 | Moonlight common-c 的音频回调需要由 Opus decoder 产出 PCM；多声道必须能力探测后降级 |
| 输入处理 | entry/src/main/cpp/audio/input_handler.h、input_handler.cpp | 键盘、鼠标、滚轮、触摸输入的部分事件桥 | 当前 activeAdapter 是单全局路由；Moonlight 手柄和相对/绝对鼠标必须独立 owner |
| ArkTS 会话状态 | entry/src/main/ets/services/RemoteSessionState.ets | connecting/connected/background/foreground/disconnecting/failed 状态和时间戳 | Moonlight 需要在通用状态下增加细粒度 stage，不应让 UI 用一条 connected 猜完整可用性 |
| Native handle 生命周期 | entry/src/main/ets/services/NativeSessionHandles.ets | 后台只脱附 renderer、前台重新绑定 Surface、请求关键帧、完全断连 | Moonlight 需要补充视频暂停/丢帧、音频 flush、输入关闭和 RTSP/UDP 关闭顺序 |
| PIP/后台 | entry/src/main/ets/services/RemoteSessionPipLifecyclePolicy.ets、RemoteSessionBackgroundTaskService.ets | decoderReady、远端尺寸、PIP 准备、multiDeviceConnection、audioPlayback | Moonlight 的背景播放必须依赖实际媒体状态和 AVSession/长时任务准入，不可只复用 RDP 文案 |
| 本地主机存储 | entry/src/main/ets/services/CloudStore.ets 的 owner-store 本地 RDB、MoonlightRepository.ets、MoonlightStoragePolicy.ets | owner/lease 隔离、20 列本地 envelope、journal、幂等读回、删除/恢复和 app cache | Moonlight 当前不得进入 CloudSyncCoordinator、selectedTables、setDistributedTables 或云传输 |
| VNC 隔离数据设计 | entry/src/main/ets/model/VncRecord.ets、services/VncRecordPolicy.ets | 仅借鉴 envelope、journal、删除和备份的安全性质 | Moonlight 使用独立本地表和自己的 record policy，不复用 VNC 业务字段、表、key 或 coordinator |
| 便携备份 V3 | entry/src/main/ets/services/LocalBackupPolicy.ets、LocalBackupService.ets、BackupManifestV3.ets | 按本地表 inventory、full/redacted、owner 校验、quarantine 和事务恢复 | Moonlight 只登记 `moonlightlocalrecords`；`moonlightappcache`、session/cache、PIN、私钥和云停靠表均不进入当前本地主机备份 |

### 1.4 当前缺口

当前没有 Moonlight、GameStream 或 Sunshine 的协议实现。全仓搜索没有发现可复用的 Moonlight client core。主要结构性缺口如下：

1. RemoteProtocol 只有 rdp、rustdesk、ssh、vnc，没有 moonlight。
2. RemoteHost 主要服务 RDP、RustDesk、SSH，并不承载 Moonlight 的 server UUID、配对证书、应用 profile、RTSP/UDP 端口和流能力。
3. ProtocolAdapter 的 ConnectionConfig 带有通用 username/password，但 Moonlight 的认证是 HTTP 配对证书/PIN，不应被误建模为普通密码。
4. VideoFrame 是单 buffer 模型，Moonlight common-c 的 DECODE_UNIT 是多 LENTRY 链，且 bufferType 可能标识 SPS/PPS/VPS。
5. AudioData 以 PCM 为主要回调形态，但 Moonlight 音频回调需要在本地执行 Opus/Opus multistream 解码。
6. InputHandler 没有 Game Controller Kit、控制器槽位、振动、LED、运动、触摸点和可靠输入 flush 的专用接口。
7. ExtensionLoader 和 decoder/audio pipeline 仍有全局 active 路径；Moonlight 的网络线程、视频线程、音频线程、输入线程和 UI generation 必须成组销毁。
8. `HostProtocolPicker` 当前已在 RDP、RustDesk、SSH、VNC 后展示禁用的 Moonlight 预告项；设置策略仍只有 RDP、RustDesk、SSH、VNC，Moonlight 实施时需要独立设置 section/route owner。
9. 当前 cloud sync 实际注册仍只有 `cryptoparams`、`usersettings`、`remotehosts`、`rdpcredentials`、`rustdeskrelays`、`sshkeys`、`totpentries`、`vncrecordv2`；Moonlight 当前不新增云表、不进入注册清单、不创建 Moonlight 云 coordinator。
10. 当前 `CloudSyncSelectionPolicy` 继续只服务既有协议；Moonlight 不新增物理/逻辑云选择项。Moonlight 只复用本地 owner-store、journal、backup 和 deletion 基础设施，禁止在本任务中顺带重构成熟云同步行为。
11. 当前只有已验证平台云身份能打开 canonical `remotedesktop.db` 并注册云表；未验证账号使用 `remotedesktop_owner-<sha>.db`，设备本地使用 `remotedesktop_device_local.db`，两者始终 local-only。旧计划中“每个账号各自云数据库”的表述已废弃。
12. 当前添加主机 FAB 已显示灰色 Moonlight 入口、“即将支持”和低延迟说明，点击无副作用；预览图标仍是 `sys.symbol.gamecontroller_fill`。正式开放前才替换为经品牌许可/来源确认的官方 Moonlight 资产，并保留系统 Symbol 无障碍/缺失回退。

### 1.5 二次完成性审计矩阵

本次二次审计不是只检查“是否提到某个主题”，而是检查每个主题是否同时具备现状证据、目标合同、实施顺序、失败策略、用户体验和验收门槛：

| 审计面 | 当前代码/官方证据 | 本计划必须形成的可执行结论 |
| --- | --- | --- |
| Moonlight 协议 | common-c、Android 配对/HTTP、Qt 产品能力、Sunshine 服务端 | exact revision、端口/加密/会话阶段、线程关闭顺序、兼容边界 |
| 媒体底层 | 当前 OH_AVCodec、NativeImage/Surface、OHAudio；API 23 SDK 头文件/库 | decode unit 桥、音视频加密、FEC、首帧、IDR、音频焦点、功耗和降级 |
| 输入 | 当前键鼠/触摸路径；API 23 Game Controller Kit | 多输入 owner、全量释放、实体手柄映射、虚拟控制、系统快捷键保护 |
| 生命周期 | 当前 RemoteSessionState、PIP、后台任务、NativeSessionHandles | 前后台、PIP、锁屏、旋转、切网、进程重建、停止和账户切换顺序 |
| 本地数据和账户 | 当前 AccountScopePolicy、AccountSessionCoordinator、SensitiveDataBarrier、owner-store/CloudStore 本地 RDB | 独立本地表、账户隔离、lease/generation、迁移隔离、secret 默认只进安全存储；不依赖 cloud-first |
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
| Moonlight Qt | `2e13ed9977bc31c73caf8428f08f58d793313ece`（2026-08-09 实施复核） | 设置能力、桌面输入、HDR/高阶 codec、产品诊断参考；其 common-c gitlink与本次 pin 一致 |
| Sunshine | `v2026.808.164219` / `25c06d79b54f3d092d3fedd5f5ba44989f394692`（2026-08-09 实施复核） | 现代服务端互操作和测试环境参考；不打包；最低安全基线仍为 `v2026.516.143833` |
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
- `installationId`：本地随机安装 ID，只用于安装级缓存/诊断关联，清除数据或重装后重建；不发送给主机、不写 `moonlightrecordv1`、不直接作为冲突 origin。
- `originId`：每个 owner-store 首次写 Moonlight 数据时独立生成的随机同步 origin，保存在 canonical payload 的 `_meta` 中，只在该 owner 的记录间可关联；同一安装的账号 A、账号 B 和 device-local 使用不同值，不从 installationId、UnionID 或硬件 ID 派生。
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

| 数据 | 默认位置 | 当前云边界 | 处理 |
| --- | --- | --- | --- |
| server UUID、主机名、地址、端口 | 本地加密记录 | 当前仅本地 | 用于发现和主机卡片 |
| 服务器证书指纹 | 本地 trust 记录 | 当前仅本地 | 变更时仍需显示旧/新指纹并重新确认 |
| 客户端证书公钥 | owner-scoped 本地 identity/trust 记录 | 当前仅本地 | 配对前已生成；发送给主机不等于允许跨账户复用 |
| 客户端私钥/配对身份 | owner-scoped 本机安全存储 | 永不进入当前云路径 | 未来跨设备恢复另立项目；当前只允许本机重新配对 |
| PIN | 临时内存 | 永不同步 | 配对失败后立即清理 |
| 访问令牌、HTTP 会话缓存 | 本地短期缓存 | 永不同步 | 过期、切换账号或撤销时清理 |

配对界面必须展示客户端生成的 PIN、清晰说明“请在主机端输入”、等待状态、取消、超时、重试、重置配对和证书变更确认。配对身份属于当前 owner，不能提供会造成半配对的“成功后不保存身份”；可以“只保存未配对主机”。在所有错误文案中区分主机端 PIN 未输入/输入错误、主机已有其他配对事务、证书变更、TCP 可达但 UDP 不通、主机正在运行其他会话。

### 2.4 端到端串流加密和会话密钥合同

除 TLS 控制面和配对信任外，现代 common-c 还定义了流级加密能力。实施不能只写“视频包加密”，而要把协商、密钥、性能和失败策略建模完整：

- `encryptionFlags` 使用 `ENCFLG_NONE`、`ENCFLG_AUDIO`、`ENCFLG_VIDEO`、`ENCFLG_ALL` 表达音视频流加密请求；输入流始终按协议加密。
- launch/resume 生成的 `rikey`/`rikeyid` 是会话级材料，必须与 common-c `remoteInputAesKey`/IV 及主机参数一致；它们只存在于当前 session owner 的安全内存中。
- `rikey`、`rikeyid`、派生 key、IV、认证 tag 不写日志、不进诊断快照、不进本地记录、不进入崩溃上报；停止、失败、账户切换和进程退出时清零。
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
| CloudStore/CloudSyncCoordinator/VncRecordPolicy | 当前只复用本地 RDB、envelope、journal、备份和删除的安全性质；不接 Moonlight CloudSync，不复制 VNC 业务逻辑 |

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
| account/store generation | AccountSessionCoordinator | 当前用户、数据库实例和本地 Moonlight store | ownerScopeId、storeIdentity、storeInstanceId、generation 全部匹配当前 lease |
| Moonlight session generation | MoonlightSessionService/native owner | 当前主机串流、Surface、音频、输入和网络线程 | sessionId、session generation、对应 media/input generation 全部匹配 |

任何 Moonlight 本地持久化、secure-store 操作或 secret 恢复必须先通过账户 lease，再通过 Moonlight session generation；当前不存在 Moonlight 云回调。任意一层过期都静默丢弃结果、递增 stale-callback 诊断计数，且不得重开 mutation gate。

Moonlight 还必须作为 `SensitiveDataBarrier` 的正式参与者：

1. 账户切换/退出开始，关闭 Moonlight 的新建、编辑、配对、secret 恢复和串流启动入口。
2. 停止 PIP/后台/实况窗等所有外部可见会话，并要求终态回执。
3. 停止所有 Moonlight native session，释放输入、音频、视频、控制/RTSP/HTTP 和在途回调。
4. 清零 PIN、`rikey`/`rikeyid`、session token 和解密中间态，撤销当前 secure-store lease。
5. 等 Moonlight local journal/RDB mutation 归零，才能让 Coordinator quiesce 旧 store；不等待、不创建 Moonlight 云任务。
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
| P8 数据和 UI | 加入独立本地主机、应用、设置和本地备份 | Moonlight model/policy/pages、`moonlightlocalrecords`、owner/lease/barrier、迁移隔离、本地冲突、UI/无障碍和功能开关；云表停靠 | P2、P7 的接口稳定；本地 store/备份/删除门具备 | 新/老/多账号/切账号用户完成本地全流程；Moonlight 零云调用；旧协议 UI 无回归 |
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
12. Sunshine 最低安全版本/advisory 结果，以及 `moonlightlocalrecords` 20 列 schema、长度、owner 规则、本地备份/删除和 owner-store 迁移证据；`moonlightrecordv1` 云 schema 与 AGC 审批属于停靠项目，不是本阶段退出条件。
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
- 遵守 `CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED`、`REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED`、`PORTABLE_BACKUP_V3_WRITE_ENABLED`、`LEGACY_CLOUD_REST_TRANSFER_ENABLED` 的当前值和 fail-closed 语义；Moonlight 子开关不得越权打开上层能力。第四次审计时 cloud lifecycle 与 portable backup 已为 true，remote crypto 与 legacy REST 仍为 false。
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

## 7. Moonlight 本地主机存储与可选云同步设计

### 7.0 2026-08-19 当前有效合同：本地事实层常驻、可选第九表增量启用

本节覆盖后面的 2026-08-10 历史停靠文本。实现和发布必须同时满足：

1. 旧版兼容优先。既有八表是不可变 baseline，启动时先单独注册；`moonlightrecordv1` 只能作为后续九表 superset 尝试。第九表缺失、权限错误或 schema 不匹配时，立即把 Moonlight 标记为 runtime unavailable，并重新确认八表 baseline；不得清空 durable selection，不得让旧协议失去拉取能力。
2. 首次安装和老版本升级均不自动选择 Moonlight。物理表与 `settings`、`hosts`、`profiles` 逻辑范围默认 `[]`，只接受用户显式选择；`trust`、`secret`、客户端身份、私钥和证书没有 v1 云能力。
3. 下载兼容优先于整表拒绝。云传输可拉取 Moonlight 表，应用按记录执行 exact shape、业务语义、owner 和版本校验；合法行与脱敏 quarantine 在同一事务提交，坏行、未来版本行和跨 owner 行不能阻断其余 Moonlight 行或既有八表。
4. 手动“以云端为准”仅对完全有效快照执行 selected-scope replacement。快照含隔离行时自动降级为非破坏性 merge：应用合法行、记录 quarantine、保留快照中缺失的本地行，绝不把部分数据解释成远端删除。
5. 上传仍严格。native-first 必须证明 exact 19 列、当前 owner、公共 recordType、当前逻辑选择和 durable mutation journal；未选择范围的干净云镜像可保留，但未授权的本地 mutation 不得借物理整表同步外泄。
6. owner-store v4→v5 只做三张 additive `CREATE TABLE IF NOT EXISTS`；三表必须按顺序验证 `name/type/pk`，完整 fingerprint receipt 可读后才推进版本。失败保持 v4 和全部旧表数据，重启幂等重试，不执行 DROP/DELETE/重建旧表。
7. `MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION=0` 是建表前熔断，不是永久禁用。用户完成目标 AGC 环境建表并确认 19 列合同后，单独提交 revision 1，再进行真实注册、core-eight coexistence、下载/上传/删除/冲突/账号切换/crypto reset 回归。
8. UI、数据层和底层全部实现完成后才进行最终 HDC/截图验收；每次只使用最终新包的新截图。

### 7.0-HISTORY 2026-08-10 范围变更：本地优先、云同步停靠（已被 7.0 覆盖）

本节的当前实施合同已经由产品决策改为 **Moonlight 只做本地主机存储**。此前设计的
`moonlightrecordv1`、Moonlight CloudSyncSelection、MoonlightCloudSyncService、云端
secret 恢复和三套 AGC schema 全部进入 `PARKED_CLOUD`，不是当前版本的交付内容；保留它们
只为了未来重新评审时有可追溯的设计，不得被实现者当作当前 TODO 自动接入。

当前版本的唯一持久化事实层如下：

| 层 | 物理对象 | 当前用途 | 允许写入 | 云边界 |
| --- | --- | --- | --- | --- |
| 本地主机事实 | `moonlightlocalrecords`，20 列 | settings、host、profile、trust 的 owner-scoped envelope；secret 只保存不可恢复元数据 | `MoonlightRepository` → 当前 owner 本地 RDB 事务 | 永不进入 `CLOUD_SYNC_TABLES`、`setDistributedTables`、CloudSyncCoordinator 或云 transfer |
| 本地目录缓存 | `moonlightappcache`，16 列 | Sunshine app catalog、图标 ETag/摘要、过期时间和排序 | `MoonlightAppCacheService`，可丢弃重建 | 永不上传、永不作为业务事实 |
| 本机安全存储 | HUKS/既有安全存储 owner | 客户端私钥、配对身份 alias、必要的本机 trust receipt | 专用 secure identity owner | 永不进入普通 RDB payload、便携备份或云 |
| 运行时内存 | session/HTTP token/PIN/`rikey`/`rikeyid`/媒体状态 | 当前连接和配对短期状态 | 当前 session generation | 停止、取消、切账号和进程退出时清零 |

当前版本的硬性禁止项：

1. 不在 `CloudSyncPolicy.CLOUD_SYNC_TABLES` 增加 `moonlightrecordv1`。
2. 不在 CloudStore 启动时创建或注册 Moonlight 云表；本地 RDB 只创建
   `moonlightlocalrecords` 和 `moonlightappcache`。
3. 不实例化 MoonlightCloudSyncService、MoonlightCloudSyncSelectionStore、
   CloudSensitiveTransferPolicy 的 Moonlight 路径，不新增云同步设置项、云状态 badge 或待上传状态。
4. 不把 Moonlight host/profile/trust/secret 写入 `remotehosts`、`usersettings`、
   `vncrecordv2` 或其他协议表。
5. 不把“本地保存成功”描述成“已同步”；当前 UI 只允许显示“已保存在此设备”。
6. 不因华为账号登录、云空间可用或其他协议云同步成功而自动改变 Moonlight 的本地边界。

#### 7.0.1 本地主机存储的实际写入合同

所有 Moonlight 数据访问必须经过当前 `AccountSessionLease`：

```text
UI/HostService
  → MoonlightRepository / MoonlightAppCacheService
  → AccountSessionLease 校验
  → Moonlight local RDB transaction
  → local mutation journal
  → readback + hash/owner 校验
  → materialized UI snapshot
```

每次读写都要校验 `ownerScopeId + storeIdentity + generation + storeInstanceId`。账号切换、
锁定、退出或数据库实例替换后，旧 lease 的读、写、目录刷新、删除和回调全部返回
`stale_lease`，不能写入新账号的本地主机列表。Repository 的 `cloudAttempted` 必须恒为
`false`；当前实施不提供把 `localonly=1` 改成云投影 `localonly=0` 的产品入口。

#### 7.0.2 本地主机记录类型

仍使用现有独立 `recordType`，但只在本地 envelope 中解释：

| 类型 | owner | 保存内容 | 禁止保存 |
| --- | --- | --- | --- |
| `settings` | 当前本地账号 scope | 用户选择的默认视频/音频/输入/网络设置 | 当前能力探针、会话状态、临时协商结果 |
| `host` | 当前本地账号 scope | server UUID、显示名、地址候选、端口、Sunshine 类型、WOL 偏好、最近成功地址摘要 | PIN、HTTP token、session key、明文私钥 |
| `profile` | host record id | appId、title snapshot、收藏/排序、针对该应用的用户覆盖项 | 完整目录缓存、在线状态、运行中状态 |
| `trust` | host record id | 服务器证书指纹候选、用户确认时间、信任版本和变更提示 | 私钥、PIN、服务器秘密、绕过确认的“已信任”结论 |
| `secret` | 当前本地账号 scope | secure-store alias、证书公钥摘要、身份版本、是否需要重新配对 | 客户端私钥、可恢复 ciphertext、rikey、session token |

`secret` row 只是本地索引；真正私钥仍由现有 secure identity owner 管理。删除 host 时，
先停止使用并撤销关联 identity/trust，再对 host/profile/trust/secret 生成本地 tombstone；
任何删除失败都返回可重试的部分状态，不能假报“已解除配对”。

#### 7.0.3 本地主机生命周期

1. **首次安装**：创建 owner-store schema v5、本地记录表和目录缓存表；不创建 Moonlight 云表。
2. **打开主机列表**：只加载当前 owner 的未删除 host rows；目录缓存按 TTL 显示“已缓存/已过期”，不因缓存过期删除 host。
3. **手动添加/自动发现**：先做格式校验、serverinfo 和可达性检查；只有用户确认保存后才写 host row。
4. **配对**：PIN 只留内存；生成 identity 后先写 secure store，再以最小 metadata 写本地 secret/trust row，失败则回滚临时状态。
5. **目录刷新**：host/profile 先持久化，app catalog 进入 `moonlightappcache`；部分失败保留旧目录并显示过期原因。
6. **编辑设置**：settings/profile 使用 mutationId 和 readback；连续点击、进程重启和重复提交必须幂等。
7. **启动串流**：只读取本地主机快照和当前 session generation；运行时 negotiated settings 不反写用户默认值，除非用户明确保存。
8. **断开/后台/PIP/崩溃恢复**：清运行时状态、保留 host/profile/trust；清理 token/PIN/key，目录缓存仍可下次使用。
9. **账号切换/退出**：关闭 Moonlight mutation gate，等待 native/session/store callback drain，再绑定新 owner；旧 owner 数据不在新账号列表出现。
10. **删除主机**：展示 host、profile、trust、secret 和本地缓存影响；用户确认后事务写 tombstone、清 secure identity、删除 artwork 文件并 readback。
11. **清除应用数据/卸载**：按系统数据清除语义移除本地记录和安全身份；卸载前不承诺可恢复，除非用户已经导出本地备份。

#### 7.0.4 本地备份、导入和恢复

本地主机存储必须接入现有 Local Backup V3，但不改变其他协议云同步：

- 当前备份只增加 `localTables.moonlightlocalrecords`；`moonlightappcache`、journal、
  quarantine、session marker、PIN、HTTP token、私钥和 secure-store alias 均排除。
- 脱敏备份包含 host/profile 的非秘密配置；trust 候选和地址按现有隐私规则处理；完整备份
  首版仍不包含可恢复私钥，恢复后需要重新配对。
- 恢复先进入 quarantine，校验 owner、schema、payload hash、引用和 tombstone，再展示新增、
  覆盖、冲突、忽略和隔离数量；用户确认后在当前 lease 内原子写入本地表。
- 旧备份没有 Moonlight local section 等价于“无 Moonlight 数据”；新备份被旧客户端拒绝时
  必须明确提示版本过新，禁止静默丢失主机。
- 本地备份恢复不执行任何云 bootstrap、云合并、上传或云 tombstone；恢复后的所有记录仍是
  `localonly=1`，UI 统一显示“已恢复到此设备”。

#### 7.0.5 云同步停靠区的重新启动条件

未来重新评估 Moonlight 云同步时，必须新建独立任务，不得在当前 N2/S1 任务中顺手打开。
重新启动前至少要有：现有 CloudStore 问题关闭记录、dev/test/prod schema/auth/index receipt、
跨账号物理隔离证明、secret E2E 设计与恢复演练、空快照/冲突/tombstone 测试、用户明确选择
和隐私文案。届时先做只读 schema/adapter 探针，再做独立 feature flag 和迁移设计；当前版本
不为这些未来条件预留可点击 UI。

### 7.1 [ACTIVE_AFTER_PROVISIONING] 可选云表物理边界

以下 7.1～7.11 的数据结构、冲突和生命周期设计重新进入当前实施路径；如果其中仍残留
“未来”“停靠”或“当前不执行”措辞，以 2026-08-19 第 7.0 节为准。客户端在 revision 0
阶段只创建本地 RDB 表和验证 receipt，不调用未知 AGC 表；用户确认云端精确结构后才启用
revision 1 的可选注册和传输。

未来重新启动云同步项目时，才考虑一张独立云端业务表；当前版本不创建、不注册、不上传：

- 未来云端物理表：`moonlightrecordv1`；仅作为未来 AGC/分布式方案草案。
- 当前本地主机事实层：`moonlightlocalrecords`；位于当前 owner 的物理数据库，永不调用 `setDistributedTables()`。
- 当前本地应用缓存：`moonlightappcache`；只缓存主机返回的应用目录、封面 ETag/摘要和过期时间，不进云、不进当前便携备份。

`moonlightlocalrecords` 是当前唯一 Moonlight 业务事实层：所有合法写入都在这里形成 owner-scoped 可恢复状态，当前没有向云端投影的步骤。journal、quarantine、bootstrap marker、selection、恢复 receipt 和 session recovery marker 仍用各自现有基础设施，不塞进业务 row。不得另建 `moonlightsettings`、`moonlighthosts`、`moonlightapps`、`moonlighttrust` 或 `moonlightsecrets` 表。

版本后缀是物理 schema 合同的一部分：首版直接命名 `moonlightrecordv1`，未来不在生产中原地改变列语义；若确需不兼容物理结构，另立 `moonlightrecordv2` 迁移项目。`CloudSyncPolicy` 只增加 `moonlightrecordv1`，所有逻辑记录由 `recordtype` 区分。不得写入当前 `remotehosts`、`usersettings`、`vncrecordv2` 或任一其他协议表。

AGC 上线顺序是硬门禁：开发/测试/生产三个目标环境先创建并验证表、权限、索引和空表读写，再合入包含该表名的客户端。因为当前 `setDistributedTables(TABLES, DISTRIBUTED_CLOUD, false)` 按完整清单注册，不能假设缺少一个新表时其余表仍必然成功；在 API 23 未证明安全的“可选单表重复注册”能力前，不用运行时开关掩盖未部署 schema。

### 7.2 表结构

第四次审计后取消旧版“22 列 Moonlight 特例”。当前 `CloudStore`、`CloudTableAdapter`、VNC validator、备份 inventory 和冲突裁决已经围绕成熟的 19 列 envelope 工作；额外物理列会扩大公共云基础设施改造并制造第二套并发模型。`moonlightrecordv1` 固定复用同样的 19 个物理列，并把 Moonlight 专属的 `baseSyncVersion`、`mutationId`、`originId`、`fieldVersions` 放入 canonical payload 的 `_meta` 对象。它们受 `payloadhashsha256` 覆盖，secret row 也只在非敏感元数据 payload 中携带，不成为明文身份材料。

云端/分布式表的规范 DDL 形状如下；实际建表由项目既有 CloudStore/云控制台迁移通道执行，不允许客户端在生产环境临时建云表：

~~~sql
CREATE TABLE moonlightrecordv1 (
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
| ownertype | `account`、`host`、`profile` 或 tombstone 的空字符串之一，最多 16 字符；不使用含糊的 `user/device` |
| secretkind | 空字符串或 `client_identity`，最多 32 字符；trust 不是 secretKind，PIN/session token/rikey 永不成为云记录 |
| payload | UTF-8 RFC 8785 canonical JSON，最多 64 KiB；包含业务对象和 `_meta`，secret 只放不可恢复的 envelope 元数据 |
| ciphertext | 端到端加密 envelope，最多 128 KiB；非 secret 为空字符串 |
| envelopeversion/cryptoversion/keyversion/aadversion | 非负整数；不支持的较新版本隔离 |
| payloadhashsha256 | 按第 7.4 节逐 recordType 字节合同计算的 SHA-256，小写 64 位十六进制；历史列名不代表 secret 只 hash payload |
| syncversion | 当前记录逻辑版本，非负整数；新 mutation 通常为观察版本 + 1；同当前 VNC 冲突策略由 `resetepoch > syncversion > updatedat > id` 形成 row 级确定序 |
| schemaversion/resetepoch | 非负整数；resetepoch 只在明确重置/复活操作递增 |
| createdat/updatedat | Unix epoch milliseconds 非负整数；服务端规范化时间优先，本机时间不单独决定胜负 |
| deletedat | `0` 表示存活，正整数表示 tombstone 时间；全链路禁止一处用 null、一处用 0 |
| localonly | 仅本地 mirror 使用，`0/1`；为 1 的记录不会被云 adapter 枚举 |

云服务为兼容性可能不支持列级 NOT NULL/CHECK，因此“DDL 可空”不代表业务可空。写入、拉取、恢复、迁移四条路径都必须运行同一个 validator；字段缺失、越界、非法枚举、负数、hash 格式错误或 live/tombstone 语义冲突全部隔离，不用默认值悄悄修复。单行总体积、云端列类型、索引数和 TEXT 上限必须在 P0 云环境实测，若平台上限更小，只能收紧本计划上限，不能拆成第二张云表规避。

初始迁移标识定为 `moonlightrecordv1_schema_19col_v1`，业务 row 的 `schemaversion=1`。云数据库控制台、ArkTS row model、`CloudTableAdapter`、validator、本地覆盖层和备份清单必须逐列一致；必须有自动测试比较列名集合、类型和默认归一化。任何遗留 22 列实验数据都只能由独立迁移器读取并隔离，不能与正式 v1 混写。

所有 live payload 都必须带如下 `_meta`；它是业务 JSON 的保留键，用户设置模型不能覆盖：

~~~json
{
  "_meta": {
    "mutationId": "random-id-reused-for-retry",
    "originId": "owner-store-random-id",
    "baseSyncVersion": 0,
    "fieldVersions": {}
  }
}
~~~

`originId` 是 owner-store 内随机值，不得取 OAID、UDID、序列号、UnionID 或硬件信息。账号再次绑定同一 canonical store 时复用；清除此 owner 数据、创建新的 local-only store 或重装后重新生成。便携备份保留历史 row 自带的 `_meta` 以便冲突审计，但不把当前设备 writer origin 单独导出为设备配置；导入后的下一次用户写入使用目标 owner-store 的新 origin。tombstone payload 固定 `{}`，不携带 `_meta`，幂等和排序只依赖 19 列 envelope。

严格 owner 矩阵如下，任何不匹配都进 quarantine：

| recordType | ownerType | ownerId | secretKind |
| --- | --- | --- | --- |
| settings | `account` | 当前 `userid` | 空 |
| host | `account` | 当前 `userid` | 空 |
| profile | `host` | 被引用的 host record id | 空 |
| trust | `host` | 被引用的 host record id | 空 |
| secret | `account` | 当前 `userid` | `client_identity` |

### 7.3 recordType 规范

以下示例为可读性省略统一 `_meta`；实际 live row 必须由 `MoonlightRecordPolicy` 在 canonicalization 前注入第 7.2 节元数据。业务 DTO、UI 表单和导入文件不得直接设置 `_meta`。

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

全局设置只存跨主机默认值。设备能力探测结果、最近自适应码率、当前音量、物理手柄编号、窗口尺寸和 diagnostics HUD 状态属于本机/会话状态，不同步。`allowLegacySha1` 初始和升级默认始终为 false，只有明确兼容流程才临时作用于指定 host，不能靠云全局开启。

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
  "lastSuccessfulAddressKey": "",
  "userOrder": 0
}
~~~

`lastSeenAt`、实时在线状态、往返时延、主机能力、运行中的 app、目录版本和探测到的端口放 `moonlightappcache`/内存快照，不制造高频云写。`paired` 也不是 host row 的权威字段：是否可用必须由当前 owner 的 client identity、trust 候选、本机确认和一次 server validation 共同推导。

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
  "favorite": true,
  "userOrder": 0
}
~~~

最近使用时间、封面路径、主机返回标题和当前运行状态仅本地缓存；只有用户编辑的收藏、排序和覆盖项进入 profile。host 删除会 tombstone 从属 profile，删除 profile 不向 Sunshine 发送“删除应用”。

#### trust

保存可公开展示但不可静默替换的信任材料：

~~~json
{
  "schemaVersion": 1,
  "hostId": "host-record-id",
  "serverCertificateSha256": "hex-or-base64-fingerprint",
  "pairingGeneration": 7,
  "candidateObservedAt": 0
}
~~~

云端 trust 只能是“待验证候选”，不能保存 `trusted=true` 之类会让另一设备静默信任的结论。本机确认 receipt 必须与 secure-store owner、当前 `AccountSessionLease`、server UUID 和证书指纹绑定，留在本机且不进云/便携备份。证书指纹改变一律进入 `TRUST_CONFLICT`，阻止连接并展示旧/新短指纹与重新配对动作。

#### secret

首个发布版本保留 `secret/client_identity` schema 和 UI 说明，但逻辑 scope 默认关闭，且在 `REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED`、威胁模型、跨设备恢复和吊销测试全部通过前不可打开。默认配对身份只进入 HUKS/Asset Store 支持的本机安全存储，cloud/local row 仅保存不可用于取出其他 owner 私钥的 alias/版本元数据；PIN、明文私钥、session token、`rikey`/`rikeyid` 永不持久化。未来用户显式开启身份同步时，私钥与客户端证书只能进入 DataCrypto authenticated ciphertext。

### 7.4 加密、AAD 和同步规则

Moonlight 应复用项目现有 DataCrypto/CloudStore envelope，但不能把 VNC 的 owner、secretKind 或 payload 直接当作 Moonlight 语义。每条记录的 AAD 至少包括：

- cloud table name，固定 `moonlightrecordv1`；
- recordType；
- id；
- ownerId；
- schemaVersion；
- envelopeVersion；
- cryptoVersion；
- keyVersion；
- aadVersion；
- resetEpoch；
- syncVersion；`_meta` 已在 canonical payload/hash 中受完整性检查，不作为不存在的物理列重复编码；
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
3. secret：私钥材料只写 ciphertext；payload 仅含 identity 版本、证书摘要、随机 origin 和恢复状态，不放可跨 owner 取出本机 key 的裸 alias，更不含硬件设备 ID。
4. 禁止把任何密码、PIN、私钥、access token、调试抓包数据写入普通 payload。
5. 密钥轮换只改变 keyVersion/cryptoVersion，不改变 record ID；迁移失败时保留旧 ciphertext 并标记待迁移。
6. 用户关闭 secret sync 时，先停止新 secret 上传，再按当前云数据删除/撤销策略生成 tombstone，不直接删除本地仍在使用的私钥。

#### 并发写入和确定性合并

每个 writer 读取记录时把 `observed.syncversion` 写入 `_meta.baseSyncVersion`，一次用户 mutation 生成新的 `_meta.mutationId` 并使用当前 owner-store `_meta.originId`；网络重试必须复用完整 canonical row。同一 mutationId 出现不同 payload/hash 视为数据损坏而隔离。相同 id、相同 baseSyncVersion、不同 mutationId 且业务 payload 不同，标记为并发分支；`_meta` 用于检测和解释冲突，但不改变公共 19 列 adapter。

确定性总序只用于需要选出可继续同步的 canonical row，优先级固定为：

1. `resetepoch` 较大；
2. `syncversion` 较大；
3. 规范化 `updatedat` 较大；
4. 仍相等时，只有内容完全相同才视为幂等；内容不同则隔离，不用客户端时间或 mutationId 随意吞掉安全冲突。

当前 VNC 通用 row 排序含 `id` 作为最后稳定键；对同一个 Moonlight id 它不提供额外裁决，因此 envelope 三项相同而内容不同属于 invariant violation，双方都隔离并阻断上传。真正完成三方合并后必须生成新 mutation 和更高 `syncversion`，不能原样回写某一分支伪装成已合并。

recordType 合并合同：

| recordType | 并发处理 |
| --- | --- |
| settings | `_meta.fieldVersions` 只覆盖稳定设置 key；不重叠路径可三方合并，同一字段并发冲突按 envelope canonical row 选择并在同步详情保留未采用提示 |
| host | 地址集合可按规范化地址 key 合并；displayName/lastSeen 等低风险字段按 field version；serverUuid、host identity、证书关联冲突必须阻断并重新验证，不能把两个主机拼接 |
| profile | 不重叠的 stream/input override key 可三方合并；同一 key 按总序；appId/hostId 并发变化进入用户选择，禁止启动含糊 profile |
| trust | 相同 server certificate fingerprint 可合并更新时间；不同 fingerprint 永不自动选择，标记 `TRUST_CONFLICT` 并要求重新验证/配对 |
| secret | 第 7.4 节 `moonlight-secret-v1` canonical hash 相同可幂等合并；不同有效 secret 永不自动恢复或覆盖，隔离双方并要求用户选择来源或重新配对 |

tombstone 通过更高 `resetepoch`/`syncversion` 阻止离线旧设备把已删对象复活。复活只能由用户明确执行并创建更高 `resetepoch` 的 live row，再经过 owner、trust/secret 和云授权确认。客户端墙上时钟不参与安全决策；离线并发、时钟回拨、重试乱序和 tombstone race 都必须进入双设备测试。

### 7.5 云同步生命周期

| 时点 | 行为 |
| --- | --- |
| 登录/打开云同步 | 仅在 verified platform cloud binding 下从 canonical `remotedesktop.db` 拉取 `moonlightrecordv1`，验证 envelope/hash，物化到本地覆盖层 |
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

`userid` 不能只当作一列过滤条件；Moonlight 数据的物理数据库、内存 cache、journal、selection 和 callback 都必须绑定当前 `AccountSessionLease`（`ownerScopeId + storeIdentity + generation + storeInstanceId`）：

- 已验证平台云身份：由已验证 UnionID 的不可逆 SHA-256 派生 `ownerScopeId`，并且只有 canonical `remotedesktop.db` 能注册/打开分布式表。
- 尚未验证或不具备平台云身份的账号：使用 `remotedesktop_owner-<sha>.db`，即使 UI 中已登录也只能 local-only，不注册云表。
- 设备本地作用域：使用 `remotedesktop_device_local.db`，不得伪造云账号 userid，始终 local-only。
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

第四次审计时 `CloudLifecycleSafetyPolicy` 的 cloud lifecycle v2 与 portable backup v3 已启用，remote crypto lifecycle v2 与 legacy REST transfer 仍关闭。Moonlight 不得硬编码假设这些值永远不变，也不得借普通分布式表绕过远端加密总门；P8 的退出条件必须覆盖 enabled/disabled 两套测试，任何门关闭时都零 secret 上传、零跨 owner 恢复。

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

普通云同步选择器只暴露一个物理项“Moonlight（主机、配置与设置）”，对应 `moonlightrecordv1`；不要在用户主文案里泄漏版本化物理名，详情/诊断才显示。表级选择之外，新建 owner-scoped `MoonlightCloudSyncSelectionStore` 和纯策略，逻辑 scope 固定为 `settings | hosts | profiles | trust | identity`。这套 wiring 可借鉴 VNC，但不得复用 `RemoteDesktopVncPrefs`、VNC key、VNC record-type mapper 或 VNC coordinator 状态。

当前 [CloudSyncSelectionPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncSelectionPolicy.ets) 新安装默认空数组，当前 VNC 逻辑 scope 默认也为空。Moonlight 两层选择默认都必须为空；用户勾选物理项时进入 Moonlight 范围确认页，由用户明确选择非敏感范围，不得自动填充并立即上传。有效上传条件为：verified canonical store + 物理表已选择 + 对应逻辑 scope 已选择 + cloud-first/bootstrap 完成 + 当前 lease 有效 + row validator 通过。

| recordType | 逻辑 scope | 默认 | 开启后的行为 | 关闭/删除行为 |
| --- | --- | --- | --- |
| settings | `settings` | 关闭 | 同步用户明确设置，不同步能力/会话态 | 只停投影；不删除本地 row，不写云 tombstone |
| host | `hosts` | 关闭 | 同步主机定义，不同步在线态/配对结论 | 删除动作另行确认，host tombstone 前预览 profile/trust 影响 |
| profile | `profiles` | 关闭 | 同步收藏和用户覆盖项，不同步目录缓存 | 保留本地 app cache，不删除 Sunshine 应用 |
| trust | `trust` | 关闭 | 只同步证书候选摘要，新设备仍需本地确认 | 停同步不撤销本地确认；“删除云候选”单独写 tombstone |
| secret | `identity` | 关闭且首版 capability 不可用 | 仅在 remote crypto lifecycle、E2E 和恢复评审通过后允许显式开启 | 先停恢复/上传；云 tombstone、本机身份删除、主机 unpair 三个独立确认 |

`MoonlightRepository.upsert()` 始终先写当前 owner 的 local overlay；只有上述有效条件满足才写云投影。取消物理或逻辑选择只停止后续投影，绝不把“取消同步”解释为“删除云数据”。重新开启必须先 cloud-first 拉取并解决冲突，再将仅本地候选提升到云；禁止 local-first 覆盖另一设备。删除云数据、删除当前设备数据、删除/忘记主机、从 Sunshine 解除配对、删除 profile 是不同命令和确认页。

### 7.10 单表容量、索引、留存和服务端安全

- `id` 是唯一物理主键；owner/recordType 是必须校验的业务隔离维度，不宣称 RDB 中存在并未定义的 `owner + id` 复合主键。
- 目标二级索引候选为 `(userid, recordtype, deletedat)`、`(ownerid, recordtype)`、`(updatedat)`；P0 必须在 AGC API 23 对应环境验证是否支持联合索引、排序和分布式表限制，只有控制台实际创建/查询证据后才称为“已建立”。若平台不支持，记录替代查询、分页成本和行数上限，不得静默全表扫描。
- `payload`/`ciphertext` 设置明确长度上限；应用图标、日志、媒体包、性能时间序列不进入表，避免单行/总容量失控。
- app catalog 仅本地缓存并设过期时间；profile 只存 titleSnapshot 和 appId。
- tombstone 有最短跨设备传播窗口，清理必须确认所有 active device generation 已观察到或达到服务端留存策略；不能本地删除后立即物理清除云行。
- 服务端规则按已认证用户限制 `userid`，客户端仍做 owner/envelope/hash 校验；任何客户端字段都不能替代服务端授权。
- 设置和非敏感记录也遵守数据最小化；IP/域名、MAC/WOL、主机名可能构成个人网络信息，应在隐私说明、导出和诊断中脱敏。
- 给用户提供账户级“删除所有 Moonlight 云数据”流程：先阻止新写、生成/确认删除集、等待云终态、清理本地 bootstrap/selection，失败时可重试且不谎报完成。

### 7.11 [ACTIVE_AFTER_PROVISIONING] 便携备份、导出和恢复

第四次审计时 `LOCAL_BACKUP_VERSION=3` 且 `PORTABLE_BACKUP_V3_WRITE_ENABLED=true`，当前备份 manifest 以表 inventory 承载内容。当前本地-only 版本只登记 `moonlightlocalrecords`；`moonlightrecordv1` 的云 section、`moonlightappcache`、journal、quarantine、receipt、bootstrap、selection 和 recovery marker 明确排除。以下涉及云表的内容仅作为未来恢复兼容参考。

格式决策：保持 `LOCAL_BACKUP_VERSION=3`，把两张本地 RDB 表作为新的可选 inventory section；原因是当前 V3 已是 table-driven envelope，无需只为新增协议改变公共格式。实施前必须添加兼容测试证明：旧 V3 文件在新版本恢复时 Moonlight section 缺失等价于“无 Moonlight 数据”；带 Moonlight section 的新文件若被旧客户端拒绝，应明确提示“备份来自较新版本”，不能部分导入。若测试发现旧 reader 会静默丢弃未知 section，则停止并升级为 Backup V4，不能带风险发布。

备份内容矩阵：

| 内容 | 脱敏备份 | 完整备份（首版） | 恢复规则 |
| --- | --- | --- | --- |
| settings/host/profile | 包含 | 包含 | 经过 owner、schema、引用和 hash 校验；来源 local/cloud 去重后只保留 canonical row |
| trust 候选摘要 | 排除 | 包含 | 恢复后仍为候选，不生成本机确认 receipt，不可绕过证书警告 |
| secret/client identity | 排除 | **仍排除** | manifest 明示“Moonlight 配对身份未备份”；恢复后要求重新配对 |
| `moonlightlocalrecords` | 按上面 recordType 过滤后包含 | 按上面 recordType 过滤后包含 | 这是 local-only 用户的主要数据来源，不当作可重建 cache 丢弃 |
| app catalog/封面、在线态、诊断、session marker | 排除 | 排除 | 启动后重新获取；不伪造旧运行状态 |
| PIN、rikey/rikeyid、HTTP/session token、私钥 alias/本机确认 receipt | 排除 | 排除 | 无恢复通道，日志/manifest 也不得出现 |

manifest 记录 App/备份/Moonlight schema 版本、两个表 section、各 recordType 的 included/omitted/count、canonical 内容 hash、来源 owner kind 和不可逆短标识；不保存原始 UnionID、硬件 ID、installationId 或当前 writer origin。导出预览明确显示“主机与配置 N 条、信任候选 N 条、配对身份 0 条（不备份）”。文件生成、hash 自校验和系统分享目标接管是三个状态，取消分享不谎报“备份失败”。

“带配对身份的加密备份”是未来独立功能，不借普通备份夹带 secret。它必须另行通过端到端 KDF/密钥托管、恢复身份确认、吊销、HUKS wrapping 可移植性和威胁模型评审；未通过时唯一跨设备路径是恢复 host/profile 后重新配对。

恢复必须由 `AccountSessionCoordinator` 串行执行：

1. 解析到 restore quarantine，不接触当前 live 表；
2. 验证 manifest/hash、版本、所有 row validator、owner kind、AAD 和引用完整性；
3. 显示新增/覆盖/冲突/忽略/隔离计数，用户确认目标 owner；
4. 对同 id 使用第 7.4 节 19 列 envelope + `_meta` 合同，host identity/trust 冲突阻断；不按导入文件创建时间覆盖；
5. 当前 Moonlight 本地恢复不执行 cloud-first/bootstrap、上传或云 tombstone；未来云版本若重新立项，需另行增加恢复门禁；
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

第四次审计确认，现代“添加主机”FAB 的 `HostProtocolPicker` 已经在 VNC 后展示 `Moonlight`：整项灰色禁用、带“即将支持”和低延迟串流副标题，点击路径因 `enabled=false` 不触发 `onSelect`。当前 `ProtocolIconPolicy` 仍返回 `sys.symbol.gamecontroller_fill`，这是占位回退，不是官方品牌资产。后续只在 P0 完成品牌/许可证/来源复核后替换图标 owner；在 P0-P8 门禁全部通过前保持禁用，不创建草稿、不打开路由、不写设置/数据库/云表。

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
| 云 | 同步 host/profile/settings | 物理表和五个逻辑 scope 均关闭 | 用户显式选择 `moonlightrecordv1` 及对应逻辑范围、verified canonical store ready、cloud-first 和生命周期总门全部通过后才生效 |
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
- 正式协议身份图标使用 Moonlight 官方仓库/发行物实际发布的品牌图形，不使用通用游戏手柄、月亮、显示器或第三方重绘替代。已审计 Moonlight Qt revision `546cb72e32e5ac04bbc7e0b3a254176e5696685a` 的 [`app/res/moonlight.svg`](https://github.com/moonlight-stream/moonlight-qt/blob/546cb72e32e5ac04bbc7e0b3a254176e5696685a/app/res/moonlight.svg) 只作为来源证据；P0 必须重新从当日官方 commit 取资产、记录 commit/path/SHA-256/许可证与品牌使用结论，不能盲用旧 pin。
- 官方图形应作为本地资源随 HAP 打包，禁止运行时热链 GitHub/CDN，也禁止从搜索引擎、图标站或第三方 fork 下载。若 HarmonyOS 资源管线需要把 SVG 转为 PNG/WebP，必须保留原始 256×256 viewBox、圆形边界、白色内圆和八向放射图形的比例与留白，只做确定性的格式/尺寸转换，不重绘、不裁切、不改变品牌构图；原始上游文件、转换脚本/参数和输出 SHA-256 一并留档。
- 官方图标由 `Image`/项目品牌资源策略渲染。实施时把 `ProtocolIconPolicy` 扩展为显式 `systemSymbol | brandedAsset` 描述器，保留现有协议调用的兼容 wrapper；不得让各页面硬编码路径。Host picker、主机卡片、详情页、设置页和诊断页消费同一个 owner，资产加载失败才回退当前 `gamecontroller_fill` 并保持可访问名称。
- 禁用占位态通过整行 opacity 和项目语义色实现，不修改官方素材文件来制作“灰色版”；浅色、深色、accent、减少透明度和高对比度下都要验证图标边界清楚。图标提供 `accessibilityText="Moonlight"`，不可用状态另行播报“即将支持”，不能把品牌图形本身当作唯一状态信息。
- 主机卡片沿用 `HostListPage` 的 card palette、边框/blur、约 14vp 圆角和 66/80vp 紧凑/常规高度；Moonlight 的在线、配对、同步信息通过现有 secondary/tertiary 文本和状态 badge 表达。
- 空间不足时先隐藏诊断摘要和最近 codec，不隐藏主机名、配对警告、主动作和可访问名称。

### 8.8 导航、sheet 和设置路由

当前 `HostListPage` 已把 Sheet 所有权分成明确边界：现代添加 FAB 的协议/添加流使用一个 mounted add Sheet；设置使用一个 root panel 加一个 leaf Sheet router；连接前置使用独立 remote-host/preflight Sheet 和队列。Moonlight 必须接入这三条既有链，不能再创建第四个长期 mounted root Sheet：

1. `sm` 使用带 drag bar 的底部 sheet；`md/lg/xl` 使用居中 sheet；mask 和 dismiss 行为保持当前实现。
2. 不在 Moonlight sheet 内再弹第二个 `bindSheet`；“保存并打开/连接”复用 `HostAddConnectionHandoffPolicy` 的 `onDisappear` 生命周期边界，不能靠固定 360ms 定时器猜测动画完成。应用目录等长流程进入 Navigation 页面；启动确认进入既有 preflight owner/队列。
3. PIN、证书变更、secret 云同步和删除属于不能误触关闭的事务页：支持系统返回，但有未提交敏感状态时使用 dirty-dismiss 确认。
4. `SettingsAccordionPolicy` 中 Moonlight 作为独立协议分组放在 VNC 之后，保持 RDP → RustDesk → SSH → VNC → Moonlight 的既有认知顺序。
5. 第四次审计时 `SettingsSheetRoutePolicy` 已使用 VNC 12–22、Terminal line spacing 23。实施时先新增 route contract test，再从当时最大 mode + 1 起为 Moonlight 分配连续常量；不得复用 12–23、不得在页面散落数字、不得以多个布尔值组合路由。
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

### 8.14 第四次源码对齐后的完备页面与人因设计合同

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
8. **Moonlight 直接沿用 RustDesk 视觉语法**：FAB 打开、协议选择、单 Sheet owner、返回/关闭、步骤标题、模式卡、输入框、主按钮和错误提示都以现有 `HostProtocolPicker` + `RustDeskAddFlow` 为唯一 UI/交互基线；Moonlight 只替换协议文案、官方图标和业务步骤，不以 VNC 页面作为设计或抽取来源，也不重构 RustDesk 业务状态。设置沿用 HostListPage accordion + leaf Sheet；连接内沿用 RustDesk 自动收起顶栏、RemoteModifierPanel 和 DiagnosticsHud 的交互语法，颜色统一走 Theme token。
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

整体外观直接复用 RustDesk 添加流程的设计合同：由现有 `HostListPage.showAddSheet` 单 owner 挂载，手机保持 `SheetType.BOTTOM`、其他断点保持 `CENTER`；20vp 横向留白、36vp 圆形返回、20vp 标题、12vp 步骤说明、12–16vp 圆角模式卡/输入框和 44vp 主按钮均与 `RustDeskAddFlow` 对齐。Moonlight header 显示官方可着色图标、标题以及“n/4 + 步骤名”，业务仍为四步，但不复制或改写 RustDesk relay/TOTP/保存状态。长内容在同一 Sheet 内滚动，软键盘和 footer 遵循现有 RustDesk add Sheet 的避让与关闭生命周期。退出时若已有手输地址、已选主机或已生成临时 identity，弹出“继续添加 / 丢弃草稿”，扫描结果本身不算脏数据。

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

Settings accordion 在 VNC 后加入 Moonlight，摘要为“串流、音频、输入、网络、安全和后台”。展开后的卡片、`protocolActionRow`、留白、圆角、标题层级和 Sheet 生命周期直接沿用 RustDesk 设置分组的视觉/交互语法；数据和路由仍由 Moonlight 独立 owner 持有，包含以下叶页：

1. **快速设置**：体验预设、有效配置摘要、恢复推荐值。
2. **视频与画面**：分辨率、帧率、码率、codec、HDR、色彩、帧节奏和缩放。
3. **音频**：启用、声道、主机同时播放、音量和焦点行为。
4. **输入与控制器**：触控/触控板/鼠标、键盘捕获、控制器、虚拟控制和反馈。
5. **网络与安全**：地址策略、计费网络、重连、加密、legacy 兼容和 Wake-on-LAN。
6. **后台与画中画**：PIP、后台音频、锁屏/无 Surface 行为。
7. **性能监视与诊断**：HUD、采样、日志和脱敏导出。
8. **Moonlight 云同步范围**：唯一 `moonlightrecordv1` 的 settings/hosts/profiles/trust/identity 五个逻辑 scope；所有 scope 默认关闭，identity 首版保持不可用。
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

Moonlight 操控模式中的实体与虚拟手柄都不得在 ArkTS 编码或直发协议。实体手柄事件由 native
GameController listener 进入 N3-05；虚拟控件在后续 UI 阶段只通过窄 typed NAPI 提交语义状态，
由 native 聚合为 button/stick/trigger/dpad full-state，再统一经过 N3-05 mapper、N3-01 bridge 和
official common-c port。两类 source 使用独立 generation；source 切换、编辑态、退出和后台必须先
经 N3-07 neutral，禁止双 owner、双 slot 写入或按下状态跨 source 泄漏。

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
| `HostAddWizardSheet` + `MoonlightHostAddFlow` | 复用 RustDesk 同款单 Sheet 路由与视觉语法；Moonlight owner 只负责四步草稿、异步 generation、保存/打开 | `HostProtocolPicker`/`RustDeskAddFlow` 的 FAB、header、卡片、字段、按钮和返回合同；不复制 RustDesk relay/TOTP 业务状态 |
| `MoonlightHostDetailPage` | 主机摘要、状态、目录 owner 和详情动作 | HostCard/HostList 响应式布局 |
| `MoonlightAppCatalog` | 搜索/筛选/封面/缓存/更多菜单 | MoonlightOH app grid 的任务模型，不复制视觉代码 |
| `MoonlightLaunchSheet` | 有效配置、计费网络、主机忙、开始串流 | 进入现有 remote-host/preflight Sheet owner 与队列，不新挂 root bindSheet |
| `MoonlightConnectStageOverlay` | 阶段进度、取消、降级和失败恢复 | RemoteSessionState + 非模态事务卡 |
| `MoonlightSessionToolbar` | 最多 5/7 项快捷控制、收起、固定 | RustDesk 会话顶栏的自动收起/固定语法 + protocol-neutral `RemoteSessionTopBar` 能力 |
| `MoonlightControlCenter` | 六组本次设置和保存 profile | RemoteDesktop control panel + settings leaf components |
| `MoonlightDiagnosticsHud` | 简洁 chip、详细 dock、拖动/吸附 | RustDesk 诊断浮层的层级/动效语法 + protocol-neutral diagnostics primitives；新增 Moonlight 指标 |
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
  opt 用户已显式选择 moonlightrecordv1 及对应逻辑 scope 且云总门通过
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
- 发布文档说明云端 `moonlightrecordv1` 不会因卸载自动消失；
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
- 19 列 envelope、payload `_meta.baseSyncVersion/mutationId/originId/fieldVersions`、resetEpoch 总序、field-level 三方合并、时钟回拨、并发 tombstone/显式复活、trust/secret 冲突阻断；
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
- [ ] Moonlight 只使用 `moonlightrecordv1` 一张云业务表，`moonlightlocalrecords` 与 `moonlightappcache` 不注册成云表，identity 默认不上云。
- [ ] 新安装物理表与五个逻辑 scope 均默认未选择；19 列 schema/DDL、长度、索引实测、payload `_meta` 和 `id` 单主键与实现一致。
- [ ] cloud-first bootstrap、可疑空快照、阻断重试、tombstone、malformed/legacy quarantine 和删除终态均有双设备证据。
- [ ] device-local↔账号、账号 A↔B、退出保留/清除、静默登录、重装恢复均不跨 owner；旧 lease/callback 无法写新 store。
- [ ] 账户切换时 SensitiveDataBarrier 能停止 Moonlight PIP/后台/native/输入/媒体/secret restore 并清零会话密钥；失败时切换 fail closed。
- [ ] 两台设备同时编辑 host/profile/settings 可按 19 列 envelope 与 `_meta.fieldVersions/baseSyncVersion` 合同合并；trust/identity 冲突不静默覆盖，tombstone 不被旧离线写复活。
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

- [AGENTS.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/AGENTS.md)
- [DECISIONS.md](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/docs/codex/DECISIONS.md)
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
- [RemoteSessionCapabilityPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets)
- [RemoteSessionTopBar.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/RemoteSessionTopBar.ets)
- [VncSessionToolbar.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/VncSessionToolbar.ets)
- [RemoteModifierPanel.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/RemoteModifierPanel.ets)
- [RemoteShortcutSurface.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/RemoteShortcutSurface.ets)
- [Theme.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/common/Theme.ets)
- [BreakpointUtil.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/utils/BreakpointUtil.ets)
- [HostProtocolPicker.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/hostadd/HostProtocolPicker.ets)
- [HostAddConnectionHandoffPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/HostAddConnectionHandoffPolicy.ets)
- [HostAddWizardSheet.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/hostadd/HostAddWizardSheet.ets)
- [RustDeskAddFlow.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets)
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
- [CloudTableAdapter.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudTableAdapter.ets)
- [CloudSensitiveTransferPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSensitiveTransferPolicy.ets)
- [CloudSyncCoordinator.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncCoordinator.ets)
- [CloudSyncCoordinatorPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets)
- [CloudSyncLifecyclePolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/CloudSyncLifecyclePolicy.ets)
- [LegacySharedStoreMigrationPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LegacySharedStoreMigrationPolicy.ets)
- [LocalBackupPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LocalBackupPolicy.ets)
- [LocalBackupService.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/LocalBackupService.ets)
- [BackupManifestV3.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/BackupManifestV3.ets)
- [VncRecord.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/model/VncRecord.ets)
- [VncRecordPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/VncRecordPolicy.ets)
- [VncCloudSyncSelectionPolicy.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/VncCloudSyncSelectionPolicy.ets)
- [VncCloudSyncSelectionStore.ets](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/ets/services/VncCloudSyncSelectionStore.ets)
- [CMakeLists.txt](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/cpp/CMakeLists.txt)
- [module.json5](/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS/entry/src/main/module.json5)

### 14.5 实施开始前的最终确认

真正开始编码前，负责人必须在计划 issue 或 ADR 中补齐：

1. common-c 和 ENet exact revision；
2. API23 probe 结果和真实设备清单；
3. Sunshine/legacy 主机支持边界；
4. client identity 本地安全存储 API；
5. `moonlightrecordv1` 19 列云端 schema migration 版本及开发/测试/生产部署 receipt；
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
18. 19 列 `moonlightrecordv1`、payload `_meta`、并发 mutation/tombstone 总序和便携备份 V3 双 section 恢复评审；
19. Sunshine `v2026.516.143833` 或更高安全基线及所有当日未关闭 security advisory 的处置结论。

在这些确认完成前，Moonlight 只能保持为本计划中的待立项能力，不能通过 UI 暗示已经可连接或已经兼容全部 Sunshine/GameStream 主机。

## 15. 面向逐步执行模型的文件级实施手册

本节是第四次审计后新增的执行层。它不替代第 2–14 节的协议、安全、UI 和验收合同，而是把这些合同拆成可以逐项验证、逐项提交、失败即停的工作包。后续无论由 GPT-5.6 Luna、其他模型或人工执行，都必须按任务 ID 顺序维护执行台账；不能把一个阶段压缩成“接入 Moonlight”“完善 UI”或“支持云同步”一次完成。

### 15.1 执行纪律和单步完成格式

每次开始工作必须先执行仓库 `AGENTS.md` 的启动流程，继续当时未完成的 `codex/<task>` 分支，不切走、不 stash、不 reset、不覆盖用户修改。前置 SSH 与隐私任务已经闭环；Moonlight 已于 2026-08-09 从干净 `main@aeb0cdac5` 立项并进入 `codex/moonlight-complete-upgrade`，后续实施以任务台账和仓库门禁为准。

每个任务 ID 都使用以下五段式记录，缺一项不得标为完成：

1. **基线**：分支、HEAD、main、工作树、依赖 pin、目标设备/主机版本。
2. **范围**：本任务允许创建/修改的文件；发现额外公共改动时先更新计划并说明原因。
3. **合同**：输入、输出、owner/generation、失败/取消、持久化、UI 文案或 ABI 的明确行为。
4. **验证**：先运行本任务定向测试，再运行 `git diff --check`；阶段末运行双 Hvigor、native/双 ABI、Light 合规和独立复核。
5. **证据**：测试命令与结果、真机/主机日志、截图/录屏、AGC receipt、依赖 SHA/许可证、已知限制和回滚点。

一次提交只完成一个可命名合同；纯模型/策略、RDB schema、云协调、native control、媒体、输入、页面、会话浮层和发布合规不得混为一个提交。测试必须和生产变更同提交。任何 capability probe 未通过时保留 feature flag 关闭并写 blocker，不通过伪实现、空回调、硬编码 true 或隐藏失败来推进。

全程禁止以下捷径：

- 不把 Moonlight host/profile 塞进 `remotehosts`、Moonlight默认值塞进 `usersettings`、配对身份塞进其他协议 credentials。
- 不复用 `vncrecordv2`、`vnclocalrecords`、`RemoteDesktopVncPrefs` 或 VNC secret/trust owner；只复用经测试的通用 envelope/生命周期性质。
- 不在 AGC 三环境 schema 部署完成前把 `moonlightrecordv1` 加入生产 `TABLES`。
- 不在页面里直连 `CloudStore`、HUKS、HTTP/common-c 或全局 native 单例；UI 只调用当前 owner/session 的 service/repository。
- 不在 `RemoteDesktop.ets` 继续堆叠大段 Moonlight 业务；新增逻辑放独立 policy/service/component，入口页只组装。
- 不复制 MoonlightOH、Moonlight Android/Qt 的 UI 或第三方资源；代码/协议/品牌来源分别留证。
- 不在首版云同步或便携备份中携带 PIN、session token、`rikey`、私钥、本机 trust receipt、应用封面或诊断日志。
- 不把“保存成功”“已同步”“已连接”“已退出主机应用”建立在排队/请求发出之上，必须等待对应持久/云/首帧/主机响应终态。

### 15.2 依赖图和发布开关

~~~mermaid
flowchart LR
  G0["G0 基线、上游、安全、能力探针"] --> D1["D1 领域模型与纯策略"]
  D1 --> D2["D2 本地主机存储"]
  D2 --> D3["D3 本地账户、备份恢复"]
  G0 --> N1["N1 common-c 与主机控制面"]
  N1 --> N2["N2 视频与音频"]
  N1 --> N3["N3 输入与控制器"]
  D1 --> U1["U1 统一 scaffold、入口、设置、目录"]
  D3 --> U1
  N1 --> U1
  N2 --> S1["S1 会话页、浮层与生命周期"]
  N3 --> S1
  U1 --> S1
  S1 --> R1["R1 端到端、安全、性能、灰度发布"]
~~~

开关分层固定为：

| 开关/能力 | 默认 | 何时可开 | 关闭时合同 |
| --- | --- | --- | --- |
| `moonlightBrandAssetReady` | false | 官方资产 provenance/许可证/视觉验收完成 | 当前 system Symbol 占位；入口仍可显示“即将支持” |
| `moonlightHostControlReady` | false | 真实 Sunshine 完成 serverinfo/pair/catalog/launch/quit | 不出现可交互添加/配对入口 |
| `moonlightStreamingReady` | false | H.264+Opus+输入+生命周期 MVP 真机门通过 | 主机管理即使灰度可用，也不出现“开始串流” |
| `moonlightCloudSchemaReady` | false（deployed revision 0） | 用户按第 7.2 节创建并确认目标 AGC 表，客户端 revision 1，真实 optional registration/空表读写 receipt 通过 | 只移除 Moonlight runtime admission；旧 8 表、本地 repository 和 durable user intent 保持可用 |
| `moonlightCloudIdentityReady` | false（v1 不开放） | 未来独立完成 remote crypto lifecycle、E2E、恢复/撤销评审 | identity/trust/证书/私钥只留本机，不影响 settings/hosts/profiles 云同步 |
| `moonlightProtocolAvailable` | false | G0–S1 MVP 全部通过 | FAB 项保持禁用和“即将支持”，点击零副作用 |

这些名称是计划语义，实施时应集中到 `MoonlightFeaturePolicy.ets`/native build config，不能在页面散落布尔值。构建期开关只控制尚未部署的 schema/依赖，用户级开关只控制已安全交付能力；远端开关不能替代缺失的本地 schema 或 ABI。

### 15.3 G0：重建基线、锁定来源并完成能力探针

| ID | 允许范围与动作 | 必须验证/产物 | 停止条件与提交点 |
| --- | --- | --- | --- |
| G0-01 | 只读运行 workspace status，记录当时 `CURRENT/QUEUE/STATE`、branch/HEAD/main/dirty tree；确认不存在需继续的旧任务后才创建 Moonlight 任务分支 | 启动摘要和代码范围指纹 | 存在未完成分支就继续旧任务，不创建 Moonlight 分支 |
| G0-02 | 从官方 `moonlight-common-c`、Moonlight Android、Moonlight Qt、Sunshine 仓库重新抓取当日 HEAD/release；记录 commit、tag、submodule、SHA-256 | `docs/codex` 任务计划中的 upstream lock；链接只指官方源 | 网络/commit 无法验证即 blocker；不沿用本文旧 snapshot |
| G0-03 | 审计 common-c、ENet、Opus、OpenSSL、官方图标及任何补丁的许可证/NOTICE/source-offer 义务 | SBOM 草案、许可证矩阵、source bundle 方案、Light 结果 | 任一组合不满足分发要求则不 vendoring |
| G0-04 | 核对 Sunshine 当日 security advisories；最低基线不得低于修复 GHSA-ph75 的 `v2026.516.143833`，并处理之后所有适用公告 | 支持/阻断版本表，真实测试主机版本 | 主机落入已知关键漏洞基线则 UI 阻断并给升级说明 |
| G0-05 | 创建独立 native probe target，检查 API 23 双 ABI 的 socket/TLS/thread/monotonic clock、OH_AVCodec H.264 surface、OHAudio、Input Kit、Game Controller headers/libs | arm64-v8a/x86_64 编译结果和一台 ARM64 真机运行日志 | header 存在但运行失败仍算未支持；不在产品设置显示 |
| G0-06 | 真机探测 H.264 profile/level/resolution/fps、Surface 重建、Opus stereo、音频焦点、raw relative mouse/pointer capture、手柄枚举；高级反馈逐项探测 | `capability matrix`，每格是 supported/unsupported/pending + 证据 | pending 只能保持隐藏/禁用，不写“兼容” |
| G0-07 | 准备至少两台 Sunshine 主机/版本和局域网、IPv6、计费网络/受限网络；记录显卡编码器、端口和可恢复快照 | 可重复测试清单，不含口令/私钥 | 无真实主机则只能继续纯策略/构建，不进入主机控制验收 |
| G0-08 | 冻结 MVP：Sunshine 安全基线、LAN/用户自备可达网络、H.264、Opus stereo、键鼠/触控、已验证实体手柄；HEVC/AV1/HDR/7.1/rumble/公网便利功能默认关闭 | ADR/产品矩阵，feature flags 初值 | 决策未签字不进入 native vendoring；提交 `plan/probe` checkpoint |

### 15.4 D1：领域模型、状态机和纯策略（不接 UI、云或 native）

| ID | 文件与精确动作 | 定向测试 | 完成证据/下一步 |
| --- | --- | --- | --- |
| D1-01 | 新建 `entry/src/main/ets/model/MoonlightModels.ets`：定义 Host、Address、App、Profile、Settings、TrustCandidate、IdentityMetadata、EffectiveSettings；所有字段有长度/枚举/默认值，不含运行态 | `entry/src/test/MoonlightModels.test.ets` 覆盖合法/缺失/越界/未知枚举 | DTO 可独立编译；禁止引用 UI/CloudStore |
| D1-02 | 新建 `model/MoonlightRecord.ets`：精确声明 19 列 row、五种 recordType、owner 矩阵和 local row；物理字段名全部小写 | schema 列名集合/顺序、live/tombstone shape、localonly 测试 | 与第 7.2 节逐列一致 |
| D1-03 | 新建 `services/MoonlightRecordPolicy.ets`：canonical JSON、NFC/JCS、`_meta` 注入、payload hash、引用校验、size limit、tombstone、quarantine reason | `MoonlightRecordPolicy.test.ets` 覆盖每种 row、篡改、过新 schema、重复 key、NaN、hash、owner mismatch | 纯函数，无 RDB/时间/随机隐式依赖；随机/时钟由调用方传入 |
| D1-04 | 在 policy 中实现 current envelope order 和 `_meta` 并发检测；settings/profile 仅合并允许的 fieldVersions，host identity/trust/secret 冲突 fail closed | 两 writer、重试幂等、时钟回拨、相同 envelope 不同内容、tombstone/复活矩阵 | 不改变 VNC policy；冲突理由稳定可展示 |
| D1-05 | 新建 `MoonlightSettingsPolicy.ets`：全局→host→profile→session 四层合并、能力裁剪、实际值/请求值/原因 | preset、继承、逐项重置、unsupported codec/HDR/7.1、临时设置不持久化 | UI 可只消费 effective snapshot |
| D1-06 | 新建 `MoonlightCapabilityPolicy.ets` 和 `MoonlightFeaturePolicy.ets`：把 probe/host/native/云/发布能力变为可测试 truth，默认 fail closed | capability 组合表，确保一个下层 false 不会被 UI 子开关越权 | 不读取页面状态，不硬编码“所有设备支持” |
| D1-07 | 新建 `MoonlightSessionState.ets`：disconnected/discovering/verifying/pairing/catalog/launching/negotiating/video/audio/input/firstFrame/streaming/reconnecting/stopping/failed，并定义合法迁移和错误码映射 | 合法/非法迁移、cancel、迟到 generation、降级、first-frame gate | 通用 `RemoteSessionState` 暂不修改；提交 `domain-policy` checkpoint |

### 15.5-HISTORY D2-local：本地主机存储基础合同（已完成并继续保留）

D2-local 曾是唯一执行路线；现在作为可选云同步下方不可回退的本地基础层继续有效。
`moonlightlocalrecords` 与 `moonlightappcache` 的 owner/lease/backup/delete 合同不得因上云
削弱；其中“零云调用”“不得创建 optional projection”只描述 2026-08-10 历史阶段，已被
第 7.0 节覆盖。

| ID | 文件与精确动作 | 定向测试/数据合同 | 完成证据/停止条件 |
| --- | --- | --- | --- |
| D2-L01 | 审计 `CloudSyncPolicy.ets`、CloudStore startup 和 Moonlight imports；将 Moonlight 当前写入/读取路径收束到 local table，保证启动/登录/账号切换不会创建 Moonlight 云注册或投影任务 | `CLOUD_SYNC_TABLES` 仍精确 8 项；启动、账号 A/B、云可用/不可用四矩阵；source scan 禁止 Moonlight 调用 `setDistributedTables`/CloudSyncCoordinator | 只允许 `moonlightlocalrecords`/`moonlightappcache` 的本地 SQL；云表/selection/transfer 代码仅作 parked reference，不进入 runtime wiring |
| D2-L02 | 校准 `MoonlightStoragePolicy.ets`、owner-store migration 和 `MoonlightRecord.ets`：20 列本地 envelope、16 列可重建 cache、schema v5；每个本地写入固定 `localonly=1` | 首次安装、v4→v5、重复打开、schema 列顺序/类型、失败回滚、localonly 非 1 拒绝 | API 23/24 可重建 RDB receipt；不能新增 Moonlight 云表或修改其他协议 schema |
| D2-L03 | 收束 `MoonlightRepository.ets`：所有 upsert/tombstone 只落 local overlay；携带完整 `AccountSessionLease`，读写前后 owner/generation/storeInstance 二次校验，事务后 readback | 新建/编辑/重复 mutation、stale lease、账号 A/B 同 id、数据库写失败、进程中断恢复；每个结果 `cloudAttempted=false` | local-only 主机增删改可重试、幂等；旧 lease 零污染新 owner；不提供 local→cloud promotion API |
| D2-L04 | 收束 `MoonlightAppCacheService.ets`：owner+host+app key、ETag/hash/expiry/artwork path、完整/部分刷新、过期优先+稳定 LRU、有界总量 | 空目录、部分目录失败、过期、重复 app、损坏封面、磁盘不足、账号切换；cache 删除不触碰 profile/host | `moonlightappcache` 永不进入业务备份、云注册或 host truth；目录可丢弃并由主机重建 |
| D2-L05 | 接现有 Local Backup V3 的 local section：备份/导入只包含 `moonlightlocalrecords` 的允许 recordType；cache、journal、quarantine、session marker、PIN、token、私钥和 secure-store alias 排除 | 旧 V3→新版本、新 V3→旧 reader、redacted/full、损坏 hash、owner A→B、重复恢复、磁盘满、恢复中切账号 | 恢复 quarantine→用户预览→当前 lease 内原子本地提交；全部恢复记录仍 `localonly=1`；不触发 cloud-first/upload |
| D2-L06 | 接 `MoonlightDeletionCommandService` 的本地命令：删除 host、profile、trust、secret metadata、cache、journal/restore marker 的 exact impact preview；unpair 仍等待真实 Host Control port | 取消/重复/过期 preview、删除失败、孤立 secure identity、无 Host Control、部分本地清理；本地终态与远端 warning 分离 | 本地删除可准确重试；没有远端 port 时零伪造 unpair 成功，不创建 cloud tombstone |
| D2-L07 | 增加 local-only wiring/静态审计 receipt，更新 CURRENT/QUEUE；不加入任何 Moonlight 云 UI、CloudStatus、selectedTables 或上传按钮 | native/ArkTS 定向测试、8 表集合、source scan、Light、双 Hvigor；Moonlight 入口仍 disabled | 提交 `d2-local-storage` checkpoint；当前版本本地主机存储完成后才进入 Host/UI/media 装配 |

### 15.5-CLOUD-ACTIVE：D2 云表、CloudSync 和 AGC 适配

以下 D2 云任务已由 2026-08-19 用户决定重新激活。代码部分必须先完成并审查；唯一外部
停点是 D2-05/06 的 AGC 建表 receipt。客户端不得在 receipt 前把 deployed revision 从 0
改为 1，也不得用可选表失败覆盖旧八表 baseline。

执行顺序固定为：本地 exact schema/adapter → core-eight + optional-nine 隔离实现 → 用户创建
AGC 表 → revision 1 → 真实注册与传输矩阵。不得颠倒。

| ID | 文件与精确动作 | 定向测试/数据合同 | 完成证据/停止条件 |
| --- | --- | --- | --- |
| D2-01 | 在 `CloudStore.ets` 的同一个 owner-store schema migration 新建 `moonlightrecordv1`、`moonlightlocalrecords` 与 local-only `moonlightappcache`；只有第一张具备后续 distributed registration 资格 | 从每个仍支持旧 schema 升级、重复打开幂等、失败回滚、19/20 列 envelope 与 cache schema exact test | migration receipt 和本地 RDB inspection；不得碰用户现有表数据，cache 不出现在云表清单 |
| D2-02 | 新建 `MoonlightRepository.ets`：所有 upsert/tombstone 先写 local overlay，接受 `AccountSessionLease`，写前后校验 owner/generation/storeInstance | stale lease、事务失败、重复 mutation、本地模式、账号 A/B 同 id | local-only 主机可完整增删改，零 cloud 调用 |
| D2-03 | 新建 app cache service：使用 D2-01 的 `moonlightappcache`，key 含 owner+host+app，保存 ETag/hash/expiry/artwork local path；限制条数/体积并 LRU 清理 | 过期、目录为空、部分刷新、封面损坏、owner 切换、磁盘不足 | cache 删除不删除 profile；不出现在 CloudSyncPolicy/BackupManifest |
| D2-04 | 修改 `CloudTableAdapter.ets`，增加 `moonlightrecordv1` exact 19 列映射；未知/缺列拒绝，不做默认补齐 | 扩展 `CloudTableAdapter.test.ets` 比较 column set、round-trip、malformed row | adapter 只传 envelope，不解释业务 payload |
| D2-05 | 在 AGC 开发环境按第 7.2 节创建表、权限和已验证索引，运行空表/单行/tombstone/分页/删除演练 | 控制台导出或受控 receipt，列类型/长度/索引/用户隔离结果 | 任一不一致先改计划/schema；不得先改客户端 TABLES |
| D2-06 | 将相同 schema 部署测试和生产环境；用非生产测试 owner 验证服务端授权，禁止跨 userid | 三环境 schema hash/时间/执行人/回滚方案 | 生产未部署则 `moonlightCloudSchemaReady=false`，停止 D2-07 |
| D2-07 | 修改 `CloudSyncPolicy.ets` 把 `moonlightrecordv1` 加入分布式表；修改 `CloudSyncSelectionPolicy.ets` 作为一个普通可选择 physical item，默认数组仍为空 | 扩展两项现有测试：顺序、注册集合、default empty、normalize、加密表分类 | 旧 8 表行为和顺序回归；setDistributedTables 真机成功 |
| D2-08 | 修改 `CloudSensitiveTransferPolicy.ets` 增加 Moonlight row-aware 检查：任何进入 physical projection 的 live identity row 都必须是 authenticated ciphertext；identity scope 关闭时 repository 不新建/提升 identity 云 row，既有 ciphertext row 仍按安全策略处理；crypto reset 时暂停会携带身份行的整表 native-first | 无 identity、合法 ciphertext、plaintext/坏 envelope、scope off、crypto configured/reset、只含非 secret row 测试 | 不能因 settings 同步顺带发布本地 identity，不能把已在云端的 ciphertext 误当明文删除，也不能破坏 VNC 规则 |
| D2-09 | 新建 `MoonlightCloudSyncSelectionPolicy.ets`/`Store.ets`：五 scope、默认 `[]`、ownerScopeId preference key、stage→RDB projection→persist 回滚合同 | normalization、owner A/B、Preferences 写失败、identity capability false | 不读取 VNC prefs；UI 与 durable selection 不分裂 |
| D2-10 | 新建 `MoonlightCloudSyncService.ets`：recordType→scope、pull validate/materialize、local promotion、tombstone、quarantine；页面不可调用 CloudStore | physical off/logical off/identity off/cloud-first/promotion/malformed/partial table failure | 单表失败不回滚其他协议或登录；提交 `cloud-table-adapter` checkpoint |

### 15.6-HISTORY D3-local：本地账户、删除、备份恢复基础合同（继续有效）

D3-local 的本地 owner/store、备份恢复和安全删除保证继续有效；“不得创建云 selection/request”
只描述历史 local-only 阶段。当前云路径必须建立在这些本地保证之上，并继续证明 Moonlight
不会改变既有协议云同步合同。

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| D3-L01 | 在 `AccountSessionCoordinator.ets`/`SensitiveDataBarrier.ets` 接入 Moonlight local drain：切换前关闭 host edit/pair/launch、停止 session/identity/local journal，撤销旧 lease，再绑定新 owner | 正常/失败/超时/强杀/重复切换；旧 callback 不能更新新列表；云可用性变化不改变 Moonlight local read | local account lifecycle receipt；阻塞时保持旧 owner，不泄漏新 owner |
| D3-L02 | 完成本地恢复 resolver：验证 manifest、owner、schema、hash、引用、tombstone 和 secure identity metadata，先 quarantine 后预览/原子提交 | 同 id、owner A→B、非法 row、孤儿 profile/trust、重复导入、磁盘满、恢复中切账号 | 恢复只提交 `moonlightlocalrecords`，全部 `localonly=1`；不触发 cloud-first、upload 或 cloud tombstone |
| D3-L03 | 完成“删除全部 Moonlight 数据”本地 exact set：settings、host/profile/trust、identity metadata、cache、local journal/quarantine/restore marker；私钥先通过 secure owner 清理 | 预览重算、取消、重复、部分清理、孤立 secure identity、进程中断后重试 | 删除报告区分 RDB、cache、secure identity；不把远端 unpair 伪造为完成 |
| D3-L04 | 生成 local-only 数据状态 snapshot：`localSaved`、`localDirty`、`localRestorePending`、`localQuarantined`、`secureIdentityState`；禁止 `synced/pendingUpload` 等 Moonlight UI 状态 | owner A/B、云登录/退出、云失败/恢复、备份/恢复、空库；状态只能由真实本地记录推导 | U1/S1 只订阅此 snapshot；没有 Moonlight cloud badge 或同步设置 |
| D3-L05 | 更新 local backup inventory/manifest 和删除命令的文档/receipt；验证现有 8 表云同步回归未变 | Local Backup V3、既有 8 表集合、RDP/RustDesk/SSH/VNC 云回归、Light、双 Hvigor | 提交 `d3-local-lifecycle` checkpoint；云同步问题不再阻断本地主机开发 |

### 15.6-CLOUD-ACTIVE：D3 CloudCoordinator、云选择和多设备

以下 D3 云任务进入当前路线：CloudCoordinator wiring、cloud-first、physical/logical selection、
云 tombstone、跨设备冲突和双设备矩阵。v1 明确排除 secret/identity/trust 云恢复；任何实现或 UI
都不得借“完整功能”扩大这一隐私边界。

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| D3-01 | 在 `CloudSyncCoordinator.ets` 增加 Moonlight table request/status/retry/bootstrap wiring；优先新增 `CloudStoreMoonlightLifecycleWiring.ets`，避免继续把领域逻辑塞进 coordinator | 启动 pull、手动上传/下载、retry 1/5/30s、suspicious empty、partial failure、stale callback | VNC wiring 测试全绿；Moonlight 状态能独立展示 |
| D3-02 | repository/coordinator 所有 promise/callback 携带完整 `AccountSessionLease`；完成前二次校验，旧 generation 只能被丢弃并计数 | 账号 A 请求→切 B→A 迟到成功/失败/进度；storeInstance 重开 | B 的 UI/RDB/selection 零污染 |
| D3-03 | 修改 `AccountSessionCoordinator.ets` 和 `SensitiveDataBarrier.ets`：切换前关闭 Moonlight mutation/launch，停止 session、pairing、identity restore、journal/cloud task，再 quiesce store | 正常/失败/超时/强杀/重复切换；barrier 失败保持旧 owner | 不允许“先换 owner 后等旧任务”；独立 lifecycle test |
| D3-04 | 把 `moonlightrecordv1` 与 `moonlightlocalrecords` 登记到 `BackupManifestV3.ets`、`LocalBackupPolicy.ets`、`LocalBackupService.ets`；实现第 7.11 内容矩阵 | 旧 V3→新 app、新 V3→旧 reader 行为、redacted/full、local-only、unknown section、32 MiB、hash | manifest 明示 identity omitted；不含 cache/marker/journal |
| D3-05 | 在 `CloudStoreRestoreResolutionWiring.ets` 增加 Moonlight resolver：两个 section 先 quarantine/去重，最终只提交 local overlay；已启用云时 cloud-first 后再 promotion | 同 id 双来源、云 tombstone、trust conflict、账号 A 文件→B、device-local→account、恢复中切账号/磁盘满 | 导入不直接 local-first 覆盖云；失败整批回滚 |
| D3-06 | 实现“取消同步/删除云数据/删除本地/忘记主机/unpair/删除 profile”五类命令对象和影响预览；云删除写 tombstone 并等待终态 | 每个命令影响集合、撤销/重试、主机无响应、其他设备可见性 | 文案与实际删除集一致，取消选择不写 tombstone |
| D3-07 | 扩展云设置状态模型：physical selection、五 scope、bootstrap、pending upload、quarantine、last success/error 独立展示 | offline、无 platform identity、crypto locked、partial failure、empty selection | 不用一个“已同步”布尔覆盖所有状态 |
| D3-08 | 运行双设备/双账号/设备本地数据矩阵和便携备份恢复矩阵，保存脱敏 receipt | 第 7.5–7.11 全矩阵，其他 8 表同步回归 | `data-lifecycle` checkpoint；未通过不做 UI 的云开关 |

#### 15.6.1 D3 实施校准（2026-08-19 覆盖）

下表保留 2026-08-10 的代码基线说明；当前状态与剩余动作以实施台账第 10 节为准，不能仅凭
旧状态字符串重复实现或重新停靠已经接通的 coordinator/selection/deletion 合同：

| ID | 当前源码状态 | 已完成边界 | 唯一剩余边界 |
| --- | --- | --- | --- |
| D3-01 | ONLINE BLOCKED / STATUS POLICY PASS | 独立状态 policy 已覆盖 physical、五 scope、bootstrap、pending、quarantine、last success/error、identity crypto lock | 真实 request/retry/bootstrap wiring 依赖 D2-07；不得提前改八表集合 |
| D3-02 | LOCAL/DORMANT PASS | repository、selection、materializer、barrier 均使用完整 `AccountSessionLease` 并在事务边界复核 | D2-07 后补真实 coordinator callback 的 A→B 迟到污染测试 |
| D3-03 | CONTRACT PASS / RUNTIME PENDING | `SensitiveDataBarrier` 已在 store quiesce 前按 mutation/launch→session→pairing→identity restore→cloud/journal→runtime secrets 排序 drain；新 store 激活后绑定 lease | N1/S1 注册真实 runtime port 后补超时、强杀、旧 callback 和 secret 清零验收 |
| D3-04 | PASS | Backup V3 optional descriptor 和 cloud/local 双 section 已落地；旧 V3 无 section 可读，新 V3 对旧 inventory fail closed；redacted/full 矩阵固定 | 任何旧 reader 静默忽略未知 section 的新证据都会触发 Backup V4，不允许带风险兼容 |
| D3-05 | LOCAL RESTORE PASS / CLOUD PROMOTION BLOCKED | exact/owner/semantic validation、冲突/孤儿 quarantine、tombstone、目标 owner rebound 和最终仅 `moonlightlocalrecords`/`localonly=1` 已落地 | D2-07 后才能做 cloud-first/promotion；设备级故障原子性归 D3-08 |
| D3-06 | LOCAL EXECUTION PASS / CLOUD+HOST PENDING | 六类命令从当前 owner 的 exact 业务行、cache、journal/quarantine/restore marker 与 secure identity inventory 生成预览并在执行前重算；settings 已纳入删全部；本地删除/忘记 host/删 profile 使用 CloudStore 单事务，identity 安全材料先清且单独报告终态 | checkpoint `ea32ffa`；D2-07/terminal port 前 cloud tombstone 返回 unavailable，N1 Host Control 前 unpair 返回 unavailable；U1 不得提前暴露 |
| D3-07 | POLICY PASS / UI PENDING | 不使用“已同步”单布尔，状态输出已独立建模 | U1-11 消费此 snapshot；physical/schema truth 为 false 时必须显示 off/unavailable |
| D3-08 | EXTERNAL PENDING | 138 个 Moonlight 测试用例覆盖纯策略、备份和本地生命周期编译合同 | 双设备/双账号/device-local/真实云/恢复故障/旧八表回归需要外部环境 receipt |

D3-04/05 的不可变实现合同如下：

1. 备份格式仍为 V3；Moonlight descriptor 和两个 section 都是 V3 的可选扩展，旧文件缺失等价于 Moonlight 记录数为零。
2. redacted 只允许 settings、host、profile；full 在此基础上只增加 trust candidate。两种模式都排除 secret/client identity、PIN、token、私钥、本机 trust receipt、app cache、journal、quarantine、bootstrap、selection 和 recovery marker。
3. 源库 admission 对未知/缺失列、外来 owner、重复 id、非法 `localonly` 和语义损坏整批失败；不能把坏行静默过滤后生成不完整备份。
4. 恢复同时裁决 cloud/local section，但最终只原子提交目标 owner 的 local overlay，全部 `localonly=1`；不会直接触发云上传，也不会设置会冻结 RDP/SSH/VNC/RustDesk 的公共恢复 marker。
5. 相同 id 的等 envelope 歧义或 identity 冲突隔离双方；live profile/trust 没有 active host 时隔离；trust 恢复后仍是候选，配对身份始终要求重新配对。
6. D3-03 代码 checkpoint 为 `05e96d3`，D3-04/05 checkpoint 为 `b27a58a`，D3-06 本地命令 checkpoint 为 `ea32ffa`；19 个 describe、138 个 Moonlight test 只具备编译注册证据，当前不宣称 Hypium 设备执行。
7. D3-06 的预览不能信任 UI 传入计数：执行器从当前 lease 的 owner 行、cache 和 runtime state 重新生成 exact set；新增/删除任一目标会得到 `stale_preview`。删除全部包含 settings、host/profile/trust、identity metadata、cache、Moonlight local journal/runtime quarantine/restore marker，并在安全身份端口可枚举时清理没有 metadata row 的 owner 孤立身份。
8. 普通本地删除不制造 cloud tombstone；需要 tombstone 的忘记/unpair/profile/删云命令在 terminal cloud port 缺失时零写入。unpair 在 Host Control port 缺失时零写入；真实端口返回失败时允许保留已完成的本地安全终态，但必须以 warning 明示远端未确认。

### 15.7 N1：官方 common-c、Host API、配对与应用控制

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| N1-01 | 按 G0 pin 把原样 upstream 放 `entry/src/main/cpp/moonlight/upstream/`，补 commit/SHA/license 清单；项目补丁放独立 `patches/`，不直接失去来源 | 双 ABI 单独静态库构建、upstream tests（可用时）、source archive 重建一致 | 无产品 NAPI；`vendor-common-c` 独立提交 |
| N1-02 | 修改 CMake 将 common-c/ENet 作为隔离静态目标链接 `rdpnapi`；警告、宏、异常/RTTI、OpenSSL/Opus 符号边界明确 | RDP/RustDesk/SSH/VNC 在不启用 Moonlight 时二进制/测试不回退；符号/ABI 检查 | 不把 upstream include 全局泄漏 |
| N1-03 | 新建 `moonlight/core/MoonlightSessionOwner.*`：sessionId、generation、owner token、cancel token、线程/回调计数；common-c start/stop 全局串行但实例状态独立 | 两个启动请求仲裁、重复 stop、stop 中新 start、旧 callback | 不依赖 `g_activeConnection` 判断归属 |
| N1-04 | 新建 `moonlight/core/MoonlightHostApi.*`：serverinfo、version/capability、app list、launch/resume/quit、超时、取消、地址尝试；与媒体 adapter 分开 | XML/parser fuzz、HTTP 状态、TLS 错误、IPv4/IPv6、超时、取消、响应脱敏 | host API 不持久化 secret、不调用 ArkUI |
| N1-05 | 新建 secure identity bridge：owner-scoped RSA/client cert 生命周期、HUKS/Asset Store alias metadata、内存清零；OpenSSL 只获得最短期签名/解密能力 | owner A/B、重装、删除、并发 pairing、alias 不可跨 owner、日志扫描 | 无明文私钥落盘；探针不支持时 blocker |
| N1-06 | 实现官方兼容 pairing 状态机：生成 PIN→challenge→主机确认→server cert candidate→用户 trust→commit；取消/超时 best-effort unpair | 真实 Sunshine、错误 PIN、超时、证书变化、取消时临时 identity 清理 | UI 尚不接入；事件序列/错误码稳定 |
| N1-07 | 实现 app catalog、launch/resume/quit 命令；区分“仅断开”和“退出主机应用”，记录 success/failure/unknown | 官方客户端互操作、主机忙、已有 app、quit 无响应、id 失效 | 请求发出不算成功；不会默认 quit |
| N1-08 | 新建 `moonlight/bridge/MoonlightNativeBridge.*`、`moonlight/moonlight_napi.*` 和 ArkTS `MoonlightHostService.ets`，并更新唯一发布 d.ts：typed request/event，所有事件含 request/session generation | NAPI 参数错误、回调线程 marshal、取消、页面销毁、账户切换和迟到事件 | 不扩张通用 `ProtocolAdapter` 承载 pairing/catalog；提交 `typed-host-bridge` checkpoint |

#### 15.7.1 N1-01 已完成事实与 N1-02 唯一执行合同（2026-08-10）

N1-01 已由 checkpoint `0013ba034` 完成：117 个上游文件原样保存在独立目录，common-c、ENet、nanors 的 commit/tree/license/content manifest 已机器锁定；校验器可在普通无 `.git` 源码归档中重建三个官方 Git tree，并以 `160000` 模式验证 common-c 的两个 gitlink。shell/PowerShell 7 双 ABI静态构建都匹配锁文件中的四个 deterministic receipt；NOTICE/SPDX/hash/source offer、patch 分离与幂等生成门禁已落地。产品 `CMakeLists.txt`、NAPI、ArkTS、云表注册和 UI 未接线，签名 HAP 与 `rdpnapi` 仍不含 Moonlight 符号。

N1-02 只能修改主 CMake、项目拥有的 `moonlight/CMakeLists.txt`、N1-01 standalone wrapper 及必要的构建验证脚本/文档，按顺序执行：

1. 记录两 ABI `rdpnapi` export/undefined symbol inventory、签名 HAP 内容和现有 native/Hvigor 基线；不以包含 build timestamp 的整库 hash 判断 ABI 回归。
2. 在 `moonlight/CMakeLists.txt` 唯一定义静态 common-c/ENet target：复用 `libs/openssl/install`，目录作用域关闭 shared build/install，校验 ABI输入和 target 类型，只给两个第三方 target 加狭窄 Clang 诊断豁免。
3. standalone `vendor-build` 必须改为消费同一边界并继续命中 N1-01 四个 archive receipt；不得复制第二套 CMake 配置或编辑 upstream。
4. 主 CMake 在既有 OpenSSL imported target 之后 `add_subdirectory(moonlight)`，只以 `PRIVATE`/`LINK_ONLY` 语义链接包装 target；不得新增全局 include、definition、link directory 或 whole-archive。
5. 不新增 NAPI/ArkTS/runtime source，不注册协议/云表，不改变六个 capability truth、FAB、设置或路由；静态 archive 因尚无引用而不应凭空形成用户可调用能力。
6. 两 ABI验证目标参与依赖图、无未解析 `Li*`/`enet_*`/OpenSSL 符号、无新增 NAPI export、上游 include 未全局泄漏；再跑现有协议 native tests、N1 receipt、双 Hvigor、signed HAP、TOTP/Light、diff/state。
7. N1-02 单独提交；任一 ABI、现有协议或产品隔离证据失败就回退该构建边，不进入 N1-03。

#### 15.7.2 N1-02 已完成事实与 N1-03 唯一执行合同（2026-08-10）

N1-02 已由 checkpoint `99edc58` 完成：`entry/src/main/cpp/moonlight/CMakeLists.txt` 是 product 与 standalone 唯一共享的 common-c/ENet target 定义，限定 static、PIC、API 23 ABI、既有 OpenSSL crypto 和两个上游 target 的窄 warning 豁免。主产品只通过 `PRIVATE`/`LINK_ONLY` 接入；两 ABI link graph 有静态 archive，47 个产品 compile command 均无 upstream include 泄漏。链接前后 `librdpnapi.so` 的 exported/undefined/NAPI-related inventories 逐字一致，没有未解析 Moonlight/ENet/OpenSSL symbol；签名 HAP 前后都是同一 423 项路径 inventory。host native 342/342、shell/PowerShell 四个 deterministic receipt、两项 Hvigor、signed HAP、vendor/TOTP/Light/diff/state 全部通过。NAPI、ArkTS、云注册、feature truth 和灰色 FAB 均未改变。

N1-03 只能修改主 CMake、新建的 `moonlight/core/MoonlightSessionOwner.h/.cpp`、一个 focused native test 文件及必要状态文档，按顺序执行：

1. 以 `99edc58` 保存 host native count、两 ABI symbol/HAP inventory 和产品构建基线；任何旧协议回归都停止 N1-03。
2. public owner header 只定义项目自有 C++17 类型，不包含 `Limelight.h` 或其他 upstream header；key 必须同时含非零 `sessionId`、`generation`、不可复用 `ownerToken`，不能只凭当前全局连接判断 callback/stop 归属。
3. 生命周期固定为 `idle → starting → running → stopping → stopped/failed`；每个 owner 有 cancel token、callback/worker admission gate、in-flight counts 和只读 snapshot。非法迁移 fail closed，不自动重绑 key。
4. 唯一 process-wide coordinator 通过窄 callable/driver seam 串行 future common-c operations。一个 start 占用车道后，其他 start 返回稳定 `busy`，不排队、不抢占；测试 seam 不伪造 serverinfo/stream config，生产在 N1-03 仍没有 callable NAPI。
5. starting 期间 stop 只触发一次 cancel/interrupt，必须等 start callable 返回后才可 stop；running stop 最多执行一次；start 失败按 common-c 已自行 cleanup 处理，不再双 stop。stale/repeated stop 零副作用且结果稳定。
6. stop 先关闭新 callback/worker admission，再等待已发 lease 归零。lease 不可复制、析构精确减计数；drain 超时后保持 `stopping` 并继续占用全局车道，禁止下一连接，不用 detach 或清空指针伪装停止。
7. 测试用 condition/barrier 和有界 deadline 证明两个并发 start、blocked-start 中 stop、一次 interrupt/stop、start failure、重复/stale stop、callback/worker drain、timeout fail closed、旧 generation callback 拒绝、snapshot/count 和 driver exception；禁止以 sleep 猜竞态。
8. 生产 `MOONLIGHT_SOURCES` 与 host test source 只登记 owner；不新增 Host API、NAPI/ArkTS、媒体/输入、secure identity、云/UI/资源或 capability true。新增定向测试和既有 native 全回归、双 ABI/符号/HAP 隔离、双 Hvigor、TOTP/Light/diff/state 均通过后单独提交，才允许 N1-04。

#### 15.7.3 N1-03 已完成事实与 N1-04 唯一执行合同（2026-08-10）

N1-03 已由代码 checkpoint `18cdd39aa` 完成。`MoonlightSessionOwner` 只使用
项目自有 hidden C++ 类型，key 固定为非零 `sessionId + generation + ownerToken`；
生产只有 process singleton，测试实例仅在既有 native-test define 下开放。一个 owner
从 start admission 到 callback/worker drain、interrupt 和 stop 全程占用唯一车道；
cancel 在 common-c interrupt flag 初始化后的显式 fence 才触发。interrupt 从预留到
返回都计入 control operation，因此新 start 和 stop 不能越过一个尚未返回的
interrupt。超时保持 `stopping` 和车道占用，不 detach、不清指针伪装成功。

13 个 barrier/deadline 用例覆盖真实并发 start、stop-during-start、late interruptible
fence、interrupt/stop 串行、start/stop/interrupt 异常、stale generation、重复 stop、
callback/worker drain、timeout fail closed 与析构 join；沙箱外 native **355/355
PASS**。两 ABI产品各有 48 个非上游 compile command、恰一个 owner command、零
upstream include leak；defined/undefined/`napi|init|register` inventory 与基线逐字
相同，签名 HAP 仍为同一 423 项。双 Hvigor、vendor、TOTP、Light、diff/state 均
通过。NAPI、ArkTS、云、资源、UI 和所有 feature truth 没有改变。

N1-04 必须把锁定的官方 Android `NvHTTP`/`PairingManager` revision 当作 wire 事实，
但不能复制 Android/OkHttp/XmlPullParser 实现，也不能把后续 pairing/identity/UI
提前塞进本步。按以下原子步骤执行：

1. 以 `18cdd39aa` 保存 355 项 native、两 ABI symbol/NAPI audit、每 ABI 48 条
   产品命令和 423 项 HAP inventory。代码范围只允许主 CMake、新建
   `moonlight/core/MoonlightHostApi.h/.cpp` 与一个 focused native test 文件；若
   发现必须改旧协议/公共网络层，先停下补计划和旧协议回归，不复制 VNC/RDP 私有
   socket helper。
2. public header 只包含项目自有 C++17 value type/PIMPL：endpoint、operation、
   immutable request/response、server-info、app、launch/quit terminal result、stable
   error 与 diagnostic snapshot。不得包含 common-c/OpenSSL/NAPI/ArkUI header，
   不得接受/返回 PIN、PEM 私钥、session token 或原始 `rikey` bytes。
3. 每个操作携带不可重绑定的非零 `requestId + generation + ownerToken` 和 shared
   cancel state；开始、每次 attempt、transport 返回、解析 commit 前都复核 exact
   key 与同一 monotonic absolute deadline。迟到 response 只能成为 stale/cancelled，
   不能发布给新 generation；析构 cancel 并 drain，不 detach worker。
4. URL builder 固定官方兼容值：HTTP 默认 `47989`、HTTPS 默认 `47984`、
   `uniqueid=0123456789ABCDEF`、每请求独立 UUID。IPv6 authority 正确加 bracket，
   SNI/serverName 与连接地址分离，query 逐值 percent-encode；只允许 GET、
   `http/https`、端口 `1..65535` 与白名单 endpoint，拒绝 redirect/proxy/user-info/
   fragment/CRLF 和重复保留参数。
5. `serverinfo` 可在未配对 HTTP 读取候选；已有 pin 时先走 HTTPS。`applist`、
   `appasset`、pair challenge、launch/resume/cancel 必须 authenticated HTTPS。证书
   不匹配只返回 `trustConflict`；为重新配对读取的 HTTP candidate 不能维持 paired/
   launch truth。N1-04 可形成 pair/unpair request shape，但不执行 N1-06 密码学；
   launch/resume 只消费 caller 提供的 opaque launch material，不生成/持久化 rikey；
   `rikey` 仅接受 32 hex、`rikeyid` 兼容官方 signed 32-bit，且固定 `corever=1`。
   cancel 的 200 不是完成证据，必须再以 authenticated `serverinfo/currentgame=0`
   确认；busy、复核失败或歧义都返回稳定的非成功终态。
6. 唯一 transport seam 接收 immutable request、absolute deadline、cancel probe 与
   response budget，返回 DNS/connect/TLS/HTTP/body stage 以及
   `notSent / sentResponseUnknown / confirmedResponse`。read-only 可按冻结的地址
   优先级顺序尝试；mutation 一旦可能已发送就禁止换地址自动重放，返回 unknown
   交给显式复核。N1-05 再实现 owner-scoped TLS client identity adapter；N1-04
   没有 NAPI caller，也不持久化 transport secret。
7. budget 固定为 URL ≤ 8 KiB、body ≤ 4 MiB、XML depth ≤ 32、elements ≤ 16384、
   attributes ≤ 16/element、name ≤ 64 bytes、attribute ≤ 1 KiB、单 text ≤ 256 KiB、
   apps ≤ 2048、title ≤ 1 KiB。只允许一个有界且位于 root 前的 XML declaration；
   拒绝其他 processing instruction、DTD/DOCTYPE、外部或自定义 entity、NUL、非法
   UTF-8、未闭合/错配标签、重复 root 和 trailing non-whitespace；只解码五个
   builtin entity 与合法 numeric entity。
8. XML root 必须有唯一十进制 `status_code`；按官方行为接受 `0..UINT32_MAX` 后
   映射 signed 32-bit（含 `0xFFFFFFFF → -1`），只有 200 提交业务结果。serverinfo
   必填 `uniqueid/appversion/state/PairStatus/currentgame`，appversion 必须四段有界
   整数；其他 host/version/port/address/GPU/codec/luma 字段是有界 optional。
   applist 只提交正整数唯一 ID、非空 title 和可选 HDR；缺字段计入 bounded partial，
   冲突 duplicate ID 或同 ID 不同 title 整批失败。
9. timeout 只使用一个 absolute budget，不能因 DNS、地址切换或 body progress
   重置；参考官方 3s short-connect、5s long-connect、7s read，caller 下限固定
   100ms，普通操作上限 30s，只有用户正在等待 PIN 的初始 `getservercert` pair
   阶段允许 120s。HTTP status 与 XML status 分开；404/401、TLS version/chain/pin、timeout、
   cancel、body-too-large、malformed XML、host busy、action unknown 都使用 stable
   code。diagnostics 只保留 operation/stage/attempt/family/port/status/bytes/duration/
   masked endpoint，禁止完整 host、query、UUID、证书、PIN、token、rikey、XML body
   或 app title；debug formatter redact 所有 query value。
10. focused tests 覆盖官方 serverinfo/applist/launch/resume/cancel fixtures、未知字段、
    partial app、duplicate ID、`0xFFFFFFFF`、DTD/entity bomb、深度/数量/长度/UTF-8/
    截断、IPv4/IPv6/percent encoding、HTTP/XML status、TLS/pin error、deadline/cancel/
    stale generation、read-only fallback、mutation no-replay、unknown result 和 secret
    canary。全量 native、双 ABI产品/符号/HAP、双 Hvigor、vendor/TOTP/Light/diff/
    state 全通过并单独 checkpoint 后，才允许 N1-05。

#### 15.7.4 N1-04 已完成事实与 N1-05 唯一执行合同（2026-08-10）

N1-04 已由代码 checkpoint `fd2d7ec92` 完成。`MoonlightHostApi` 是无 NAPI caller
的 project-owned C++17/PIMPL core；15 个定向用例覆盖 official endpoint/query、
transactional bounded XML、512 个确定性 fuzz body、exact request key/cancel/stale、
单 absolute deadline、IPv4/IPv6/SNI、read-only fallback、mutation no-replay/unknown、
trust conflict、authenticated cancel verification 和 secret canary。沙箱外 native 与
ASan/UBSan 都是 **370/370 PASS**。两 ABI各保持 48 个 `rdpnapi` compile command，
新增 Host API 恰好各一个 private archive command、零 upstream include leak；
defined/undefined/`napi|init|register` inventory 与 N1-03 基线逐字一致，签名 HAP
仍为 423 项。双 Hvigor、platform probe、四个 vendor receipt、三 tree/117 文件、
合规生成幂等、TOTP、Light 和 diff 均通过。生产 transport、identity、pairing、
ArkTS/UI、云、媒体、输入和 feature truth 均未接入。

N1-05 只建立 owner-scoped secure identity bridge 和平台能力证据，不实现 PIN/challenge
配对状态机，不把 identity 暴露给 ArkTS。按以下原子步骤执行：

1. 以 `fd2d7ec92` 保存 370 项 native、两 ABI symbol/NAPI/HAP inventory、每 ABI
   48+1 条产品/private-archive compile command 与双 Hvigor结果。代码范围优先限定
   为主 CMake、新建 `moonlight/security/MoonlightSecureIdentity.h/.cpp`、必要的窄
   platform backend/probe 和一个 focused native test；不得改 `host_locker.cpp` 的
   TODO 实现、通用 `DataCrypto`、旧协议 credential store、云表、NAPI、资源或 UI。
2. identity key 固定为 caller 已验证的 `ownerScopeFingerprint + installationId`，经
   domain-separated SHA-256 派生不可逆 alias；原始 owner/UnionID/installationId 不进
   alias metadata、文件名或日志。public API 只返回 version、certificate SHA-256、
   storage mode、opaque local ref、created/rotated time和 stable capability/error，绝不
   返回可复制 private-key bytes、PIN、pair token 或可跨 owner 使用的 handle。
3. 兼容材料固定为 RSA-2048、public exponent 65537、SHA256withRSA、自签名 X.509、
   互操作 CN `NVIDIA GameStream Client`、安全随机正 serial 和约 20 年有效期；生成
   后必须重新解析并验证 key/cert match、算法、位数、subject、serial、时间窗、DER/
   PEM 长度与 certificate fingerprint，任何 partial 结果都先清临时材料再失败。
4. 平台 backend 先探测“不可导出 HUKS RSA 是否可经受控 signer/provider 完成 OpenSSL
   mTLS”；只有真实签名和 handshake-compatible probe 通过才选择 direct-key 模式。
   否则只允许 HUKS AES-256-GCM wrapping key 包裹 PKCS#8：随机 nonce、alias/version/
   owner fingerprint 作 AAD、ciphertext/tag 有界且原子存入安全 backend。Asset Store
   的短 secret 限额不能靠静默截断或多条拼接绕过；若没有可证明的 app-private
   encrypted-blob backend，能力返回 unavailable，严禁明文文件/Preferences/RDB/云
   fallback。
5. OpenSSL 只能获得 move-only、exact alias+generation 的短期 identity lease。
   wrapped 模式在 lease 内解封到不可复制 secure buffer，尽力锁页并记录 capability，
   所有 exit/exception/cancel 路径都以明确不被优化掉的 cleanse 清零 private DER、
   EVP/RSA 临时量和序列化 scratch；certificate public bytes 可单独有界缓存，private
   material 不能进入 exception text、diagnostic snapshot、core dump helper 或测试输出。
6. 每个 alias 只有一个生成/轮换 mutation owner；并发 ensure 复用同一 terminal
   result 或返回稳定 busy，不生成两个身份。delete/rotate 先关闭新 lease admission，
   drain 已发 lease，再删 encrypted blob/Asset metadata/HUKS alias；任一步失败保留
   可重试 tombstone 状态，不能删除 metadata 后留下不可枚举 secret。旧 generation、
   旧 owner、重装后的 installationId 和删除后的迟到 callback 必须零副作用。
7. bridge 提供 owner-scoped inventory/count/delete contract，语义与既有 D3
   `MoonlightIdentityDeletionPort` 对齐，但 N1-05 不新增 ArkTS adapter；N1-08 只能薄接
   这一个 owner。普通 host 删除、单 host unpair 和“重建整个 owner identity”保持
   三个不同命令；轮换前必须能列出受影响 identity/host metadata，不能自动轮换。
8. focused tests 至少覆盖 alias 确定性/域隔离/无原始 ID、RSA/cert golden 与坏随机源、
   owner A/B、installation change、并发 ensure/rotate/delete、lease-drain/timeout、
   backend partial write/rollback、HUKS direct probe false、wrapped tamper/AAD mismatch、
   oversize Asset、wrong owner/ref、枚举孤立项、幂等删除、全部零化路径与日志 canary；
   platform API 用真实 API 23 双 ABI compile-link probe，不能用 fake 结果宣称可用。
9. N1-05 后 production pairing/NAPI/UI 和全部 capability truth 仍为 false。HAP/
   AppSpawn 内 HUKS→OpenSSL runtime receipt 缺失时，允许 secure identity core 形成静态
   checkpoint，但 N1-06 只能做 injected/dormant pairing state machine，真实配对和
   Host Control 继续阻断，绝不以软件明文 key 解锁。
10. 定向与全量 native/ASan、双 ABI严格产品构建、symbol/NAPI/HAP 隔离、双 Hvigor、
    vendor receipt/platform probe、TOTP/Light/diff/state 全通过后单独 checkpoint；任何
    secret 落盘/日志 canary、owner 穿透、未清零路径或旧协议回归都必须停止 N1-05。

#### 15.7.5 N1-05 已完成事实与 N1-06 唯一执行合同（2026-08-10）

N1-05 已由代码 checkpoint `599882ada` 完成。新增实现只有 hidden pure-native
`MoonlightSecureIdentity` core、窄 API 23 platform backend/probe、focused test 与私有
静态归档接线；没有 NAPI/ArkTS/UI、production pairing、云 identity、媒体、输入或
feature truth。alias 固定为 owner fingerprint + installation ID 的 domain-separated
SHA-256，长度精确满足 HUKS 64-byte 上限且不泄漏原值。RSA-2048/65537、
SHA256withRSA、自签 X.509 v3、单一 `NVIDIA GameStream Client` CN、正随机 serial、
约 20 年有效期、PEM LF/PKCS#8 与锁定 Android revision 一致，并在生成/加载后完成
canonical parse、self-signature、key pair、subject/time/fingerprint 验证。

private material 只存在于 move-only secure buffer/lease，尽力锁页、显式记录结果，
退出时 `OPENSSL_cleanse` 后解锁；lease 只提供 SHA256withRSA 签名与 TLS context 配置。
每个 alias 的 ensure/rotate/delete 由 exact `requestId + generation + ownerToken` 串行，
delete/rotate 先关 admission 再 drain；cancel-before-commit、commit-wins、unknown
outcome repair、cross-owner、orphan inventory 和 rollback 都有确定合同。产品平台边界
只证明 API 23 HUKS RSA/AES-GCM 与 Asset metadata symbol 可编译链接，不能证明
AppSpawn 权限、TLS provider、硬件语义或原子 encrypted-blob storage，因此 backend
保持 `RuntimeProofRequired`/unavailable，绝无 plaintext fallback。

14 个 focused case 加入后，沙箱外 native 与 ASan/UBSan 均为 **384/384 PASS**；
strict warning/analyzer、API 23 双 ABI probe、两项 Hvigor、signed HAP、vendor/TOTP/
Light/diff 均通过。两 ABI的 product dynamic defined/undefined/NAPI inventories 与
N1-04 基线逐字一致，签名 HAP 仍是 423 项，每 ABI仍只有 48 个 `rdpnapi`、1 个
private Host API 和 2 个 private identity compile command。HDC 当前为
`Connect server failed`，没有 HAP runtime HUKS、真实 Sunshine、Hypium 或用户实机
receipt。

N1-06 只实现依赖注入且在 signed HAP 中不可达的 native pairing state machine。
wire 事实锁定 Moonlight Android
`f10085f552b367cf7203007693d91c322a0a2936` 的 `PairingManager` 与 N1-04 已冻结的
request builder；不得复制第二套 HTTP/XML/TLS、client certificate、private-key store
或当前-operation singleton。按以下原子步骤逐一执行：

1. 以 `599882ada` 保存 384 项 native、ASan/UBSan、两 ABI
   16103/698/716 与 15634/696/711 symbol inventories、每 ABI 48+1+2 compile
   command 和 423 项 HAP inventory。允许范围优先限定为主 CMake、新建
   `moonlight/pairing/MoonlightPairingManager.h/.cpp`、一个 focused native test 与
   必要 probe/state 文档；若必须改变 N1-04/N1-05 合同，先补失败测试和计划，不在
   pairing 内旁路。
2. public header 只使用 project-owned C++17 value type/PIMPL。每次 pair 固定非零
   `requestId + generation + ownerToken`、owner fingerprint、installation ID、冻结的
   host identity/address candidate 和一次 monotonic absolute deadline；PIN 只能经
   move-only/cleansed secret 输入，不能存入普通 result、exception、event、日志或
   callable capture。迟到 response、trust decision、commit callback 或 cancel 只能
   命中 exact operation key。
3. 状态机固定为 `idle → preflight → waitingForServerCertificate → awaitingTrust →
   clientChallenge → serverChallenge → secretVerification → clientSecret →
   finalChallenge → committing → paired`，并有 `cancelling/failed/cancelled` 终态。
   非法、重复或跨 owner transition fail closed；一个 owner+host 只允许一个 mutation
   owner，并发请求返回 stable busy，不排队、不替换。
4. preflight 必须先证明 injected Host API transport、N1-05 exact identity lease、
   entropy source、trust-decision port 和 atomic local commit/rollback port 全部可用，
   再发任何会改变主机状态的请求。产品 backend 为 unavailable 或 commit port 未注册
   时必须在首包前返回 unavailable；不得远端已 pair 后才发现本地无法保存。
5. PIN 固定四个 ASCII 十进制数字，salt 与 client/server secret/challenge 都由受控
   CSPRNG 各生成 16 bytes。server major version `>=7` 使用 SHA-256；`<7` 的 SHA-1
   只作为明确 legacy compatibility 分支并默认被当前 Sunshine 最低安全版本 policy
   阻断，禁止协商失败后自动 downgrade。pairing wire 的历史 AES-128 block transform
   必须明确标为 protocol-compatible ECB/zero-block-padding，不能与 N1-05 at-rest
   AES-256-GCM 混用或抽成同一个“通用加密 helper”。
6. 第一阶段严格经 N1-04 构造
   `phrase=getservercert&salt=<HEX>&clientcert=<HEX-PEM>` 的未认证 HTTP pair 请求，
   最长只可使用 N1-04 明示的 120s user-PIN budget。只接受唯一 `paired=1` 与有界
   `plaincert` hex X.509；空证书映射 `alreadyInProgress`。证书必须 canonical parse、
   算法/位数/时间/长度有界并计算 SHA-256 candidate，不能在用户 trust 前写 durable
   trust 或把 HTTP candidate 当 authenticated host。
7. `awaitingTrust` 只发布有界的 host label、certificate SHA-256、subject/issuer、
   validity 与变更分类，不发布 DER/PEM 到 UI event；测试注入 accept/reject/timeout，
   production N1-06 没有 UI port。accept 只把 candidate 冻结为本次最终 HTTPS
   challenge 的 TLS pin，reject/timeout 进入 cleanup；任何 host/address/generation
   变化使 decision stale。
8. 严格保持官方线序：`clientchallenge`、`serverchallengeresp` 和
   `clientpairingsecret` 三个 `/pair` mutation 仍走 HTTP；主机尚未完成配对前不能把
   它们臆改为 HTTPS，其协议认证来自 PIN-derived AES、server cert signature 与
   client identity signature。AES key 为所选 hash `Hash(salt || UTF8(PIN))` 的前
   16 bytes。发送 16-byte encrypted client challenge；解密 `challengeresponse` 后
   严格取 `hashLength` bytes server response 与 16-byte server challenge，拒绝奇数
   hex、非 hex、短包、超限、非法 trailing shape。`Hash(serverChallenge ||
   clientCert.signature || clientSecret)` 加密后发送 `serverchallengeresp`。
9. `pairingsecret` 必须是 16-byte server secret 加 server signature；使用 candidate
   certificate 公钥和 SHA256withRSA/ECDSA（按证书 key type）验证签名。随后常量时间
   比较 `Hash(clientChallenge || serverCert.signature || serverSecret)` 与 server
   response；不相等映射 `pinWrong`，签名不对映射 `serverAuthenticationFailed`，两者
   都不得提交 trust。所有 parse/verify 在 bounded scratch 中完成并及时清零。
10. client secret 只经 N1-05 lease 的 `signSha256()` 签名，发送
    `clientpairingsecret=<HEX(secret||signature)>`；不得导出 private key。`paired=1`
    后还必须以 frozen candidate pin 和同一 identity lease 执行官方 HTTPS final
    `phrase=pairchallenge`。每次 mutation 都继承 N1-04 的
    not-sent/maybe-sent/confirmed 事实；maybe-sent 不自动换地址重放。HTTP/XML 200、
    主机 `paired=1` 或请求已发送都不能单独成为本地成功。
11. final challenge 后通过 injected atomic commit port 一次提交 exact owner+host 的
    trust candidate、identity metadata/version 与 paired marker；commit 前再次检查
    account/session generation。commit known-failure 必须清本地 staged state并发起一次
    best-effort unpair；commit outcome unknown 返回 repair-required 并冻结该 host 新
    pair admission，不能伪装 paired 或盲目重试。
12. cancel/timeout/reject/验证失败在第一条 pair mutation 可能发送后都只发一次
    best-effort unpair，并分别报告 local cleanup 与 remote cleanup 的 confirmed/
    unknown/failed；cleanup 失败不阻塞 secret zeroization。析构关闭 admission、取消
    exact operation、等待所有 transport/trust/commit callback drain，不 detach；drain
    超时保持 owner blocked。PIN、salt、AES key、challenge、client/server secret、
    hash、signature assembly 和解密块在所有 success/error/cancel/exception 路径清零。
13. diagnostics/event 只允许 stage、stable code、attempt、HTTP/XML status、duration、
    masked host、certificate fingerprint 和 cleanup truth；禁止 PIN、salt、AES key、
    secret、challenge、signature、完整 query/response、certificate bytes、owner/install
    原值。error strings、fake transport capture 和 test output 必须跑 secret canary。
14. focused tests 至少覆盖官方 SHA-256 golden transcript、明确关闭的 SHA-1 legacy、
    wrong PIN、server signature MITM、空/坏/超长 cert、trust accept/reject/timeout、
    candidate/address change、每阶段 HTTP/XML/hex/length failure、cancel/deadline/stale、
    concurrent pair、maybe-sent no replay、best-effort unpair confirmed/unknown、commit
    rollback/outcome unknown、entropy failure、identity lease unavailable、所有 secret
    cleanse 和日志 canary；用 barrier/condition 和 fake monotonic clock，不用 sleep 猜
    竞态，不把 fake seam 写成 production capability。
15. N1-06 结束后仍不新增 NAPI/ArkTS/UI、真实 trust repository wiring、云、catalog、
    launch、媒体、输入或 capability true。全量 native/ASan、双 ABI strict product/
    probe、symbol/NAPI/HAP 隔离、两项 Hvigor、vendor/TOTP/Light/diff/state 全通过后
    单独 checkpoint；HAP runtime identity 与真实 Sunshine receipt 缺失时状态只能是
    dormant contract pass，不能宣称“可配对”。

#### 15.7.6 N1-06 已完成事实与 N1-07 唯一执行合同（2026-08-10）

N1-06 已由代码 checkpoint `6f7094038` 完成。新增的
`MoonlightPairingManager` 是 hidden、依赖注入、signed-HAP 不可达的 pure-native
状态机；它逐包复用 N1-04 `MoonlightHostApi`，逐次签名/TLS 配置复用 N1-05 exact
identity lease，没有第二套 HTTP/XML、证书生成器、private-key store、NAPI、ArkTS、
UI、云或 capability truth。Host API 仅增加 pure validation 与 pairing wire scratch
清零合同。

实现固定官方线序：`getservercert`、`clientchallenge`、`serverchallengeresp`、
`clientpairingsecret` 四步 HTTP，最后才以 frozen certificate pin 和同一 client
identity 执行 HTTPS `pairchallenge`。Sunshine generation 7+ 使用 SHA-256；SHA-1
必须 caller 显式许可且默认阻断；PIN、salt、AES-128 ECB/zero-padding key、challenge、
client/server secret、hash 与 signature assembly 全部由 move-only secure buffer 管理并
在各终态清零。证书候选做 canonical DER、自签、时间、RSA>=2048/EC>=256、fingerprint
和签名验证，trust event 只有有界 label/subject/validity/fingerprint 与 masked host。

每个 `owner+host` 只有一个 mutation lane；operation key 固定为非零
`requestId+generation+ownerToken`。所有 packet 共用一次 absolute deadline，剩余预算
不足 Host API 100ms 下限时不发包；Host、identity、trust、TLS bind、commit 都有 exact
cancel/drain。maybe-sent 永不重放；失败后最多一次独立 2s best-effort unpair。atomic
commit known-failure 回滚并 unpair，commit/rollback unknown 持久化 repair fence 并冻结
该 lane，late cancel 不覆盖已确认 commit。

15 组 pairing 用例与 16 组 Host API、14 组 identity、13 组 owner 用例共同覆盖官方
SHA-256 transcript、显式 SHA-1、wrong PIN/MITM、空/坏/超长 cert、跨阶段字段、后半段
HTTP/XML/hex/paired failure、trust reject/timeout/stale、deadline 不延长、maybe-sent、
cleanup unknown、rollback/repair、并发/cancel 与 trust/TLS/commit/destructor drain。
沙箱外 native 与 ASan/UBSan 均为 **400/400 PASS**；strict `-Werror` 和三份
`clang --analyze` 为零诊断。最终两项 Hvigor、双 ABI API 23 probe、vendor/TOTP/Light
均通过；`rdpnapi` inventories 仍为 arm64 16103/698/716、x86_64 15634/696/711，
HAP 仍为 423 路径，每 ABI保持 48 个 `rdpnapi`、1 个 Host API、2 个 identity 和
1 个 pairing compile command，pairing command 零 upstream include leak。HDC 仍为
`Connect server failed`，所以没有 HAP runtime identity、真实 Sunshine 或真机配对
声明。

N1-07 只能建立同样 injected/dormant 的 app catalog 与 host-command orchestrator，按
以下原子步骤执行；runtime identity blocker 未解除前仍不得进入 NAPI/UI：

1. 以 `6f7094038` 保存 400 项 native/ASan、双 ABI symbol/NAPI/HAP inventory、
   compile-command 计数和上述门禁为新基线。允许范围优先为主 CMake、新建
   `moonlight/control/MoonlightHostControl.h/.cpp`、一个 focused native test 和状态文档。
2. public header 仍只含 project-owned C++17 value/PIMPL；不得 include common-c、NAPI、
   ArkUI、RDB 或云 SDK。所有 HTTP/XML、scheme、地址 fallback、parser 和 diagnostic
   必须只调用 N1-04，不复制 request builder/parser/transport。
3. 每次 catalog/asset/launch/resume/quit 固定非零
   `requestId+generation+ownerToken`、owner fingerprint、host ID、server UUID、冻结的
   endpoint/pin 和一次 absolute deadline；迟到结果只能 stale/cancelled，析构
   cancel/drain，不 detach。
4. preflight 在首包前验证 Host API、authenticated endpoint pin、client identity/TLS
   transport、caller generation 和所需 command input；product transport/identity 尚
   unavailable 时返回 unavailable，不能通过 HTTP candidate 伪造 paired/catalog truth。
5. catalog 只发 authenticated HTTPS `applist`。结果事务式返回唯一正整数 app ID、
   有界 title、optional HDR、bounded partial count、observedAt 与 generation；一个坏/重
   复 ID 使整批失败。N1-07 不写 `MoonlightAppCacheService`，缓存提交留给 N1-08 ArkTS
   service 的 owner/store lease。
6. app asset 只经 N1-04 `appasset` 获取有界 bytes；N1-07 不猜 MIME、不解码图片、不
   落盘、不把坏封面升级为 catalog failure。asset request 与 catalog generation 不匹配
   时丢弃。
7. 所有 mutation 前先读 authenticated HTTPS `serverinfo`，要求 paired=true、server
   UUID/host generation 未变化，并冻结 `currentgame`；candidate-only HTTP 结果永远不
   能进入 mutation。
8. `launch` 只允许 `currentgame=0`；若同 app 已运行，返回 stable
   `resumeRequired`，若其他 app 运行，返回 `hostBusy`，绝不自动 quit。`resume` 只允许
   currentgame 精确等于目标 app；app ID 失效或状态变化 fail closed。
9. launch/resume 的 `rikey`、`rikeyid` 和流参数只从 caller 提供的 move-only
   `MoonlightLaunchMaterial` 短期消费；本步不生成、不持久化、不日志输出，也不与
   identity secret 混用。query scratch 与 transient RTSP URL 在 transfer/终态后清零。
10. launch/resume 的 2xx 或 request sent 都不是 success；必须先有 N1-04 action
    accepted 和有界 RTSP output，再做 authenticated serverinfo postcondition，只有
    `currentgame==target` 才返回 confirmed。postcheck 超时/坏 XML/状态冲突返回
    outcomeUnknown，不自动重发 mutation。
11. `quit` 必须是用户显式命令，并直接复用 N1-04 已实现的 cancel+authenticated
    `serverinfo/currentgame=0` verification；“仅断开”不调用 Host API quit。主机已 idle
    可返回 idempotent no-op，其他客户端启动的 app 在真实互操作证据前保持 policy
    阻断或二次确认，不靠 fixed uniqueid 猜成功。
12. 同一 owner+host 的 mutation lane 串行；catalog/asset 不得越过正在执行的
    launch/resume/quit 写回旧 generation。不同 host 的 read-only operation 可并行，
    但 mutation 不得建立第二个 process-wide active-session owner。
13. 结果固定区分 `confirmed/failed/outcomeUnknown/cancelled/stale/busy/unavailable`，并
    分开记录 preflight/action/postcondition truth；diagnostic 只含 stage、stable code、
    attempt、HTTP/XML status、masked host、app ID hash 和 byte count，不含 title、地址、
    UUID、rikey、RTSP URL 或 body。
14. focused tests 至少覆盖 complete/partial/empty/duplicate catalog、asset bounds、
    unpaired/pin conflict、launch idle、same-app resume、other-app busy、invalid app、
    launch/resume postcondition、explicit quit/idempotent idle/quit unknown、not-sent retry、
    maybe-sent no replay、deadline/cancel/stale、并发 lane、destructor drain、secret/log
    canary；用 barrier/fake clock，不用 sleep 猜竞态。
15. N1-07 结束仍无 NAPI/ArkTS/UI/cache/cloud/media/input/runtime feature truth。native/
    ASan、strict/analyzer、双 ABI build/probe/symbol/NAPI/HAP isolation、两项 Hvigor、
    vendor/TOTP/Light/diff/state 全通过并单独 checkpoint 后，才允许 N1-08 typed bridge。

#### 15.7.7 N1-07 已完成事实与 N1-08 唯一执行合同（2026-08-10）

N1-07 已由代码 checkpoint `019ed98b4` 完成。新增 hidden、依赖注入且此前无产品
caller 的 `MoonlightHostControl`，只消费 N1-04 `MoonlightHostApi`：authenticated
HTTPS catalog/asset、launch/resume 和用户显式 quit 没有复制 HTTP、XML、TLS、parser
或 secret store。catalog 以 owner+host+server UUID+generation 事务提交唯一正 app ID；
asset 只接受同 catalog generation 的已知 app，且不猜 MIME、不解码、不落盘。

launch 只允许 authenticated `currentgame=0`，同 app 返回 `ResumeRequired`、其他 app
返回 `HostBusy`；resume 只允许 exact app。move-only launch material 和 transient RTSP
scratch 在终态清零；2xx/request-sent 不算成功，必须同时满足 accepted、有效 RTSP 与
authenticated postcondition `currentgame==target`。maybe-sent 或 postcheck 不确定只返回
`OutcomeUnknown`，永不重放。quit 只接受显式确认，复用 N1-04 cancel+idle verification；
主机已 idle 才是 idempotent no-op。“仅断开”仍没有调用 quit 的路径。

同 owner+host 的 read/write lane 有 generation watermark，catalog/asset 不越过 mutation；
不同主机 read 可并行，但全进程同一时刻只有一个 launch/resume/quit mutation。exact
cancel、absolute deadline、析构 drain、preflight/action/postcondition truth 和只含稳定
枚举/状态/计数/app hash 的脱敏 diagnostic 均已固定。26 组新用例使 sandbox 外 native
与 ASan/UBSan 都达到 **426/426 PASS**；strict `-Werror`、Host Control 与测试 analyzer
零诊断。最终两项 Hvigor、双 ABI API 23 probe、vendor/TOTP/Light 均通过；产品动态
inventories 仍为 arm64 16103/698/716、x86_64 15634/696/711，HAP 仍为 423 路径。
每 ABI 有 86 条 compile command：48 条 `rdpnapi`、1 条 Host API、2 条 identity、
1 条 pairing、1 条 Host Control；Host Control 零 upstream include，符号只在 private
archive。HDC 仍为 `Connect server failed`，故没有真实 Sunshine、HAP runtime 或真机
Host Control 声明。

N1-08 只能把已冻结的 N1-03/N1-06/N1-07 合同做成 typed、可取消、代际安全的薄桥；
它不是解封产品 transport/identity、入口或串流的任务。后续模型必须依次完成以下原子
步骤，不得把“导出 NAPI”写成“Moonlight 已可用”：

1. 以 `019ed98b4` 的 426 项 native/ASan、双 ABI dynamic symbol/NAPI/HAP inventory、
   86 条 compile command 和上述门禁作为基线。先盘点 `napi_init.cpp`、唯一发布声明
   `entry/src/main/cpp/types/librdpnapi/index.d.ts`、账户 lease、
   `MoonlightAppCacheService` 和既有 async-work teardown；不得直接扩张
   `ExtensionLoaderNapi` 或通用 `ProtocolAdapter` 承载 pairing/catalog。
2. 允许的主要落点限定为主 CMake、`napi_init.cpp`、新建
   `moonlight/bridge/MoonlightNativeBridge.h/.cpp`、`moonlight/moonlight_napi.h/.cpp`、
   发布 d.ts、`services/MoonlightHostService.ets`、对应 focused native/ArkTS tests 和
   状态文档。`entry/src/main/ets/types/rdpnapi.d.ts` 只有被证明是同一声明的源码镜像时
   才同步；不得顺手整理其他 NAPI 或旧协议。
3. `MoonlightNativeBridge` 是 NAPI-free 的 process owner：持有唯一 production factory
   port、N1-06 pairing manager、N1-07 Host Control 和 async request registry。生产 factory
   在 HAP identity/transport/trust/commit 回执缺失时必须返回 stable
   `runtime_proof_required/unavailable`，并证明零 DNS/socket/TLS/secret/cache 副作用；
   host tests 可注入 fake factory，但 fake capability 绝不编入 release truth。
4. typed request 必须使用不可重绑定的非零 `requestId+generation+ownerToken`，并同时
   携带 owner fingerprint、host ID、server UUID、冻结 endpoint/pin 与 timeout；ArkTS
   service 再绑定完整 `AccountSessionLease(ownerScopeId/storeIdentity/generation/
   storeInstanceId)`。native 不接受 userId、数据库对象、页面引用或通用 username/
   password config，也不从全局 active connection 推断归属。
5. NAPI 导出使用独立 `moonlight*` 前缀，最小闭包只含 capability snapshot、pair、
   catalog、asset、launch、resume、quit、cancel、subscribe/unsubscribe 或等价单一事件
   channel。所有网络/密码学操作在 async work 线程运行；completion 只在 ArkTS 线程
   创建 JS value。不得同步阻塞 UI、不得让 native worker 直接调用页面对象、不得为
   每个操作各建一套线程/handle registry。
6. 入参 parser 必须 exact：拒绝缺失/未知关键字段、错误 JS type、NaN/Infinity、负数、
   超过 JS safe-integer 的 key、越界字符串/数组/ArrayBuffer、重复 app、非法端口和
   timeout；不能用 `napi_get_value_*` 失败后的零值继续。`rikey` 只接受 exact 16-byte
   ArrayBuffer/TypedArray 并立即复制进 move-only native material；PIN、key、RTSP、body
   不进入 exception message、event debug、HiLog 或 analytics。
7. result/event 只暴露冻结的 stable string code、operation/stage/truth、generation、
   monotonic sequence/timestamp、bounded apps/asset/RTSP success payload 和脱敏 diagnostic。
   event 必须至少携带 `requestId+generation+ownerToken`；pair trust candidate 可携带
   计划允许的 fingerprint/subject/validity/masked host，但 PIN 仅属于当前 pair request，
   不进入普通 snapshot。不得把 native enum ordinal 当永久 ArkTS ABI。
8. 每个 request 只有一个 settlement。JS Promise 被 resolve/reject、取消、页面 owner
   dispose、NAPI env cleanup 或账户 barrier 关闭后，先关闭 callback admission，再 exact
   cancel N1-06/N1-07，等待 async work/TSFN/lease drain，最后释放 reference；不得 detach、
   不得 late resolve、新 env 或新 generation 不能收到旧事件。cancel 重复幂等，错误 key
   零副作用。
9. trust review 如果本步形成双向事件，必须由一个 exact-key pending decision registry
   将 ArkTS 的 accept/reject/cancel 回给 N1-06 trust port；超时/页面销毁/account switch
   只能返回 fail-closed，不得默认接受。production identity unavailable 时 pair 必须在
   trust event 前失败，测试 seam 不得伪造 runtime receipt。
10. `MoonlightHostService` 只接受注入的 `MoonlightNativePort`、账户 lease port 与现有
    `MoonlightAppCacheService`。调用前和 Promise/event/缓存提交前后都复核同一 lease 与
    request generation；stale completion 静默丢弃并计数，绝不能写新 owner/store。
    service 不 import 页面、不持有 `UIAbilityContext`、不直接访问 RDB/CloudStore 表。
11. catalog 只有 native `confirmed` 且 `partialAppCount==0` 才转换为现有
    `MoonlightAppCacheEntry` 并调用一次 complete refresh；partial/failed/unknown/stale
    都不把 missing app 标 unavailable。asset 只能更新同 owner+host+app+catalog
    generation 的 local cache/artwork port；app cache 仍不进云、不进备份。缓存失败不
    反写 native Host Control success，也必须以独立 stable code 返回。
12. launch/resume 的 ArkTS 输入只能来自 D1 effective settings 与 native launch-material
    provider；service 不生成弱随机 `rikey`、不持久化 key/RTSP。quit 与 disconnect 保持
    两个命令；Host Service 不提供“断开时顺便 quit”选项，不自动 resume/quit。
13. bridge capability 与六项发布 truth 分离：可以报告 `bridgeCompiled=true`，但 production
    `identityReady/transportReady/hostControlReady/pairingReady` 在 runtime receipt 前全为
    false；`MoonlightFeaturePolicy`、FAB、路由、资源、云注册和设置页不得因 N1-08 改为
    true/可点击。调用不可用桥得到 stable fail-closed result，而不是 crash 或假 success。
14. native focused tests 至少覆盖 exact DTO/bounds、安全整数、ArrayBuffer cleanse、单次
    settlement、async cancel-before-start/during-work/after-result、env cleanup、页面 dispose、
    stale generation、跨 owner、event sequence、trust response、destructor drain、factory
    unavailable 零网络和日志 canary；使用 barrier/fake clock，不用 sleep 猜竞态。
15. ArkTS focused tests 至少覆盖 native port 注入、账户 A 请求→切 B→A 成功/失败/事件
    迟到、storeInstance 重开、complete/partial catalog cache、asset generation、cache
    rollback/error、launch/resume/quit stable mapping、dispose/cancel 幂等、feature truth false。
    若当前 Hypium task 仍未注册，只能声明 compile-registered，不能虚报设备执行。
16. 更新唯一发布 d.ts 后执行类型消费者搜索，保证没有 duplicated drifting declaration；
    HAP/`librdpnapi.so` 允许且只允许计划内新增的 `moonlight*` NAPI surface，必须生成新的
    双 ABI symbol/NAPI baseline，并证明旧 export/undefined inventories 的差异仅来自精确
    allowlist，423 项 HAP path inventory 不因 bridge 偷带资源/上游文件。
17. N1-08 完成时运行 native/ASan、strict/analyzer、ArkTS compile registration、双 ABI
    probe/build/symbol/include/HAP audit、两项 Hvigor、vendor/TOTP/Light/diff/state。独立
    checkpoint 后才能进入 N2-01 stream config；真实 pairing/catalog/launch 和 runtime
    feature truth 仍等待 HAP identity/transport 与 Sunshine 回执，不能由 N1-08 宣称通过。

#### 15.7.8 N1-08 已完成事实与 N2-01 唯一执行合同（2026-08-10）

N1-08 已由代码 checkpoint `aecd2ea4e` 完成；同轮 sanitizer 暴露的既有 deferred-owner
成员初始化竞态以独立 checkpoint `aa3b947` 修复。新增边界严格限定为 NAPI-free
`MoonlightNativeBridge`、独立 `moonlight*` NAPI、唯一发布 d.ts、ArkTS
`MoonlightHostService` 和 focused tests；没有修改 `ProtocolAdapter`、`HostListPage`、
`MoonlightFeaturePolicy`、`CloudSyncPolicy`、媒体、输入、资源、路由或三张 Moonlight
数据表。灰色 FAB 与“即将支持”保持不变，在线云注册仍精确为既有 8 表。

native bridge 固定 exact 非零 `requestId+generation+ownerToken`、owner/host generation
watermark、同 lane duplicate retirement、bounded 256 event queue、exact cancel/cancelOwner、
shutdown cancel/drain 和 PIN/RI key/RTSP 清零。product runtime port 的
identity/transport/trust/commit/pairing/host-control capability 全为 false，所有操作于
DNS/socket/TLS 前返回 `runtime_proof_required`；测试 fake 不进入 release truth。NAPI 只
注册 `moonlightGetBridgeCapabilities`、`moonlightRequestAsync`、
`moonlightCancelRequest`、`moonlightCancelOwner`、`moonlightPollEvents` 五个属性，严格
拒绝未知字段、错误类型、非 safe integer 和越界 binary；worker 不创建 JS value，env
cleanup 先关 admission、取消 async work、再 shutdown/drain。ArkTS service 在调用前、
completion/event/cache 前后复核完整 `AccountSessionLease` 和 store instance；只有
confirmed、complete、零 partial、唯一正 app ID 的目录才提交既有 local app cache，
cache 错误不改写 native truth，launch material 在 NAPI 复制后立即释放并清零。

14 个新增 native case 使全量普通测试达到 **440/440 PASS**；ASan/UBSan 修复成员初始化
顺序后连续三轮均为 **440/440 PASS**。13 个 ArkTS case 使 Moonlight 聚合器达到 20 个
describe、151 个 compile-registered test。bridge/NAPI/test/deferred-owner 四份 analyzer
均零诊断，产品双 ABI strict `-Werror` 通过。arm64 动态 inventory 为
16103 defined / 705 undefined / 716 `napi|init|register`，x86_64 为
15634 / 703 / 711；defined 和 NAPI-filtered 集合与 N1-07 逐项相同，undefined 无删除且
只增加 7 个计划内系统 NAPI import。每 ABI 88 条 compile command 中 48 条仍属于
`rdpnapi`，bridge/NAPI 两条位于 `--exclude-libs` private archive，upstream include leak
为 0；signed HAP 仍为同一 423 路径。最终两项 Hvigor、双 ABI API 23 probe、vendor 三
tree/117 文件、TOTP 251 项和 Light 全通过。HDC 仍为 `Connect server failed`，所以没有
新增 Hypium、HAP runtime HUKS/TLS、真实 Sunshine、真实配对/目录/launch 或 ARM64
实体机声明。

N2-01 只定义“从当前 D1 设置快照到 common-c 可消费 offer 之间”的纯配置合同，不启动
RTSP，不创建 decoder/audio/input，不扩张 NAPI，也不让入口可用。后续模型必须按以下
原子顺序实现，不得把 `offer_ready` 写成“已协商”或“已连接”：

1. 以 `aecd2ea4e` 和 `aa3b947` 为基线，保存 440 项 native/ASan、151 项 ArkTS
   compile registration、双 ABI symbol/NAPI/include 和 423 路径 HAP inventory。允许的
   代码落点只为主 CMake、新建 `moonlight/media/MoonlightStreamConfig.h/.cpp`、新建
   `test/moonlight_stream_config_test.cpp` 及聚合登记；只有发现现有 D1 合同自相矛盾时
   才先停下更新计划，不顺手改 NAPI、Host Service、renderer/audio 或 UI。
2. 新 header 只暴露项目自有 C++17 value types/PIMPL，不 include `Limelight.h`、ArkTS、
   NAPI、OH_AVCodec、OHAudio、页面或数据库。实现进入 hidden/private archive，产品双
   ABI必须实际编译但不产生新动态 export/import；common-c 的
   `STREAM_CONFIGURATION` 数字常量和回调注册只允许在 N2-02 的单一 adapter 中映射。
3. 输入分三份且都不可变：`MoonlightRequestedStreamConfig` 保存 D1 requested 与既有
   adjustment；`MoonlightStreamCapabilitySnapshot` 保存经来源/版本/expiry 验证的 host、
   platform、network/display 能力；`MoonlightStreamConfigIdentity` 保存 owner token、
   session generation、host ID、server UUID、settings revision、host capability generation
   和 platform-probe generation。不得接受 userId、页面对象、地址明文、PIN、RI key、
   RTSP URL、decoder handle 或全局 active adapter。
4. D1 是唯一持久设置真源：N2-01 不重做 global→host→profile→session 合并，不修改
   `MoonlightSettingsPolicy` 的 durable schema，也不把 native adjustment 回写云表。
   native 只做“启动瞬间能力可能已漂移”的第二次 intersection，并把新增 adjustment 以
   stable code 追加；UI 后续同时显示用户 requested、D1 effective 和本次 runtime
   effective，不能只显示最终数字掩盖降级。
5. 当前 `MoonlightSettings` schemaVersion=1 的码率是 1000～200000 的显式
   `bitrateKbps`，不存在 auto sentinel。N2-01 禁止把 0、负数或缺字段解释成自动；未来
   UI 若提供“自动码率”，必须先做独立领域/schema migration。纯 resolver 使用 checked
   arithmetic，保证传给 common-c 的 kbps、FEC 计算和诊断不会溢出 32-bit signed int。
6. 分辨率预设固定映射为 720p=1280×720、1080p=1920×1080、1440p=2560×1440、
   2160p=3840×2160；custom 使用现有 bounded width/height。`host` 表示可信 host
   recommended mode，必须由 capability snapshot 给出；不存在、过期或 generation 不符
   时返回 `host_mode_pending`，不得猜成客户端 viewport、默认 1080p 或 custom 字段。
   最终尺寸必须在 host/device 交集内、为正且满足 codec chroma alignment；任何向下
   对齐或 4K→1080p fallback 都产生显式 adjustment。
7. codec 结果分为 `offeredCodecs` 和 RTSP 后才可能出现的 `selectedCodec`。N2-01 只产出
   offer，`selectedCodec` 必须 absent；H.264 是 MVP 必需 fallback，但只有 HAP 内 decoder
   probe 和 host 同时 supported 才可进入 offer。HEVC/AV1/10-bit/YUV444/HDR 逐 profile
   相交，pending 等价 unavailable。requested=auto 可按已证明优先级给出多个候选；用户
   指定 codec 失效时沿用 D1 的 fail-safe H.264 adjustment；无 H.264 时整体
   `mvp_codec_unavailable`，绝不把空 mask 送入 common-c。
8. 高级组合单独裁决：仅 H.264 时不得接受宽或高超过 4096；HDR 必须同时具备 host
   HDR、显示链、10-bit HEVC/AV1 profile、Surface/PIP 色彩证据；YUV444 必须匹配具体
   8/10-bit profile 和 renderer 证据。关闭 HDR/YUV444 时保留 requested 和 reason，不能
   静默切色域；N2-01 的安全 SDR 输出只能是已证明的 Rec.709/limited 或明确 absent，
   不能复制 Android 平台常量猜 HarmonyOS 色彩能力。
9. `launchRefreshRate`、stream fps 与 `clientRefreshRateX100` 是三个字段：前两者来自
   D1 effective fps 和 host/device 上限，display refresh 只来自当前窗口/显示探针；缺失
   时 `clientRefreshRateX100=0`，不得伪造 60Hz。latencyMode 只作为后续 queue/frame
   pacing policy 输入，N2-01 不改现有 renderer 队列，也不声称 fps 已实际送达。
10. `bitrateKbps` 必须同时受 D1 范围、host encoder、device decode/thermal tier 和
    network budget 上限约束；任一必要上限 pending 时配置只能 `capability_pending`，不能
    用固定经验值冒充实测。高质量音频约 15Mbps 阈值和 common-c 20% FEC 语义仅用于
    checked projection/test，不二次增加 20%，诊断同时保留 configured 与预计 encoder
    budget，避免把两者混为一谈。
11. packet/remote mode 不是用户持久设置。未证明的路径和公网/计费路径有效 packet size
    固定 1024；大于 1024 只在本地路径、地址族、VPN/NAT64 和 MTU receipt 明确后允许，
    并保持 16-byte/encryption overhead 约束。`remote=auto` 只能在 N2-02 由单一网络
    detector 解析；N2-01 记录 unresolved，不复制 Android 1392 或自己再建 RFC1918
    heuristic。计费网络未确认直接返回 `metered_confirmation_required`。
12. audio 只允许 disabled 或已证明的 Opus stereo MVP；5.1/7.1 必须 host、common-c
    multistream、Harmony 输出 route 和 OHAudio channel layout 同时通过。输出同时包含
    project-owned layout 与 launch 所需 surround semantics，但 N2-02 才映射官方
    `AUDIO_CONFIGURATION_*`；`playOnHost` 保持用户意图。audio disabled 的 common-c
    discard/no-audio callback 路线未证明前标记 pending，不以 stereo 占位宣称已静音。
13. encryption 输出是 policy requirement，不是已协商事实：remote input 永远要求 exact
    ephemeral key/IV；`required` 必须等待 host/common-c 对目标 data streams 的证明并在
    缺一项时阻断，`compatible` 也不得关闭 remote-input protection，`auto` 保留候选。
    N2-01 类型禁止携带 key/IV；N2-02 在 owner lease 内最后注入并在 start/失败/stop 清零。
14. resolver 一次性产出同源的 `effectiveStreamOffer` 与 `launchProjection`，width/height/
    launch fps/HDR/audio layout/playOnHost 必须逐字段一致；不得由 Host Service 和
    common-c adapter 分别再算一遍。controller bitmap、persist gamepad 和 input key material
    在 N3 前固定安全零/false，不能由 stream config 猜测实体手柄。
15. result 状态至少区分 `invalid_request`、`capability_pending`、`confirmation_required`、
    `offer_ready`、`rejected`；adjustment 使用 bounded stable field/code/requested/effective，
    不含本地化文案和敏感值。只有 N2-02 收到合法 RTSP/renderer selection 后才能生成
    `negotiated`，只有 decoder 首帧后 D1 session state 才能进入 streaming。
16. resolver 必须 deterministic、无时钟/网络/线程/global state；capability expiry 由调用方
    传入单调时刻后判定。相同 identity+input 得到 byte-equivalent result；任一 owner、
    session、host/server UUID、settings/capability generation 变化都要求重新 resolve，旧
    offer 不得用于 launch 或连接。
17. focused tests 必须覆盖全部预设/custom/host-pending、奇数尺寸、边界/溢出、H.264
    MVP、forced/auto codec、4K fallback、HDR/10-bit/YUV444 组合、fps/display 三字段、
    bitrate/FEC 上限、local/remote/IPv6/NAT64 packet、计费确认、audio disabled/stereo/
    surround、encryption 三模式、stale generations、launch/stream projection 一致、
    adjustment 稳定性和 deterministic property/fuzz corpus；不以 sleep 或真实网络测试纯函数。
18. 完成时重跑普通 native 与 ASan/UBSan、strict/analyzer、双 ABI compile/symbol/include/
    HAP isolation、两项 Hvigor、platform probe、vendor/TOTP/Light/diff/state。defined/NAPI
    集合、7 个 N1-08 NAPI import allowlist和 423 路径 HAP 必须保持不变；新增配置源码只
    能作为 private command 出现。独立 checkpoint 后 N2-02 才能建立唯一 common-c
    adapter/RTSP callback owner，且产品 capability truth 仍不得因纯配置合同变为 true。

#### 15.7.9 N2-01 已完成事实与 N2-02 唯一执行合同（2026-08-10）

N2-01 已由代码 checkpoint `db5865c53` 完成。新增
`MoonlightStreamConfig.h/.cpp` 只暴露 project-owned C++17 值类型，在 private/hidden
archive 中被 arm64-v8a 与 x86_64 产品命令实际编译；没有 include `Limelight.h`、NAPI、
ArkTS、OH_AVCodec、OHAudio、页面、RDB 或云 SDK，也没有运行时 caller。resolver 对
requested、D1 effective、既有 adjustment、owner/session/host/settings generation 以及
host/platform/network/display 四类带 source/version/expiry 的 capability snapshot 做一次
确定性交集，同时生成同源 launch projection。结果严格区分 invalid、pending、confirmation、
offer-ready 与 rejected；`selectedCodec` 在所有 N2-01 路径都 absent。

36 个 focused native case 覆盖固定预设、host/custom、奇数与越界尺寸、H.264 MVP、
forced/auto codec、HDR/10-bit/YUV444、fps/display/launch 三字段、bitrate/FEC、local/remote/
IPv6/NAT64 packet、计费确认、audio disabled/stereo/surround、三种 encryption、stale
generation、adjustment、同源 projection 和 deterministic/malformed corpus，使全量测试达到
**476/476 PASS**，ASan/UBSan 连续三轮也为 **476/476 PASS**。strict `-Werror` 与 analyzer
零诊断；每 ABI 由 88 条增至 89 条命令且只增加 1 条 stream-config command，48 条
`rdpnapi` 命令不变。两 ABI defined/undefined/NAPI inventories 仍精确为 arm64
16103/705/716、x86_64 15634/703/711，与 N1-08 逐项相同；signed HAP 仍为 423 路径，
SHA-256 为 `095700a5af1823645689d913b4c995f5cca662eafa6202fec12b0eb68156a0ac`。
两项 Hvigor、API 23 双 ABI probe、三棵官方 Git tree/117 文件、TOTP 251、Light、diff
均通过。在线 `CloudSyncPolicy` 仍精确 8 表，`HostProtocolPicker` 中 Moonlight 仍为
disabled 并显示“即将支持”，所有 feature truth 仍 false。当前 HDC `list targets` 无输出，
人工中断后退出；本 checkpoint 不声明 Hypium、HAP runtime、真实 Sunshine 或实体机通过。

N2-02 只把 N2-01 的 offer 映射进当前锁定
`moonlight-common-c@e41355ea01670fd4c830b384009d31dd0339a705` 的公共 C API，
并把其 process-global、non-thread-safe 的 start/interrupt/stop 与 callback 生命周期收束到
既有 `MoonlightSessionOwner`。官方 `Limelight.h` 明确 `LiStartConnection()` 非线程安全，
`LiInterruptConnection()` 后必须等原 start 返回才能开始下一连接；`Connection.c` 又持有
全局 `StreamConfig/ListenerCallbacks/VideoCallbacks/AudioCallbacks/NegotiatedVideoFormat`。
因此不得为 RTSP、媒体或输入再创建平行 active-session owner。后续模型必须按以下原子
顺序执行，一次只完成这个 dormant native 边界：

1. 以 `db5865c53` 保存 476 项 native/ASan、151 项 ArkTS compile registration、两 ABI
   89/48 command、symbol/NAPI/include 与 423 路径 HAP 基线。允许修改的代码范围只为主
   CMake、新建 `moonlight/media/MoonlightCommonCAdapter.h/.cpp`、新建
   `test/moonlight_common_c_adapter_test.cpp` 及必要聚合登记；如确需改
   `MoonlightSessionOwner` 或 `MoonlightHostControl`，必须先用失败测试证明现有合同无法
   表达的 exact lifecycle/secret handoff，并在本计划中记录最小增量。当前已识别的唯一
   owner 缺口是 deadline 线程不能安全调用 blocking `stop()`；先以失败测试证明，再只加
   exact-key、non-blocking、与 `stop()` 共用状态转换的 `requestStop()`。禁止顺手改 NAPI、
   ArkTS service、renderer/audio/input、UI、数据或旧协议。
2. adapter header 只暴露 project-owned C++17 request/result/event/PIMPL，不 include
   `Limelight.h`。仅 `.cpp` 的单一 translation unit 可见 `SERVER_INFORMATION`、
   `STREAM_CONFIGURATION`、callback structs、`VIDEO_FORMAT_*`、`AUDIO_CONFIGURATION_*`、
   `ENCFLG_*` 与 `Li*`；所有官方数字映射集中在这里并有 compile-time/asserted golden
   tests，其他源码不得复制 common-c mask。
3. request 在 admission 前只携带非零 `sessionId+generation`、独立命名的 account owner
   token、N2-01 identity/canonical offer、host/server generation、masked endpoint 的实际
   连接地址、appversion、optional
   GFE version、server codec mode、RTSP session URL、absolute overall deadline 和每阶段
   deadline。不得接受 userId、页面/JS value、数据库对象、可变全局设置、PIN、证书私钥、
   任意 query/body 或 decoder handle；request 入 owner 后不可重绑定。
4. 新建 move-only、不可复制的 `MoonlightRtspLaunchLease`，只在一次 launch/resume 与一次
   start 间携带 exact 16-byte RI key、signed 32-bit `rikeyid`、RTSP URL 和对应 account
   owner/session/host/settings generation；它只能在 driver.start 中从
   `StartContext.key()` 一次性绑定 N1-03 生成的 `MoonlightSessionKey.ownerToken`，两个
   owner token 不得复用字段名或相互推导。当前 N1-08 会把 RI key 作为 ArkTS 输入再立即
   清零，不能作为最终产品密钥所有权；N2-02 仍不扩 NAPI，product wiring 前必须把随机
   生成、launch query 与 adapter 消费收回同一 native session owner。官方 Moonlight
   Android `NvConnection`（已锁定 `f10085f552b367cf7203007693d91c322a0a2936`）使用
   128-bit AES key、随机 signed int key ID，并以 Java 默认 big-endian
   `ByteBuffer.allocate(16).putInt(rikeyid)` 构造 IV；为正/负/边界 key ID 建 16-byte
   golden vector，禁止 native-endian `memcpy`。
5. `STREAM_CONFIGURATION` 必须先调用 `LiInitializeStreamConfiguration()`，再逐字段映射
   N2-01 effective offer：width/height/fps/bitrate/packet、resolved local/remote（永不传
   `STREAM_CFG_AUTO`）、audio layout、offered profile mask、display refresh、color、
   encryption flags；最后复制 RI key/IV。所有 int 转换 checked，packet 已是 16-byte
   对齐，H.264/10-bit/444/profile mask 与 offer 一一对应，空 codec mask 或 unknown enum
   在 `LiStartConnection()` 前失败。
6. `SERVER_INFORMATION` 必须先调用 `LiInitializeServerInformation()`；address、appversion、
   GFE version、RTSP URL 的 backing storage 由 invocation 持有到 stop/drain 完成，不能
   指向临时 `std::string::c_str()`。`serverCodecModeSupport` 只能来自同 generation 的
   authenticated host capability，不从 offered mask 反推。RTSP URL 只允许受限 scheme/
   长度/端口形态且永不进入日志、事件或崩溃诊断。
7. 因 connection/video/audio callbacks 多数没有 context 参数，adapter 只能有一个
   process-global callback routing slot；该 slot 不是第二个 session owner，只能由
   `MoonlightSessionOwner` accepted key 安装。slot 保存 invocation weak/shared state 与
   exact key，高水位阻止旧 generation 重入；安装、读取、退休在一把窄 mutex 下完成，
   不持锁调用 common-c 或下游 callback。旧 slot 完全退休前绝不安装新 slot。
8. adapter 的 `start()` 只构造一份 `MoonlightSessionOwner::Driver`：driver.start 先用
   `StartContext.key()` 一次性绑定 invocation/launch lease 并安装 router，再唯一调用
   `LiStartConnection()`；driver.interrupt 唯一调用 `LiInterruptConnection()`，driver.stop
   唯一调用 `LiStopConnection()`。首个合法 `stageStarting` 回调必须立即调用
   `StartContext.markInterruptible()`，从而关闭 cancel-before-first-stage 的 lost-cancel
   窗口；禁止在调用 `LiStartConnection()` 前盲调 interrupt，也禁止 adapter 自建并行
   start semaphore/active pointer。
9. stage callback 映射使用 project-owned enum，精确覆盖官方 1～11：platform、name
   resolution、audio init、RTSP handshake、control/video/input init 与 control/video/audio/
   input start。状态机只接受 `starting(S) → complete(S)` 或 `starting(S) → failed(S)`，
   stage 单调前进；duplicate、reverse、unknown、complete-without-start 都置 protocol
   violation 并请求 interrupt。仅在 0～11 范围内才可调用 `LiGetStageName()`，用户文案
   后续由 ArkTS stable code 本地化，不能把上游英文当永久 ABI。
10. 每个 adapter 只有一个 joinable deadline scheduler，等待 injected monotonic clock/
    condition variable 上当前 exact key 的 overall 或 stage deadline；它不持有 invocation
    强引用，超时只调用 N1 owner 的 non-blocking `requestStop(key)`，由 owner 唯一 control
    lane 决定 interrupt/stop，不直接并发调用 common-c API。正常终态清除登记；adapter
    析构先确认无 active owner，再停止并 join scheduler，不 detach、不用 sleep 猜时序。
    timeout、user cancel、account drain、host generation 失效使用同一状态转换。
11. `DecoderRendererSetup(videoFormat, width, height, redrawRate, context, flags)` 是唯一
    negotiated video profile 来源。只接受一个已 offered 的官方 exact profile bit，且尺寸/
    refresh 与 effective offer 相容；然后产出 project-owned selected codec/profile 快照。
    多 bit、unknown、未 offered、10-bit/444/HDR 不一致或 media port 拒绝立即失败。不得读
    common-c internal `NegotiatedVideoFormat`，也不得在 RTSP stage complete 时提前声称
    negotiated。
12. `AudioRendererInit(audioConfiguration, opusConfig, ...)` 是唯一 negotiated audio 来源；
    验证 0xCA magic、channel count/mask、sampleRate/streams/coupledStreams/samplesPerFrame/
    mapping 边界及 N2-01 offered layout。N2-06 前 product audio port 不 ready 时 setup
    必须失败；测试 fake 可证明 stereo/surround mapping，但不能改变产品 capability truth。
13. N2-03/N2-06 前不实现 payload 管线。video submit、audio sample、start/stop/cleanup
    callbacks 只转发给 injected readiness-aware media ports；product 缺 port 时在 setup/init
    阶段 fail closed，绝不默默丢 payload 后报告连接成功。callback 入口先从 router 获取
    exact invocation，再获取 `MoonlightSessionOwner::AdmissionLease`；stale/cancelled/closed
    admission 只安全丢弃并计数，绝不触达新 session。
14. connectionStarted 只表示 common-c transport stages 已建立，不能令 D1 进入
    `streaming`；只有 N2-03/04 decoder 提交并确认首帧后才允许。connection status/HDR
    callback 形成 bounded stable event；rumble、motion、LED、adaptive trigger 在 N3 前
    保持 disabled/no-op 并不得声称输入支持。上游 variadic log callback 进入固定长度脱敏
    sink，地址、RTSP、key、UUID、媒体 payload 以 canary 测试证明不会外泄。
15. start 非零返回、stageFailed、connectionTerminated、media setup failure、deadline 与
    cancel 都映射为单一 terminal result；保存 project code、mapped stage、raw bounded
    error、port flags 和 sequence，不保存完整 endpoint。上游 `Connection.c` 的 termination
    callback 可能从 detached thread 到达，adapter callback lease 与 router retirement
    fence 必须保证 stop/析构后无 UAF、无 late terminal、无旧事件投递。
16. stop 顺序固定为：关闭新 callback/media admission → 清除 deadline 登记 → 标记
    cancellation → starting 时 interrupt、running 时 stop → 等 `LiStartConnection()` 返回 →
    等 common-c stop/cleanup 与所有 callback/worker lease drain → 退休 router slot → 清零
    secret/config/string backing → 释放 owner。scheduler 只在 adapter 析构
    且无 active invocation 时 join；重复 stop 幂等，错误 key 只返回 stale，绝不停止新 owner。
17. RI key、IV、signed key ID scratch、RTSP URL 与包含它们的 `STREAM_CONFIGURATION`
    在 start failure、interrupt、normal stop、external termination、deadline、account drain、
    exception 和析构全部显式 cleanse；move-from 对象也归零。测试提供 cleanse counter 和
    secret/log/event canary；key/IV 不进入 canonical result、云表、备份、diagnostic 或 NAPI。
18. result/event 至少区分 invalid、busy、runtime-proof-required、starting、stage-progress、
    negotiated、transport-ready、cancelled、timeout、terminated、failed、stale；所有事件带
    exact key、monotonic sequence、stage 和 generation。`negotiated` 必须同时包含经 setup
    验证的 selected video profile及实际 audio layout；`transport-ready` 仍不是 first-frame、
    running UI 或 release-ready。
19. focused tests 使用 injected common-c driver/callback harness、fake clock、barrier 和
    property corpus，至少覆盖全部字段/mask golden mapping、big-endian RI IV、string lifetime、
    owner busy、cancel-before-first-stage/during-each-stage/after-start、stage 乱序/重复/unknown、
    setup selected codec、audio Opus shape、media-not-ready、callback stale/late、termination
    thread、deadline、stop idempotence、exception、destructor drain、cleanse/log canary；不连
    真实网络、不依赖 sleep。另做锁定 common-c 的 compile-link smoke，证明 production
    `.cpp` 实际调用官方初始化与 start/interrupt/stop，而不是测试 fake-only 实现。
20. 完成时重跑普通 native 与连续三轮 ASan/UBSan、TSan 可用环境或等价 deterministic
    race harness、strict/analyzer、双 ABI compile/symbol/include/HAP isolation、两项 Hvigor、
    platform/vendor/TOTP/Light/diff/state。不得新增 NAPI export/import、HAP path、云表、路由、
    UI 资源或 feature truth；独立 checkpoint 后唯一下一任务才是 N2-03 video decode-unit
    bridge，N2-04 首帧前仍不得把 FAB、streaming/protocol truth 改为 true。

#### 15.7.10 N2-02 已完成事实与 N2-03 唯一执行合同（2026-08-10）

N2-02 已由代码 checkpoint `248e704ab` 完成。新增实现只有一个 hidden/private
`MoonlightCommonCAdapter` archive、EXCLUDE_FROM_ALL 官方 link probe、20 个 adapter
focused case，以及先由失败测试证明后给既有 `MoonlightSessionOwner` 增加的 exact-key、
non-blocking `requestStop` 与 1 个 focused case；没有 NAPI、ArkTS、UI、云表、renderer、
audio player 或 input caller。adapter public header 只含 project-owned C++17 类型，唯一
`.cpp` 才 include 锁定 `Limelight.h`，官方 stage/mask 由 static assert 与 golden vectors
锁定。product driver 初始化全部 common-c struct/callback，唯一调用 start/interrupt/stop；
product media port 仍 unavailable，因此真实 start 在网络前返回 runtime-proof-required。

launch lease move-only 地绑定 account/session/host/settings generation 与 owner accepted key，
128-bit RI key、signed key ID、big-endian 16-byte IV 和 RTSP backing 在 invalid、failure、
cancel、deadline、termination、exception、normal stop 与析构路径全部 cleanse。process-global
router 不是第二 owner，只保留 weak invocation/exact key/owner-token high-water；回调不持
router 锁进入 common-c 或 media，owner admission 加本地 callback fence 保证 finalization
等待异步 media/lifecycle callback 后才退休 router 和清秘密。单 joinable scheduler 不持
invocation，只向 owner 投递 requestStop；析构不 detach、不 sleep 猜测时序。

11 个官方 stage 只接受严格 starting→complete/failed 单调序列，首个 platform stage 关闭
cancel-before-first-stage 窗口；unknown/duplicate/reverse、stage failure、deadline、external
termination 和 driver exception 都形成单一 bounded terminal。video setup 与 Opus audio init
是 negotiated 的唯一真值，精确验证 offered profile、尺寸/刷新率、0xCA audio layout 与
stereo/5.1/7.1 mapping；transport-ready 仍令 `firstFrameReady=false`，不能进入 D1
streaming。payload 仅经 injected lease-fenced media port；N2-03/N2-06 前 product port 不可用。

验证结果：普通 **497/497**，ASan/UBSan 连续三轮 **497/497**，strict `-Werror`、四份
analyzer 和 async blocked-callback/termination/destructor deterministic race harness 通过。
TSan 可构建，但全量运行在进入 Moonlight 前停于既有 RustDesk continuity timing assertion，
此前无 ThreadSanitizer/race 输出，不宣称全量 TSan PASS。两 ABI 官方 adapter link probe、
两项 Hvigor、platform probe、三 tree/117 文件、TOTP 251、Light、diff 全通过。每 ABI
90 条 command 中 `rdpnapi` 仍 48、adapter 仅 1，零 upstream include leak；defined/
undefined 与 147-entry NAPI ABI 子集逐项等于 N2-01 基线。signed HAP SHA-256
`3d67e3a743207d39df8e4bb81ba7f49efd7acd8896f412000defc6670af05578`，423 路径
零变化。在线云注册仍 8 表，FAB 灰色“即将支持”和 11 个 false feature inputs 不变。
第二个允许的 `gpt-5.6-sol low` reviewer 只读审查 `49735f1a1..248e704ab` 后 PASS、无
P0/P1/P2；后续阶段必须复用既有 reviewer task ID，不得创建第三个实例。

N2-03 只能按以下原子顺序执行，不回开 N2-02 的 router/owner/stage/secret 边界：

1. 先保存 `248e704ab` 的 497 项普通/ASan、两 ABI 90/48/1 command、symbol/NAPI/include、
   423-path HAP、双 Hvigor 和 truth 基线。代码范围优先限定为主 CMake、新建
   `moonlight/media/MoonlightVideoBridge.h/.cpp` 与 focused native test；公共 decoder 若无
   失败测试证明现有 generation/ownership 合同不足不得修改。
2. bridge 输入必须是只在 callback lease 内有效的 `DECODE_UNIT` view；立即校验非空链、
   `fullLength`、entry 数量、每项 `length/data`、整数溢出、buffer type、frame type、
   `frameNumber` 与 codec profile。锁定 common-c 的 `LENTRY` 没有 offset 字段，
   `DECODE_UNIT` 也没有 decodeNumber；offset 只能由本地按链顺序计算。设置单 frame/单
   entry/总 payload 有界上限，任何
   malformed、cycle、截断、重复 config 或长度不一致在读 payload 前 fail closed。
3. 不把 LENTRY 首指针当连续 buffer。按链顺序建立 project-owned immutable fragment view；
   只有下游需要连续 Annex-B/access unit 时才在有界 owner buffer 中一次组装。明确复制与
   borrowed 生命周期、allocation/backpressure 结果，回调返回后绝不保存 upstream pointer。
4. 区分 codec configuration、IDR/reference/non-reference frame 与 unknown。H.264 保存并
   限界 SPS/PPS，HEVC/AV1 只冻结结构合同且 feature truth 继续关闭；config generation 与
   exact session/codec generation 绑定，旧 config/frame 不得进入新 session。
5. 输出只允许 stable `accepted/drop/need-idr/backpressure/malformed/stale/unsupported`
   truth、bounded metadata 和 owned payload lease；不得携带 endpoint、RTSP、RI key、原始
   payload 到日志/事件/NAPI。drop/backpressure 与 malformed 分离，只有可恢复丢失才请求
   IDR，避免 malformed 输入触发无界 keyframe storm。
6. N2-03 只提供 injected decoder sink fake 与 dormant product unavailable sink，不调用
   OH_AVCodec、Surface、现有 renderer 或 ArkTS。N2-04 才可在失败测试保护旧协议后，把
   owned access unit 接入现有 generation-aware decoder owner；不得创建 Moonlight 私有
   第二 decoder singleton/thread pool。
7. teardown 顺序为关闭 submit admission→等待 in-flight bridge lease→清 config/payload
   owner buffers→释放 session generation；旧 callback、重复 stop、sink exception、析构中
   blocked submit 都必须有 deterministic barrier 测试，不 detach、不 sleep 猜时序。
8. focused tests 至少覆盖单/多 LENTRY、config+IDR、fragment 顺序、本地计算的
   offset/fullLength、空/cycle/过长/溢出/截断/unknown type、frame number 边界、stale generation、
   backpressure/need-IDR、sink exception、blocked submit teardown、payload/log canary 和
   deterministic malformed corpus；普通/三轮 ASan、strict/analyzer、TSan 或等价 race
   harness、双 ABI/HAP/NAPI/include、双 Hvigor、vendor/TOTP/Light/diff/state 全通过后
   单独 checkpoint。N2-04 前 first-frame/streaming/protocol truth 必须继续 false。

#### 15.7.11 N2-03 已完成事实与 N2-04 唯一执行合同（2026-08-10）

N2-03 已由代码 checkpoint `34d2ffa7a` 完成。新增 hidden/private
`MoonlightVideoBridge`、项目自有 borrowed view/owned access-unit DTO、一个 dormant
unavailable product sink 和 8 个 focused case；N2-02 adapter 的唯一 `.cpp` 同步把官方
`PDECODE_UNIT/LENTRY` 投影到固定 64 项 project view，header、bridge 和测试都不暴露
`Limelight.h`。单 fragment、单 AU、codec config 上限分别为 4 MiB、16 MiB、1 MiB；
`fullLength`、cycle、数量、长度加法、type、frame/profile/time/colorspace 和 H.264/HEVC/AV1
锁定链形状在复制前 fail closed。callback 返回前完成连续 owned bytes 与本地 fragment
offset 复制，绝不保留 upstream pointer；H.264 保存 SPS/PPS，HEVC 保存 VPS/SPS/PPS，
AV1 只接受 picture data。config generation 只在新的 accepted IDR 内容变化时增长。

bridge 复用 N1-03 的 exact `MoonlightSessionKey` 和 owner-token high-water，不创建线程池或
第二 session/decoder owner。submission 串行化；P frame 在 accepted IDR 前、sink
backpressure/need-IDR 后保持 gated，IDR 请求按 invocation 合并，accepted IDR 才重新打开。
stop 先关闭 admission，再有界等待 in-flight；timeout 后仍保持关闭，后续 stop 可完成 drain，
析构等待最后 lease。product sink 永远 unavailable，`firstFrameReady` 硬保持 false；无
OH_AVCodec、Surface、NAPI、ArkTS、UI、云、音频或输入 caller。

验证结果：普通、strict `-Werror` 与完整 TSan 均 **506/506 PASS**；ASan/UBSan 连续三轮
**506/506 PASS**，scan-build 全目标零报告。两 ABI 产品和 adapter link probe 通过；每 ABI
91 条永久 command 中 `rdpnapi` 仍 48、adapter 1、video bridge 1。arm64
16103/705、x86_64 15634/703 的 defined/undefined 集合及各 147 条 NAPI 子集与 N2-02 基线
逐项一致。两项 Hvigor、API 23 双 ABI platform probe、三 tree/117 文件、TOTP 251、Light、
diff 均通过；signed HAP SHA-256
`d5311acdf2d8e02385cf7bf2d33bd737e971584058b0c90d9ef7c1a0bfa9d045`，423 路径不变。
在线注册仍精确 8 表，FAB 只有一个 disabled Moonlight 和一个“即将支持”；11 个 feature
input 默认 false，平台能力默认 11 pending/1 unsupported/0 supported。两个 reviewer 实例此前
均已建立，本 checkpoint 只有完整机器门禁与逐文件自审；后续复用既有 task ID，不伪造审查回执。

N2-04 只能按以下原子顺序执行；不得回开已经冻结的 common-c router、bridge ownership、
云模型或 UI：

1. 以 `34d2ffa7a` 保存 506 项普通/ASan/TSan、两 ABI 91/48/1/1 command、symbol/NAPI、
   423-path HAP、双 Hvigor和 8 表/灰入口/全 false truth 基线。先为现有 RDP/RustDesk/VNC
   decoder owner、display、Surface bind/rebind、teardown 和 keyframe recovery 补失败回归；
   公共 `hw_decoder` 改动必须由这些测试证明且不得改变旧协议结果码或锁顺序。
2. 新增一个窄的 project-owned Moonlight decoder sink/port 实现文件；只有该实现可 include
   `render/hw_decoder.h` 和平台媒体头。`MoonlightVideoBridge` 继续只认识 owned AU 与抽象
   sink，不 include NAPI/OH_AVCodec/Surface。不得复制 `HardwareDecoder`、registry、
   `SharedSessionSinkOwnerLease`、renderer owner、callback gate 或 retire owner。
3. decoder start request 必须携带 exact Moonlight key、映射后的 `DecoderSessionIdentity`、
   negotiated profile、width/height、renderer handle、surface/display generation 和 runtime
   proof。任一值 absent、owner lease 不接受、active owner/handle 不匹配、renderer 已被别的
   协议占用或平台 capability 未证实时，必须在创建 codec/网络继续前返回 unavailable/stale；
   不得调用 `SetActiveSessionId/SetActiveDisplay` 抢占旧协议全局 owner。
4. 若公共 API 缺少 pure-native exact-owner create/decode/detach/destroy，先用测试冻结后只加
   最窄 overload，并内部复用既有 registry generation、callback identity-before-start、
   `BindVideoPipeline`、pipeline transition mutex、deferred retire 和 shared sink lease。
   禁止把内部 handle 暴露到 ArkTS/NAPI，也禁止建立 Moonlight 私有 active pointer。
5. MVP 只启用 runtime-proven H.264 8-bit 4:2:0；HEVC/AV1/HDR/YUV444 继续返回
   unsupported/pending。把 accepted owned AU 的连续 Annex-B bytes、`presentationTimeUs`、
   IDR flag、negotiated dimensions 和 codec 精确投影为现有 `VideoFrame`；配置必须随 IDR
   同一 AU 提交。config generation 改变时只在新 IDR 上 flush/recreate，旧 generation AU
   不得进入新 codec。
6. 把现有 decoder admission 结果翻译为 stable sink truth：成功才 `Accepted`；pipeline
   busy/queue pressure 为 `Backpressure`；hardware/software keyframe-required 为 `NeedIdr`；
   owner/display/generation 不匹配为 `Stale`；capability 不满足为 `Unsupported`；平台错误为
   `Failed`。不得把通用 `-1` 猜成成功，也不得在持有 decoder/pipeline/owner 锁时进入
   common-c 或调用 IDR 请求。
7. `submit accepted`、`OH_VideoDecoder_PushInputBuffer` 成功和 output callback 都不是单独的
   首帧证据。只有 exact key/generation 的 output buffer 成功交给 NativeImage、
   `UpdateSurfaceImage` 成功且 renderer owner 接受该纹理后，才能发布一次 first-frame receipt；
   Surface absent/rebind/teardown、旧 callback 或仅 telemetry 增长均保持 false。若现有 void
   render callback 无法证明接受，N2-04 必须新增 project-owned ack seam，而不能推断。
8. teardown 固定为 bridge close admission→decoder sink close→停止 frame/error callback
   admission→detach renderer/Surface→等待 codec/image/render worker lease→destroy registry
   handle→清 config/first-frame receipt；blocked submit、late input/output/frame callback、
   callback 中 stop、重复 stop、Surface rebind 和 owner replacement 必须确定性通过，不
   detach、不 sleep 猜测。
9. product wiring 仍不得经 NAPI/UI 启动；只有 HAP/AppSpawn API 23 的 H.264 decode、
   NativeImage/renderer first-frame 与 teardown probe 都有 receipt，product sink 的
   `available()` 才可针对该 exact profile 返回 true。N2-04 checkpoint 后 FAB、云表、
   `streaming/protocolAvailable` 仍 false；N2-05 才处理 Surface 缺失/PIP/后台策略。
10. focused tests 必须覆盖 exact-owner create/bind/decode/detach/destroy、H.264 config+IDR、
    P-before-IDR、config generation recreate、queue pressure/IDR 合并、旧 owner/display/surface
    generation、renderer 拒绝、output/NativeImage/renderer ack 三段首帧、blocked callbacks、
    20 次 rebind/teardown 和旧协议全量回归。普通/三轮 ASan、完整 TSan、strict/analyzer、
    双 ABI/HAP/NAPI/include、双 Hvigor、vendor/TOTP/Light/diff/state 全通过后单独 checkpoint。

#### 15.7.12 N2-04 已完成事实与 N2-05 唯一执行合同（2026-08-10）

N2-04 已由代码 checkpoint `bee0ac1da` 完成。新增内容是一个 NAPI-free、hidden/private 的
`MoonlightOwnedVideoDecoderSink`、一个只在 OHOS 产品目标编译的
`MoonlightHardwareDecoderPort` 和 9 个 focused case；静态 archive 私有链接到 `rdpnapi`，
但产品没有 factory caller、NAPI/ArkTS 路由或会话协调器。bridge 继续不 include
`hw_decoder`、NAPI、Surface 或平台媒体头，只在 accepted IDR 上提交 prospective codec
configuration generation；sink/port 才把 owned Annex-B AU 投影为现有 `VideoFrame`。

start 必须同时匹配 exact `MoonlightSessionKey`、既有 `DecoderSessionIdentity`、active decoder
handle/generation、display/generation、renderer handle/generation、H.264 8-bit 4:2:0、尺寸、
handle ownership 和显式 runtime proof。port 只读取既有 active owner，不调用
`SetActiveSessionId`、`SetActiveDisplay`，也不创建第二 decoder registry、renderer owner、
callback gate、线程池或 retire lane。HEVC/AV1/HDR/YUV444 仍不支持。配置变化仅在携带新
SPS/PPS 的 IDR 上触发现有 recovery/recreate；返回的新 decoder generation 必须与除 decoder
generation 外完全相同的 binding 原子提交，任何非精确重绑都会永久关闭该 sink admission。

公共 decoder 只增加 hidden typed exact-owner seam：queue pressure、pipeline transition、
need-keyframe、stale generation 和 platform failure 不再由通用 `-1/0` 猜测；既有
`Decode/DecodeNative/RenderNative` 返回与调用路径保持不变。首帧要求同一 exact binding 下
`RenderOutputBuffer` 成功、NativeImage `UpdateSurfaceImage` 成功、实际 EGL swap 成功三段
计数均非零；renderer 在 swap 返回前被替换时二次 active handle/generation 核验会拒绝旧
Surface ack。stop 先关闭提交 admission、等待 in-flight，再复用既有 exact detach/destroy
和 deferred retirement；20 次 start/stop、blocked submit timeout+retry、旧 owner token、
callback transition 和旧协议全量回归均已冻结。

验证结果：host 普通、strict `-Werror` 与完整 TSan 均 **515/515 PASS**；ASan/UBSan
clean rebuild 连续三轮 **515/515 PASS**，scan-build 全 native 目标零报告。两 ABI 产品库、
Moonlight sink archive 与 callback-entry carrier 均通过；每 ABI 93 条永久 command 中
`rdpnapi=48`、common-c adapter=1、video bridge=1、decoder sink=2。arm64
16103/705、x86_64 15634/703 的 defined/undefined name+type 集合和两 ABI 各 147 条 NAPI
name+type+size 子集与 N2-03 基线逐项一致。两项 Hvigor 均 BUILD SUCCESSFUL；signed HAP
SHA-256 为 `65db3cb5d303dd37c86fbefac514fa2bc7f9749ba6a5487151a14648b752e1bd`，排序后
423 paths 与 N2-03 基线逐项相同。在线云注册仍精确 8 表，FAB 仍只有一个 disabled
Moonlight 和一个“即将支持”，11 个 feature inputs 默认 false，平台能力默认
11 pending/1 unsupported/0 supported。两个 reviewer 实例已建立，本 checkpoint 只有完整
机器门禁和逐文件自审；后续复用既有 task ID，不新建第三个实例或伪造独立回执。

N2-05 只能按以下原子顺序执行；它只冻结视频 Surface 生命周期，不接 ArkTS 页面、PIP
controller、后台任务、音频、输入、云或可点击产品入口：

1. 以 `bee0ac1da` 保存 515 项普通/strict/TSan/ASan、双 ABI 93/48/1/1/2 command、
   callback carrier、symbol/NAPI、423-path HAP、双 Hvigor和 8 表/灰入口/全 false truth
   基线。先为 RDP/RustDesk/VNC 现有 `BindVideoPipeline`、
   `RebindActiveVideoPipeline`、`DetachVideoPipeline`、renderer active generation、
   `NativeSessionHandles`、`RemoteSessionPipLifecyclePolicy` 和 `RemoteDesktop` Surface/PIP
   顺序保存测试/源码快照；不得改它们来迁就 Moonlight。
2. 首选新增唯一 pure-native `MoonlightVideoSurfaceLifecycle.h/.cpp` 与 focused test，组合
   N2-04 sink/port，不继承或复制 decoder/renderer。状态固定为
   `AwaitingSurface → Bound → Suspending → SuspendedNoSurface → Rebinding → Bound`，另有
   terminal `Stopping/Stopped`；每个命令携带 exact key、operation generation、renderer
   handle/generation 和 runtime-proof generation，旧/重复/逆序事件返回 typed
   `stale/already-applied/busy`，绝不靠当前全局指针猜 owner。
3. 初始 setup 没有真实 Surface 时不得启动 decoder sink，也不得把 pbuffer/off-screen EGL
   当展示目标；common-c transport 可以保持运行，但 video payload 在复制/排队前以
   `NoSurface` 丢弃并只合并一次 IDR 需求。不得缓存 AU、NAL、纹理或无限增长计数；只保留
   bounded codec configuration（沿用 bridge 1 MiB 上限）和最后一个 generation receipt。
4. Surface detach、Home 后台且无可用 PIP Surface、锁屏或 renderer owner replacement 的顺序
   固定为：关闭新 video submit → 等 in-flight submit drain → 清 first-frame receipt → 停止
   frame/error callback admission → exact `DetachVideoPipeline` → 等 render/NativeImage callback
   lease → 标记 `SuspendedNoSurface`。临时 suspend 不销毁 common-c connection、session owner
   或 decoder registry handle；显式 disconnect/terminal stop 才走 N2-04 destroy/retire。
5. N2-04 sink/port 若缺少 temporary suspend/rebind seam，先写失败测试，再加最窄 hidden typed
   overload。suspend 必须保留 exact decoder handle/owner 但关闭 admission；rebind 只接受同一
   key/decoder handle/display、严格更新的 renderer handle/generation 和新的 runtime-proof
   generation，并复用既有 reactivation/configure path。不得调用全局 owner/display setter，
   不得把 handle 暴露到 NAPI/ArkTS。
6. 新 Surface attach/rebind 必须先证明 active renderer owner、handle、generation 和真实
   Surface ready，再安装 callback 并原子发布 binding；发布前到达的旧 output/frame callback
   只能命中旧 generation 并被丢弃。rebind 后 first-frame 清零、视频 admission 重开但保持
   `waitingForIdr`，向上返回一次 `requestIdr=true`，只有新 IDR accepted 后才允许 P frame。
7. PIP 迁移合同与现有 RustDesk 顺序一致：前台 controller 可预备，但 PIP free-node Surface
   未给出有效 id/尺寸/renderer generation 前不拆页面 renderer；有效后先 suspend decoder，
   再绑定 PIP renderer。恢复前台先等 PIP terminal barrier，再 suspend PIP binding、释放
   PIP renderer、绑定当前 page Surface。N2-05 只实现/测试 native policy port，不修改
   `RemoteSessionPipService` 或 `RemoteDesktop.ets`；S1-08 才装配页面事件。
8. 同一 renderer generation 的 resize 只更新 viewport/surface dimensions，不 flush codec、
   不改变 remote negotiated width/height，也不清已展示首帧；Surface id、renderer handle 或
   renderer generation 改变才走完整 suspend/rebind。旋转、折叠和自由窗若仅尺寸变化走
   resize；ArkUI 实际重建 Surface 时走新 generation，不能把旧尺寸 callback 覆盖新状态。
9. 无 Surface 期间的 video callback 必须 O(1) 返回、零 owned AU retention、零 decoder queue
   增长；`NoSurface` 与 decoder `Backpressure`、`NeedIdr`、`Stale`、terminal failure 分开计数。
   Surface 恢复只请求一次 IDR，不重启网络、不 replay 丢弃 payload；若 host 不发 IDR，保持
   paused/diagnostic truth，绝不把旧纹理或音频 ready 当新首帧。
10. stop 可从 Bound、Suspending、Suspended、Rebinding 任一状态进入；顺序为关闭 lifecycle
    admission→取消 pending rebind generation→drain submit/callback→exact detach→N2-04
    stop/destroy→清 config/first-frame/surface receipt。错误 key 不影响当前 owner，重复 stop
    幂等，timeout 后 admission 仍关闭且下一次 stop 能完成；析构不 detach thread、不 sleep
    猜测时序。
11. focused tests 至少覆盖：无 Surface setup、detach 前后 payload、单次 IDR 合并、旧/重复
    Surface generation、page→PIP→page、后台无 PIP、renderer replacement、same-generation
    resize、旋转重建、detach/rebind 中 blocked submit/output/frame callback、stop 与 rebind
    竞态、host 不回 IDR、20 次 page/PIP/foreground 循环、零 payload retention/high-water 和
    RDP/RustDesk/VNC 回归。使用 fake port、barrier、fake clock；不得用 sleep 或真实网络。
12. 普通/三轮 ASan、完整 TSan、strict/analyzer、双 ABI产品与 callback carrier、ABI/NAPI、
    HAP path、双 Hvigor、platform/vendor/TOTP/Light/diff/state 全通过后单独 checkpoint。
    无 HAP/AppSpawn Surface/PIP runtime receipt 时 product wiring、FAB、六项 truth 仍关闭；
    N2-06 才开始 Opus bridge，S1-08 才把 N2-05 接到 ArkTS/PIP/后台生命周期。

#### 15.7.13 N2-05/N2-06 已完成事实与 N2-07 唯一下一合同（2026-08-10）

N2-05 已由代码 checkpoint `7992279c7` 完成。新增内容是 NAPI-free、hidden/private 的
`MoonlightVideoSurfaceLifecycle` 和 8 个 focused case；它组合 N2-03 bridge 与 N2-04 sink，
没有 product factory caller，也没有修改 ArkTS、PIP service、NAPI、云、音频或输入。无
Surface gate 位于 bridge copy/queue 之前，typed `NoSurface` 不保留 AU 且只合并一次 IDR；
temporary suspend 关闭 admission、drain submit、清 first-frame 并 exact detach，但保留 decoder
registry handle/config generation。rebind 只接受同 key/decoder/profile/display 和严格更高的
Surface、renderer、runtime-proof generation；它清首帧并等待新 IDR。同 generation resize 只改
viewport。stop exact、幂等、timeout 后可重试，并可由更高 owner token 重新使用。

验证结果：host 普通、strict `-Werror`、完整 TSan 与最终三轮 ASan/UBSan 均
**523/523 PASS**，scan-build 全目标零报告；双 ABI 产品、sink/lifecycle archive 和 callback
carrier 通过，每 ABI 94 条永久 command 为 `rdpnapi=48`、adapter=1、video bridge=1、
decoder sink/lifecycle=3。动态 ABI 与 N2-04 完全一致：arm64 16103/705、x86_64
15634/703 defined/undefined，两 ABI NAPI 子集各 147。两项 Hvigor BUILD SUCCESSFUL；signed
HAP SHA-256 为 `e2598c67896e04949409dbe93d26ec8a7ee390a53e1052aa0c7c8e0c692453c8`，
423 paths 与基线一致。在线云注册仍是 8 表，FAB 仍只有一个 disabled Moonlight 和一个
“即将支持”，11 个 feature inputs 默认 false，平台能力默认 11 pending/1 unsupported/0
supported；HDC 为 `[Empty]`，不声明 Surface/PIP/H.264 runtime 或真实首帧可用。

N2-06 的源码审计基线也已冻结：官方 common-c 的 audio init 已投影为
`MoonlightCommonCAudioSelection {layout, opus}`，其中 opus 包含 sampleRate/channelCount/
streams/coupledStreams/samplesPerFrame/mapping；官方 `AudioStream.c` 单个 UDP packet 上限为
1400 bytes，并用 `decodeAndPlaySample(nullptr, 0)` 表示一个丢包的 PLC 请求。当前 adapter
却会跳过 `count==0`，且 `onAudioPayload()` 会拒绝 null+0；这是 N2-06 必须先用失败测试修正的
既有 seam，不能通过定时器猜丢包。项目已有唯一 OHAudio owner/registry、callback admission、
120–300 ms prebuffer 与有界 PCM queue（`audio_player.*`/`audio_queue_policy.*`），但 N2-06
不得接入或复制它们。`scripts/build_opus_ohos.sh` 以固定 SHA-256 构建 libopus 1.5.2；两个 ABI
现有 `libs/opus-ohos/<ABI>/libopus.a` 已由 RustDesk FFI 的最终链接消费，并包含 mono/stereo 与
multistream decoder symbols。N2-06 必须证明最终链接只有这一版本/一组定义，不能再引入
Homebrew/FFmpeg/另一份 vendored Opus 到产品。

N2-06 只能按以下原子顺序执行；它只冻结 borrowed Opus callback→owned bounded decode→PCM
handoff，不创建 OHAudio renderer，不接产品会话：

1. 以 `7992279c7` 保存 523 项普通/strict/TSan/ASan、双 ABI 94/48/1/1/3 command、
   symbol/NAPI、423-path HAP、双 Hvigor、Opus archive hash/symbol inventory，以及现有
   RustDesk audio owner/registry/queue 与 RDP/VNC 回归基线。允许修改范围仅为新建
   `MoonlightAudioBridge.h/.cpp`、必要的 OHOS-only private Opus port、focused tests、最窄
   CMake source/link 声明，以及为 PLC seam 增加的 adapter test/实现；不得修改
   `audio_player.*`、`audio_queue_policy.*`、RustDesk worker、NAPI/ArkTS/UI/cloud/input。
2. 先写失败测试冻结官方 callback 语义：`bytes==nullptr && count==0` 是一个 PLC work item；
   `nullptr+positive`、`non-null+zero`、negative C count 和 `count>1400` 均拒绝。adapter 的
   1 MiB 通用上限不得成为 bridge 分配上限；`commonAudioPayload()` 和
   `Invocation::onAudioPayload()` 只做最窄改动，把合法 null+0 在 active audio stage 内同步
   转交 media port。PLC 也必须持有 callback/owner lease，stop/cleanup 后的 PLC 一律 stale。
3. 新增 project-owned hidden `MoonlightAudioDecoderPort` 与 `MoonlightAudioPcmSink`，由
   `MoonlightAudioBridge` 注入；bridge 不 include `Limelight.h`、NAPI、OHAudio、
   `audio_player.h` 或 RustDesk 头。port 只负责 decoder create/decode/destroy，sink 只接收
   本次调用期有效的 PCM view 和 exact stream identity；二者都不得保存 process-global active
   pointer、另建 session owner、线程、无限队列或 detached cleanup。
4. stream identity 固定为 exact `MoonlightSessionKey + audioConfigurationGeneration`；状态固定
   为 `Idle → Configured → Started → Stopping → Stopped → Cleaned`，另有 terminal `Failed`。
   setup/start/submit/stop/cleanup 每次都校验 exact key/generation 和单调 operation generation；
   旧 owner、重复/逆序事件分别返回 typed `Stale/AlreadyApplied/InvalidState/Busy`，错误 key
   不能停止或清理当前 decoder。一次 bridge 只持有一个 decoder，重配必须先 exact cleanup。
5. MVP admission 只接受 N2-01 offered `Stereo` 和官方 48 kHz family-1 stereo multistream：
   `channelCount=2`、`streams=1`、`coupledStreams=1`、mapping 前两项 `{0,1}` 且余项为 0，
   `samplesPerFrame` 为 120..5760 且 120 对齐。`Disabled` 不创建 bridge；mono、5.1、7.1、
   mapping 置换、未知 layout、降混和重采样均 typed `Unsupported`，不静默变成立体声，也不把
   common-c 对 1–8 声道的结构校验误写成产品已支持。
6. OHOS-only port 使用 libopus multistream integer decode ABI，输出 frame count 必须
   `>0 && <= configured samplesPerFrame`；普通 packet 固定 `decode_fec=0`，null+0 固定调用
   decoder PLC，frame size 使用 negotiated `samplesPerFrame`。本 checkpoint 不主动 FEC、
   不根据 sequence 猜 PLC 次数、不重采样、不做音量/降混；损坏包和 codec error 返回 typed
   `Malformed/DecodeFailed`，保持 decoder 可继续，只有 decoder state corruption 才 terminal。
7. borrowed packet 在 callback 返回前同步复制到 bridge-owned、容量最多 1400 bytes 的 work
   item；每 bridge 同时最多一个 decode in flight，竞争 submit 返回 `Backpressure`，不阻塞
   common-c 网络线程排队。PLC work item 长度为 0。解码 scratch 最多
   `5760 frames × 2 channels × sizeof(int16_t)=23040 bytes`；有效 PCM 严格按实际 frame count
   截断并显式序列化为 interleaved S16LE，禁止暴露未初始化尾部、宿主 endian 或 float
   rounding 差异。sink 返回前 PCM 只读；需要保留时由 N2-07 现有 player 自己同步复制。
8. 结果至少区分 `Accepted/PlcAccepted/Backpressure/Malformed/Unsupported/Stale/
   InvalidState/SinkRejected/DecodeFailed/Terminal`，receipt 携带 exact key/config generation、
   operation generation、input bytes、decoded frames/PCM bytes 和是否 PLC；不携带 payload、
   PCM、host 地址、key/token。计数器饱和/有界，日志采样且脱敏。普通音频包失败不能请求
   video IDR，也不能改变 video bridge、Surface lifecycle 或首帧 receipt。
9. stop 顺序固定为关闭新 submit admission→等待 in-flight decode/sink callback drain→清
   started truth→decoder reset/destroy；cleanup 再清 packet/PCM scratch、selection、generation
   和计数敏感临时状态。timeout 后 admission 保持关闭，decoder 不提前释放，下一次 exact
   stop/cleanup 可重试。析构走同一同步/延迟清理合同，不 detach thread、不 sleep 猜时序；
   packet、PCM scratch 和 mapping backing 在 release 前 secure wipe，测试用 poison/observer
   证明没有跨 session residual audio。
10. PCM sink accepted、`audioReady()`、common-c `AudioStreamStart` 和任意音频计数都不是
    video first-frame、streaming ready 或 protocol available。N2-06 archive 无 product media
    port caller时 `audioReady()` 继续 false；不因 decoder compile/link 成功改变 FAB、
    capability snapshot、六项 release truth 或连接阶段 UI。音频失败/无音频继续的用户决策
    属于 N2-07/S1，不在本 checkpoint 制造假回调。
11. Opus 依赖只解析到固定的 1.5.2 artifact。优先让新 private port 由现有最终链接中的同一
    archive 满足；若静态库顺序需要调整，只改最窄 target order/group，并保存 link map，证明
    `opus_multistream_decoder_create/decode/destroy/get_version_string` 各只有一个产品定义，
    RustDesk 原有 `opus_decoder_*` 仍解析、动态 ABI/NAPI 不变。禁止 `--whole-archive`、复制
    `.a`、改 RustDesk Cargo feature 或把 Opus symbols 导出为产品 API。
12. focused tests 至少覆盖：合法 stereo setup/start、tracked Opus packet→golden S16LE、
    null+0 PLC、损坏/截断/1/1400/1401-byte packet、frame count 0/过大、5.1/7.1/mono/mapping
    unsupported、错误/旧 key 与 generation、重复/逆序 lifecycle、sink reject、decode failure
    后恢复、并发 backpressure、blocked decode/sink stop timeout+retry、cleanup zeroization、
    20 次 setup/start/PLC/stop/cleanup 和旧协议 audio/video 回归。时序只用 barrier/fake port；
    不 sleep。golden fixture 必须记录 Opus 版本、编码参数、packet hash 与 expected PCM hash；
    product 1.5.2 compile-link 和真实解码运行时 receipt 分开陈述，不能用 fake port 冒充真机。
13. 普通/三轮 ASan、完整 TSan、strict/analyzer、双 ABI 产品与 callback carrier、Opus single-
    definition/link-map、ABI/NAPI/HAP path、双 Hvigor、platform/vendor/TOTP/Light/diff/state 全通过
    后单独 checkpoint。若 host golden 使用系统 codec，必须额外报告其版本且不能把它写成
    产品 1.5.2 runtime receipt；HDC/实机未执行仍保持 blocker。
14. N2-07 才把 bridge PCM sink 按 exact `DecoderSessionIdentity` 接到现有
    `AudioPlayerNapi::DispatchActiveNative(owner, ...)`、`g_audioRegistry` 和既有有界 queue，
    并处理 mute/focus/background/pause/resume/flush。N2-06 不调用
    `SetActiveSessionOwner/ClearActiveSessionOwner`，不建 Moonlight 私有 renderer。S1-08 才接
    ArkTS/PIP/后台；HAP/AppSpawn audio runtime receipt 前用户入口和发布 truth 继续关闭。

#### 15.7.14 N2-07 已完成事实与 N2-08 唯一下一合同（2026-08-11）

N2-07 已由代码 checkpoint `9272f1c9c` 完成。新增 hidden/private
`MoonlightAudioPlayerSink`、production port 和 10 个 focused case；sink 将
`MoonlightAudioStreamIdentity.key` 精确映射到既有 `DecoderSessionIdentity`，并仅通过
`AudioPlayerNapi::DispatchActiveNative`、`SuspendActiveNative`、`TakeActiveNative` 与
`SharedSessionSinkOwnerLease` 使用现有 OHAudio owner、registry 和有界 queue。48 kHz stereo
PCM 的长度/帧数、owner/config/operation generation、mute、focus/background pause、resume、
stop、cleanup、owner 丢失、blocked dispatch drain 与 late PCM 均由 typed 合同保护。

本 checkpoint 没有修改 `audio_player.*`、共享 queue 或 RDP/RustDesk/SSH/VNC 业务源码；没有
新增 OHAudio renderer、registry、queue、线程、singleton、NAPI、ArkTS、UI、云或 product
caller。音频接受/静音/失败均不改变视频首帧、streaming、FAB 或六项 release truth。

验证结果：host normal、strict `-Werror`、ASan/UBSan 与最终 TSan 都是 **548 total / 532 pass /
16 fail**，10 个 N2-07 用例全 PASS，16 项均为既有 VNC 本地 TLS fixture `start()` 失败；首次
TSan 曾为 531/17 且无 sanitizer 报告，立即和最终复跑均恢复 532/16。arm64-v8a/x86_64 产品
native 均重配/链接成功，新 translation units 实际进入 `rdpnapi`，动态符号无
`MoonlightAudioPlayer`/production factory export。双 Hvigor BUILD SUCCESSFUL；signed HAP
SHA-256 为 `a1d6e72894e2596e431f5dd4806c833611adea942559e5b52afe615abd766ef3`，333 paths；Light
和 diff 门禁通过。HDC 当前无 target，故不声明 OHAudio/AppSpawn、真实 Sunshine 或 ARM64
实机运行时能力。

在 N2-07 checkpoint 完成时，N2-08 的合同是建立纯 native、generation-fenced media clock/stats，低开销汇总
network→decode→render、audio queue、FEC/丢包与 p50/p95；不可用值保持 absent，日志采样有界
且默认不含地址、token 或媒体 payload。N2-08 不接 NAPI/ArkTS/UI/cloud，不开放用户入口或
release truth。

#### 15.7.15 N2-08 已完成事实与 N2-09 外部门禁/N3-01 唯一可执行合同（2026-08-11）

N2-08 已由代码 checkpoint `57b1d7da4` 完成。新增 hidden pure-native
`MoonlightMediaClockStats`、13 个 focused case 和独立私有 archive；使用 exact
`MoonlightSessionKey + windowGeneration`、owner/window/source generation fence 和固定最多
256 槽窗口，严格区分 absent 与 measured zero。它有界汇总 network assembly、decode queue、
decode、render、end-to-end、common-c host processing latency、audio queue 的
p50/p95/max/current count/total，并精确投影 RTP media/FEC/recovered/recovery failure/OOS/
invalid/invalid FEC、audio underrun/drop 增量；累计源 reset/decrease baseline、video stride、
RTP/audio 时间节流、计数饱和、stop/cleanup/stale callback 均有确定性合同。

host normal、strict `-Wall -Wextra -Wpedantic -Werror`、ASan/UBSan 连续三轮和最终 TSan 均为
**561 total / 545 pass / 16 fail**；13 个 N2-08 用例全 PASS，16 项仍全是既有 VNC 本地 TLS
fixture `start()` 失败，sanitizer 无报告；focused clang analyzer 零诊断。arm64-v8a/x86_64
产品 native 均重配/链接成功；两个私有 archive 非空，但没有 runtime caller，object 未被拉入
`rdpnapi`，本地/动态符号均无 `MoonlightMediaClockStats`。动态 defined/undefined 集合与 N2-07
逐项相同：arm64 **16114/705**、x86_64 **15645/703**，没有新增 NAPI export 或跨协议 ABI 面。
双 Hvigor、signed HAP 和 Light 通过；HAP SHA-256
`5bf7cd91809c7c9e46cf15aa1d8b963946f0d805b91a867ef98492aa441860fe`，333 paths。

本 checkpoint 未修改 common-c、共享 telemetry/render/audio 或 RDP/RustDesk/SSH/VNC 业务源码，
未新增线程、队列、singleton、NAPI、ArkTS、UI、云、日志或 product caller。N2-09 需要真实
Sunshine 与用户 ARM64 实机完成媒体/温控/生命周期矩阵，当前保持 EXTERNAL PENDING；计划允许
跨过该外部门禁继续无产品接线的 dormant N3-01。N3-01 是当前唯一可直接执行的代码任务，只建立
exact session/generation/device/source/timestamp 输入桥、旧 session 丢弃和失焦释放合同；不得接
ArkTS/UI/product caller，不改变灰色 FAB、现有八张云表或六项 release truth。

#### 15.7.16 N3-01 已完成事实与 N3-02 唯一可执行合同（2026-08-11）

N3-01 已由代码 checkpoint `fe46025ef` 完成。新增 hidden pure-native
`MoonlightInputBridge`、12 个 focused case 和独立私有 archive；每个 bounded event 都携带
exact `MoonlightSessionKey + inputGeneration`、device、source/source generation、sequence 和
monotonic timestamp，固定最多 32 个 source lane 与 64-byte payload。它复用唯一
`MoonlightSessionOwner` 和既有共享跨协议 `SessionSinkOwnerLease`，只在 exact Running owner、
admission open 且未取消时同步执行；Starting、旧 owner、其他协议 owner、旧 source generation、
乱序 timestamp/sequence、重复事件与 source capacity 均有 typed fail-closed 结果。focus loss、
stop、失败重试、resume、cleanup、析构和并发 dispatch/stop 均冻结 neutral flush 与 generation
边界，且没有新增队列、线程、singleton 或活动 adapter。

host normal 连续三轮、strict `-Wall -Wextra -Wpedantic -Werror`、ASan/UBSan 连续三轮和 TSan 均为
**573 total / 557 pass / 16 fail**；12 个 N3-01 用例全 PASS，16 项仍全是既有 VNC 本地 TLS
fixture `start()` 失败，sanitizer 无报告；focused clang analyzer 零诊断。arm64-v8a/x86_64
产品 native 均重配/链接成功；两个私有 archive 非空，但没有 runtime caller，object 未被拉入
`rdpnapi`。产品与 HAP 中都没有 `MoonlightInput` 本地/动态符号，动态 defined/undefined 数量
保持 arm64 **16114/705**、x86_64 **15645/703**，与 N2-08 基线一致。双 Hvigor、signed HAP
和 Light 通过；HAP SHA-256
`645308dff61bb65c959ddb9f704eba1334f04fca5af74af59131183965326ba9`，333 paths。

本 checkpoint 未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio 或
RDP/RustDesk/SSH/VNC 业务源码，未新增 NAPI、ArkTS、UI、云、日志或 product caller。N2-09
继续 EXTERNAL PENDING；N3-02 是当前唯一可直接执行的代码任务，只在 N3-01 bounded command
body 内建立 HarmonyOS key→Moonlight key、修饰键 once/lock、text vs physical key、全量 key-up
和本地逃生键的纯 native 合同。它仍不得连接公共 `InputHandler`、NAPI、ArkTS、UI 或产品路径，
不得改变灰色 FAB、现有八张云表或六项 release truth。

#### 15.7.17 N3-02 已完成事实与 N3-03 唯一可执行合同（2026-08-11）

N3-02 已由代码 checkpoint `a552b30a2` 完成。新增 hidden/private
`MoonlightKeyboardMapper`、15 个 focused case 和独立私有 archive；它把工程现有 HarmonyOS
key namespace 严格映射为官方 common-c `0x8000 | Win32 VK`、down/up、modifier mask 与
non-normalized flag。物理键与严格 UTF-8 on-screen text 分流，物理 Escape 永远只作为本地逃生；
固定容量为 8 个普通按键和双侧四类修饰键，单次完整释放最多 16 条命令。once/locked modifier、
逐命令状态提交、backpressure/port failure 未接受后缀精确续传、错误设备 key-up 拒绝、反序全释放、
owner loss 与 pending payload 清理由有界状态机覆盖，没有新增线程、队列、singleton 或第二 owner。

host normal 连续三轮、strict `-Wall -Wextra -Wpedantic -Werror`、ASan/UBSan 连续三轮和 TSan
最终均为 **588 total / 572 pass / 16 fail**；15 个 N3-02 用例全 PASS，16 项仍全为既有 VNC
本地 TLS fixture `start()` 失败，sanitizer 无报告；focused clang analyzer 零诊断。N3-01 并发测试
只修正为同时接受 duplicate-first 与 stop-first 两种合法 mutex 串行结果，生产 bridge 未修改。
arm64-v8a/x86_64 产品 native 均重新配置并链接；私有 archive 非空但没有 runtime caller，object
未进入 `rdpnapi`。两 ABI 动态 defined/undefined 数量仍为 arm64 **16114/705**、x86_64
**15645/703**，产品/HAP 均无 `MoonlightKeyboard` 或 `MoonlightInput` 本地/动态符号。双 Hvigor、
signed HAP 与 Light 通过；signed HAP 共 333 paths。

本 checkpoint 未修改生产 common-c、公共 `InputHandler`、共享 telemetry/render/audio 或
RDP/RustDesk/SSH/VNC 业务源码，未新增 NAPI、ArkTS、UI、云、日志或 product caller。N2-09
继续 EXTERNAL PENDING；N3-03 是当前唯一可直接执行的代码任务，只建立 dormant pure-native
绝对/相对鼠标、按钮、滚轮与 content-rect mapping 合同。capture/constraint/raw-relative 在
API 23/HAP/实机证据前保持 fail closed，且不得改变灰色 FAB、现有八张云表或六项 release truth。

#### 15.7.18 N3-03 已完成事实与 N3-04 唯一可执行合同（2026-08-11）

N3-03 已由代码 checkpoint `1787da821` 完成。新增 hidden/private
`MoonlightPointerMapper`、18 个 focused case 和独立私有 archive；没有 product caller。
absolute mapping 明确以 physical surface pixel 和 generation-fenced content rect 为输入，覆盖
letterbox/fill/1:1/pan、四向旋转与 DPI 不变映射，黑边/outside content 不 clamp 或 teleport。
relative mapping 保存 sensitivity 后的小数残差，对非有限值与 int16 overflow fail closed。wire body
只输出官方 common-c 的 relative/absolute、五键、纵向/横向滚轮合同；按钮状态按 device/source
精确归属，absolute press 将位置与按键组成有界原子事务，出界 press 抑制但 release 仍可送达，
release-all 反序发送。逐命令状态提交、single pending transaction、backpressure/port failure 未接受
后缀精确续传、cancel-only-if-unsent、destructor 清理均由固定容量状态覆盖。

host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **606 total /
590 pass / 16 fail**；18 个 N3-03 用例全 PASS，16 项仍全为既有 VNC 本地 TLS fixture
`start()` 失败。ASan/UBSan 连续三轮与最终 TSan 同为 **590/16** 且无 sanitizer report；focused
clang analyzer 零诊断。arm64-v8a/x86_64 产品构建均生成含
`MoonlightPointerMapper.cpp.o` 的非空私有 archive；无 caller 时 object 未进入 `rdpnapi`。
两 ABI 动态 defined/undefined 仍为 arm64 **16114/705**、x86_64 **15645/703**，产品/HAP 无
`MoonlightPointer`、`MoonlightKeyboard` 或 `MoonlightInput` 本地/动态符号。双 Hvigor、signed
HAP、Light 与 `git diff --check` 通过；HAP 共 333 paths。

本 checkpoint 只新增 Moonlight pointer 私有实现/header、focused test 和 CMake target；未修改
common-c、公共 `InputHandler`、共享 telemetry/render/audio、RDP/RustDesk/SSH/VNC 生产业务源、
NAPI、ArkTS、UI、云、日志或产品状态。capture/constraint/raw-relative 当前只有显式 capability
resolution，平台 wiring 仍 unavailable，不声明 HAP/真机输入能力。N2-09 继续 EXTERNAL PENDING；
当前唯一可执行代码任务为 dormant N3-04：建立直接触控与触控板手势、稳定多点 id、cancel、
rotation/scale transform 与 overlay/远端 hit-map 互斥合同；仍不得接公共 `InputHandler`、NAPI、
ArkTS、UI、云或 product caller，模式切换前必须统一 flush，不改变 FAB 或六项 release truth。

#### 15.7.19 N3-04 已完成事实与 N3-05 唯一可执行合同（2026-08-11）

N3-04 已由代码 checkpoint `ebd2fa0bc5` 完成。新增 hidden/private `MoonlightTouchMapper`、
21 个 focused case 和独立私有 archive；仅给 N3-03 pointer mapper 增加共享 normalized content
transform、原子 press+release click 与双轴 scroll 事务，未另建第二套鼠标发送器。direct touch
严格生成官方 common-c `LiSendTouchEvent()` 对应的 28-byte body，只接受明确 host
`LI_FF_PEN_TOUCH_EVENTS` 能力；最多 10 个稳定非零 wire id，覆盖 down/move/up、pointer cancel、
cancel-all、pressure/contact ellipse/rotation、四向旋转、physical-pixel content rect 与黑边拒绝。
overlay/down 和 outside-content contact 由本地持有到 up/cancel；活动 contact 进入 overlay 或黑边时
先向远端 cancel，禁止离开后重放。geometry/hit-map generation 变化要求先 flush，模式切换在提交
新模式前发送 cancel-all 或释放拖拽按键。

touchpad 最多 3 个固定 contact：一指相对光标和左键轻点、双指 centroid 滚动和右键轻点、长按
拖拽、三指轻点只产生本地 `ToggleToolbar`；overlay-owned contact 不计入远端手势，进入 overlay
会先释放 drag 并抑制全部当前手势。固定 16 个 observed device/source lane 约束 generation、
sequence 与 monotonic timestamp；single pending、逐命令状态提交、partial click 精确 suffix retry、
cancel-only-if-unsent 与 destructor 清理由有界状态机覆盖。模块无线程、队列、singleton、平台
listener、NAPI、ArkTS、UI、云或 product caller。

host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **627 total /
611 pass / 16 fail**；21 个 N3-04 用例全 PASS，16 项仍全为既有 VNC 本地 TLS fixture
`start()` 失败。ASan/UBSan 连续三轮与最终 TSan 同为 **611/16** 且无 sanitizer report；focused
clang analyzer 对 touch/pointer 零诊断。arm64-v8a/x86_64 均生成含
`MoonlightTouchMapper.cpp.o` 的私有 archive，无 caller 时 object 未进入 `rdpnapi`。两 ABI
动态 defined/undefined 仍为 arm64 **16114/705**、x86_64 **15645/703**，产品/HAP 本地与动态
符号均无 `MoonlightTouch`/`MoonlightPointer`/`MoonlightInput`。双 Hvigor、signed HAP、Light、
117-file vendor gate 和 `git diff --check` 通过；HAP 共 333 paths。HDC 返回
`Connect server failed`，因此不声明 API 23/HAP/真机 direct-touch、touchpad 或 Sunshine runtime。

本 checkpoint 未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio 或
RDP/RustDesk/SSH/VNC 生产业务源码，未新增日志或改变云表、灰色 FAB、first-frame、streaming/
protocolAvailable 和六项 release truth。N2-09 继续 EXTERNAL PENDING；当前唯一可执行代码任务
为 dormant N3-05：先依据 API 23 probe 建立实体控制器稳定 device→slot、轴/trigger/dead-zone、
断开 neutral 合同；多玩家能力没有真实设备证据时限制为一个 slot，不接公共 `InputHandler`、
NAPI、ArkTS、UI 或 product caller。

#### 15.7.20 N3-05 已完成事实与 N3-06 唯一可执行合同（2026-08-11）

N3-05 已由代码 checkpoint `1aadfba24` 完成。新增 hidden/private
`MoonlightControllerMapper`、16 个 focused case 和独立私有 archive；platform link probe 只增加
API 23 GameControllerKit device online/offline、button、双摇杆、双 trigger、event device id 与
source type 的 compile-link 证明，不注册 listener。项目自有 28-byte command body 直接投影 pinned
common-c `LiSendControllerArrivalEvent()`/`LiSendMultiControllerEvent()` 参数；只接受当前枚举且属于
API 23 保守集合的 A/B/X/Y、dpad、肩键、Menu/Play 与 stick click。Home 保留为本地系统逃生，
Back/Special 不伪造。arrival 只声明 Unknown/Xbox/PlayStation/Nintendo 类型和已枚举 analog-trigger
输入能力；rumble、LED、motion、battery、touchpad 与 adaptive trigger 一律不声明。

映射合同固定一个物理 slot 0，直到两控制器真实设备证据成立；最多 8 个 observed lane，以 exact
device/source generation、sequence 和 monotonic timestamp 拒绝 stale/duplicate/cross-device 事件。
摇杆使用成熟 Moonlight Android 的 7% radial deadzone、`0x7FFE` 量程、不做 deadzone 后重缩放，
并把 API positive-down Y 反向到 common-c/XInput；trigger 使用 13% deadzone，analog profile 缩放到
0..255，digital profile 只发 0/255；hat 以 ±0.5 阈值形成 dpad。每次发送完整状态，bridge 接受后
才提交；background neutral 保留 active-mask=1，disconnect 发送 active-mask=0 的全中立 frame，
接受后才释放 slot，backpressure 可精确重试。

host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **643 total /
627 pass / 16 fail**；16 个 N3-05 用例全 PASS，16 项仍全为既有 VNC 本地 TLS fixture
`start()` 失败。ASan/UBSan 连续三轮与最终 TSan 同为 **627/16**，无 sanitizer report；focused
clang analyzer 零诊断。arm64-v8a/x86_64 均生成 controller archive，API 23 probe 双 ABI通过；
无 caller 时 archive object 未进入 `rdpnapi`，dynamic defined/undefined 仍为 arm64
**16114/705**、x86_64 **15645/703**，产品库没有 mapper 符号或 controller runtime 依赖。双
Hvigor、signed 333-path HAP、Light、117-file vendor、TOTP brand manifest 与 `git diff --check`
通过。HDC 返回 `Connect server failed`，不声明 HAP/真机实体控制器、双手柄或 Sunshine runtime。

本 checkpoint 未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
RDP/RustDesk/SSH/VNC 生产业务源码、NAPI、ArkTS、UI 或云，也不改变 first-frame、灰色 FAB、
streaming/protocolAvailable 或六项 release truth。N2-09 继续 EXTERNAL PENDING；当前唯一可执行
代码任务为 dormant N3-06：建立按能力拆分的 controller feedback 合同。API 23 当前未发现官方
rumble/LED/motion/battery 输出 API，所以默认必须 unsupported 且零调用；只有未来官方 API 与真机
证据同时存在才允许开启，仍不接 NAPI、ArkTS、UI 或 product caller。

#### 15.7.21 N3-06 已完成事实与 N3-07 唯一可执行合同（2026-08-11）

N3-06 已由代码 checkpoint `baa9cafef` 完成。新增 hidden/private
`MoonlightControllerFeedback`、16 个 focused case 和独立私有 archive；不注册 GameControllerKit
listener，不接 common-c callbacks、NAPI、ArkTS、UI、云或 product caller。合同按 pinned common-c
能力拆分 rumble `0x02`、trigger rumble `0x04`、accelerometer `0x10`、gyroscope `0x20`、battery
`0x40` 与 RGB LED `0x80`，adaptive trigger 因无 `LI_CCAP` bit 独立门禁。能力只有 official API
evidence 与 exact physical-device evidence 同时成立才启用；API 23 product evidence 固定全 false，
所以当前每种 feedback 都 explicit unsupported 且零 port 调用，不以空成功伪装支持。

未来双证据路径仍固定 slot 0，并要求 exact session/owner/input、controller、device/device generation、
operation generation 与 monotonic timestamp；只有一个 pending command，backpressure 只接受同 context
同 payload 精确重试。motion report 上限 200Hz，未请求 sensor、非有限/越界 sample、重复或过快
sample 均 fail closed；battery 同状态 120 秒限频，状态变化可立即上报。port 返回 unsupported 只降级
对应能力。suspend/unbind/cleanup/destructor 释放本地 haptics、sensor registration、LED ownership 和
adaptive effect；release backpressure 阻止状态推进直到同操作精确重试，resume 不重放旧 effect。

host normal 连续三轮与 strict 最终均为 **659 total / 643 pass / 16 fail**；16 个 N3-06 用例
全 PASS，16 项失败仍仅为既有 VNC 本地 TLS fixture `start()`。ASan/UBSan 最终连续三轮与 TSan
同为 **643/16**，无 sanitizer report；focused clang analyzer 零诊断。arm64-v8a/x86_64 archive
分别为 352518/343878 bytes；无 caller 时 feedback object 未进入 `rdpnapi`，dynamic defined/
undefined 仍为 arm64 **16114/705**、x86_64 **15645/703**，产品库无 feedback 符号或
`ohgame_controller` 依赖。双 Hvigor、signed 333-path HAP、Light、117-file vendor、TOTP 与
`git diff --check` 通过。HDC 返回 `Connect server failed`，不声明真机 feedback runtime。

本 checkpoint 未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
RDP/RustDesk/SSH/VNC 生产业务源码、NAPI、ArkTS、UI 或云，也不改变 first-frame、灰色 FAB、
streaming/protocolAvailable 或六项 release truth。N2-09 继续 EXTERNAL PENDING；当前唯一可执行
代码任务为 dormant N3-07：建立统一 `MoonlightInputFlushPolicy`，复用 N3-01～N3-05 既有 owner/
bridge/mappers，在 overlay、mode change、失焦、PIP/后台、Surface、reconnect、stop 与 generation
change 触发 exact key-up/mouse-up/touch-cancel/controller-neutral；必须幂等，且远端 stop 超时仍
完成本地释放，不接 NAPI、ArkTS、UI、云或 product caller。

#### 15.7.22 N3-07 已完成事实与 N3-08 唯一可执行合同（2026-08-11）

N3-07 由代码 checkpoint `02cb13aae`、审查修复 `36b4e13df`/`337c4f35e` 和终止回放证据补强 `ee073afcb` 完成。新增 hidden/private
`MoonlightInputFlushPolicy`、26 个 focused case 和独立私有 archive；没有定义第二套 input port 或
owner，而是直接组合 N3-01～N3-05 已有 bridge/mappers。统一顺序固定为 touch cancel→pointer
release→keyboard release→controller neutral/disconnect→bridge neutral；覆盖 overlay、control mode、
rotation、focus loss、PIP、background、screen lock、Surface detach、reconnect、session stop、input
generation change 与 controller disconnect。策略持有 exact owner/input identity、各 source context、
operation generation 与 monotonic timestamp；每个 backpressure 只续传当前 mapper 的 exact pending
suffix，其他请求不能越过，重复请求不重发。

`beginFlush()` 在任一 mapper release 前把唯一 bridge 原子推进到 `ReleasePending`，随后只接受 boundary
内由 mapper 标记的 lifecycle release；普通键鼠、触摸和手柄输入无法并发插入。非终止 trigger 进入
suspend，只有更高 operation generation 才能 resume；reconnect、stop 和 generation change 终止旧输入。
失败的 suspend boundary 只用更高 generation 重试且不重放 release；session stop 可从任一 component
pending 或 suspended 状态升级。terminal 遇永久 component failure/owner loss 时丢弃全部 mapper
本地状态后继续 remote stop；remote stop 也失败则 bridge 本地 stopped，返回 `AppliedLocally`。stale
terminal request 不得清状态；pending→terminal 的 drain context 与 completion replay key 分离，remote/
local-terminal exact stop 重放都为 `AlreadyApplied`。controller disconnect 使用 active-mask=0 removal。

host normal 与 strict 均为 **685 total / 669 pass / 16 fail**；26 个 N3-07 用例全 PASS，16 项仍仅为
既有 VNC 本地 TLS fixture `start()`。ASan/UBSan 顺序连续三轮与 TSan 同为 **669/16**，无
sanitizer/data-race report；focused host clang analyzer 为七份零诊断。arm64-v8a/x86_64 archive 分别为
369470/361710 bytes；无 caller 时 object 未进入 `rdpnapi`，dynamic defined/undefined
仍为 arm64 **16114/705**、x86_64 **15645/703**，产品库无 flush-policy 符号。双 Hvigor、signed
333-path HAP、Light、117-file vendor、TOTP 与 `git diff --check` 通过。HDC 返回
`Connect server failed`，不声明 HAP/虚拟机/真机输入 runtime。

本 checkpoint 未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
RDP/RustDesk/SSH/VNC 生产业务源码、NAPI、ArkTS、UI 或云，也不改变 first-frame、灰色 FAB、
streaming/protocolAvailable 或六项 release truth。N2-09 继续 EXTERNAL PENDING；当前唯一可执行
代码任务为 dormant N3-08：定义虚拟控制器模型和确定性布局 validator，覆盖 safe area、冲突热区、
坏布局 fallback 和编辑态零远端发送；button/stick/trigger/dpad full-state 必须复用 N3-05
`MoonlightControllerMapper`→N3-01 `MoonlightInputBridge`→official common-c 原生链路，退出/后台
通过 N3-07 neutral。MVP feature flag 保持 false，不创建可见占位 UI，不接 NAPI、ArkTS、云或
product caller，不创建第二套 input owner/port。

最终复核复用既有 `gpt-5.6-sol low` task `019fe966-d99a-7ce1-8b53-4ef725597053`，没有创建第三个
reviewer；`ee073afcb` 上 P0/P1/P2/P3 均为 0。复核确认 remote/local-terminal 两条 replay 都固定
旧 suspend sequence/timestamp 和 event/flush 零增量，并确认 dormant 私有 archive 不进入产品路径、
不影响 RDP/RustDesk/SSH/VNC 或公共输入的功能与性能；实体/虚拟手柄的原生 full-state 及
`activeGamepadMask=0` source handoff 合同也完整。

N3-08 必须按以下原子步骤实现，任何一步都不能绕开既有 native 输入边界：

1. 新建 project-owned、fixed-capacity 的虚拟控制器 state/layout value objects；按钮、方向键、
   双摇杆、双扳机、肩键、菜单键只使用归一化语义值，不包含 ArkTS、像素坐标或 common-c wire bytes。
2. validator 先校验版本、元素枚举、唯一 id、有限数值、最小触控热区、safe area、遮挡/冲突热区、
   互斥组合和最大元素数，再执行确定性 clamp；任何未知/损坏/跨版本数据整体回退内置安全布局，
   不做部分猜测恢复，也不读云数据。
3. native state aggregator 以独立 virtual source/device/source-generation 接收 press/release/axis/trigger，
   生成与 N3-05 相同的单槽 full-state sample；它只能调用既有 `MoonlightControllerMapper`，由该 mapper
   经唯一 `MoonlightInputBridge` 调用 official common-c controller port，不得复制 packet encoder、
   owner、slot、thread、queue 或 retry lane。
4. physical GameController 与 virtual overlay 使用不同 device/source generation，但共享远端 slot 0。
   source handoff 不得使用保留 slot 的普通 `neutralize()`：必须先关闭 admission，调用 N3-05
   `disconnect()`，确认 accepted `activeGamepadMask=0` 且 mapper slot 0 inactive/cleared，再以更高
   operation generation resume bridge，并以更高 source generation `connect()` 新 source。若 removal
   无法送达，则升级 N3-07 terminal/local-terminal，当前 session 禁止接新 source；只可在完整 cleanup
   后用新 input/session generation 重建。两类 source 的按键、摇杆和扳机状态永不合并。
5. backpressure 时只保留一份 exact pending full-state；更高 sequence 不能越过，retry 不重复提交本地
   state。stale owner/input/source/layout generation、非单调 timestamp、越界值和 edit-mode event 全部
   fail closed，编辑态必须证明 common-c port 调用数为零。
6. overlay open/close、control-mode change、layout swap、rotation、focus/PIP/background/lock、Surface
   detach、reconnect、stop 和 controller disconnect 全部复用 N3-07。实体 listener 的 arrival/state 与
   虚拟 typed ingress 的语义事件只允许在 native aggregator 生成 full-state；ArkTS 不得生成 wire bytes、
   调 official port 或直发手柄信号。退出编辑态必须从 neutral 状态重新开始。
7. focused native tests 至少覆盖 ABXY/dpad/双轴/双 trigger、同时按键、pointer-id cancel、layout
   fallback、safe-area/冲突、physical↔virtual arbitration、accepted removal→slot clear→higher-generation
   connect、failed removal 禁止接管、generation、backpressure exact retry、12 类 lifecycle neutral、
   edit zero-send、stop failure local terminal 和并发串行化。
8. N3-08 checkpoint 仍为 dormant archive：无 NAPI、ArkTS、UI、云或 product caller，双 ABI 无 caller
   时不得把 object 拉入 `rdpnapi`。后续 S1-05A 才增加一个窄 typed NAPI ingress 和 native listener；
   runtime receipt 前 FAB、MVP flag、input capability 与 release truth 继续关闭。

#### 15.7.23 N3-08 已完成事实与 U1-01 唯一可执行合同（2026-08-11）

N3-08 由代码 checkpoint `fef723770` 与审查修复 `6787cc3fb` 完成。新增 hidden/private、fixed-capacity
`MoonlightControllerAggregator`、归一化 virtual-controller layout value objects 与 deterministic validator；
validator 校验版本、枚举、唯一 id、finite 值、最小触控热区、safe area、冲突区、互斥 dpad 布局和
最大容量，合法布局确定性 clamp，任何损坏布局整体回退固定安全布局。编辑态和布局安装均零远端发送。

物理路径的 `ingestPhysical()` 接收纯 native 完整 `MoonlightControllerSample`，固定来源为
`GameController`；虚拟语义固定来源为 `VirtualController`。两者共享 N3-05 slot 0，但由
source/device/source-generation/sequence/timestamp fence 隔离，并且都只调用既有 N3-05 mapper，继而
走 N3-01 bridge 与 official common-c。没有第二 controller encoder、input owner、port、slot、queue、
thread 或 listener。HarmonyOS GameControllerKit 的实际 connected/disconnected/state listener 和
`MoonlightControllerOverlay` 窄 typed NAPI ingress 明确保留到 S1-05A；ArkTS 永远不编码或直发协议。

physical↔virtual 双向换源固定 remove-first：关闭新输入，N3-07 接受 controller disconnect 并发送
`activeGamepadMask=0`，确认 mapper 的 active/device/source/source-generation 全部清空，再以更高
operation generation resume，并以更高 source generation 连接目标。removal/clear/connect 永久失败均
升级 N3-07 SessionStop/local-terminal；同一 session 不接纳目标来源。single exact pending frame 阻止
overtake，全部 12 类生命周期触发继续复用 N3-07。审查修复进一步分离 boundary-retry/resume
generation，增加 HandoffBoundaryPending/HandoffResuming、retired-lane tombstone 原位复用，并使未知
phase 与 inactive-hat NaN fail closed；20 次双向换源后只保留两条来源 lane，旧 generation 仍拒绝。

host normal/strict、ASan/UBSan 顺序三轮与 TSan 均为 **714 total / 698 pass / 16 fail**；16 项失败
仍仅为既有 VNC 本地 TLS fixture `start()`，28 个 aggregator 与 17 个 mapper tests 全 PASS，
sanitizer/race report 为零，四份 analyzer 零诊断。arm64-v8a/x86_64 archive 各含一个 object；
无 caller 时 object 未进入 `rdpnapi`，无 aggregator 动态符号，defined/undefined 仍为 arm64
**16114/705**、x86_64 **15645/703**。两项 Hvigor、signed HAP、Light/vendor/TOTP 与 diff check PASS。

本 checkpoint 未修改 production common-c、公共 `InputHandler`、共享 telemetry/render/audio、
RDP/RustDesk/SSH/VNC 业务源码、NAPI、ArkTS、UI 或云，也不改变 first-frame、streaming、灰色 FAB、
protocolAvailable 或六项 release truth。N2-09 继续 EXTERNAL PENDING。当前唯一可直接执行的代码任务
为 U1-01：冻结 RustDesk 的 FAB→现代协议选择→单 Sheet 路由、返回/关闭、68vp 协议卡和添加页视觉
基线，新增只承载可用性/点击路由的纯 picker policy；不抽取或修改任何其他协议页面。U1-01 不接
Moonlight runtime，不解除本地-only、灰色入口或发布门禁。

复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 对 `fef723770..6787cc3fb` 完成最终复核，
P0/P1/P2/P3 全 0；receipt `moonlight-n3-08-gpt5-6787cc3fb-2026-08-11`。复核确认 staged boundary
retry、retired lane、20 次换源、fail-closed 值域和 dormant 产品隔离全部闭环，未创建新 reviewer。

#### 15.7.24 U1 RustDesk UI 基线覆盖决定（2026-08-11）

产品决定 Moonlight UI 不再以 VNC 页面为参考。U1 的唯一设计基线改为当前 RustDesk：FAB 仍走
`resetForm()`、`resolveFabAddStyle()`、`openSheetSafely()` 和唯一 `showAddSheet`；现代选择页继续由
`HostAddWizardSheet`/`HostProtocolPicker` 承载，Moonlight 与 RustDesk 调用同一个
`protocolOption()`，保持 68vp 高度、18vp 水平内边距、16vp 圆角、标题/副标题字号、卡片间距与
关闭行为一致。当前 Moonlight 仍为末项、0.58 opacity、唯一“即将支持”且点击零路由。

品牌资源锁定 Moonlight Qt `2e13ed9977bc31c73caf8428f08f58d793313ece` 的
`app/res/moonlight.svg`，原始 SHA-256 为
`6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2`。产品资源只做确定性单色
转换：保留 256 viewBox、128/96 半径与原 starburst 坐标，把白色内圆改为透明孔、统一
`currentColor`，由 ArkUI `fillColor()` 适配主题/禁用色；加载失败回退
`sys.symbol.gamecontroller_fill`。provenance、NOTICE、SPDX、artifact hash 与 source offer 必须同步。

U1-04 的 Moonlight 四步添加页只复用 RustDesk 的视觉和交互语法：36vp 返回按钮、标题/步骤说明、
模式卡、字段、错误提示、44vp 主按钮、同一 Sheet owner、返回协议列表和关闭生命周期。不得复制
RustDesk relay/TOTP/credential 业务状态，也不得引入第二个 add Sheet、固定延迟或 Moonlight 云路径。
实体/虚拟手柄产品接线仍归 S1-05A，ArkTS 不编码或直发 Moonlight 手柄协议。

#### 15.7.25 U1-01～U1-03 RustDesk 风格灰色入口 checkpoint（2026-08-11）

`c38ff6265` 完成 U1-01～U1-03，审查修复 `71e9902c9`、`7eaad950b` 收紧合规、计划来源和定向测试。
`HostProtocolPicker` 没有复制第二套卡片，也没有修改
`RustDeskAddFlow`：RustDesk 与 Moonlight 继续调用同一个 `protocolOption()`；Moonlight 只增加默认
为 false 的 `moonlightProtocolAvailable`、纯 `HostProtocolPickerPolicy` 和品牌图标分支。默认状态固定
为末项、0.58 opacity、唯一“即将支持”，禁用点击返回空 route；未来显式 enable 时 route 合同与
RustDesk 相同。`HostAddWizardSheet` 只透传该 fail-closed prop，`HostListPage` 的 FAB owner、
`resetForm()`、`openSheetSafely()` 和 `showAddSheet` 未改。

图标来自 Moonlight Qt revision `2e13ed9977bc31c73caf8428f08f58d793313ece` 的
`app/res/moonlight.svg`。上游 SHA-256 为
`6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2`，确定性单色可着色资源
SHA-256 为 `4f5ef547e33767287e3438a6d1598a1bdef6e49df4678a5f7f214ec58c9e5886`；资源加载失败回退
`sys.symbol.gamecontroller_fill`。provenance、NOTICE、SPDX、source offer、artifact hash 与 Light
门禁同步完成。

两项强制 Hvigor 均 BUILD SUCCESSFUL，并生成 signed HAP。该 HAP 已通过沙箱外 HDC 安装并启动；
协议选择页实际渲染官方几何的禁用色 Moonlight 图标，点击卡片后 UI tree 仍同时包含“添加远程主机”、
“Moonlight”和唯一“即将支持”，证明没有进入添加路由。Light、117-file vendor、SBOM JSON、资源
SHA 与 `git diff --check` 均通过。新增 3 个 pure policy 测试已注册，Moonlight focused 总数为
154 tests / 21 describe；`ohosTest` task 仍未注册，因此不声明设备 Hypium 执行通过。

隔离范围为精确 diff：未修改 `RustDeskAddFlow.ets`、`HostListPage.ets`、CloudStore、
`CloudSyncPolicy.ets`、任何 native 文件或其他协议业务文件；在线云表仍精确为原 8 表。该入口不创建
Moonlight host、不访问 repository/native/network，不产生轮询、线程或后台任务，因此不会改变其他
组件的运行时路径或性能。U1-04 后续已按第 15.7.26 节完成；该 checkpoint 当时的下一 UI 任务为 U1-05，
U1-05 现已按第 15.7.27 节完成，当前下一 UI 任务为 U1-06。

`71e9902c9` 为图标增加 exact-path GPL-3.0-only REUSE override 与 Moonlight Game Streaming Project
contributors 归属，并让 Light 精确验证 REUSE、NOTICE、source offer、SBOM package/file/checksum/
license/relationships；权威计划的设置、toolbar、HUD 实施来源统一为 RustDesk 或协议无关公共构件。
禁用回调次数、enabled route、品牌加载失败 fallback mode 和 enabled/disabled tint 也都由组件实际
消费的 pure policy 覆盖。修复后两项 Hvigor、signed HAP、Light 与 diff check 重新通过。
`7eaad950b` 进一步补齐根 `LICENSES/GPL-3.0-only.txt` 和 exact hash 门禁、SPDX 单文件 package
verification code，并将 descriptor、`protocolIcon()` 与组件渲染 fallback 统一到唯一
`moonlightSystemFallbackIcon()` 字面资源映射；对应定向断言和双 Hvigor/Light 再次通过。
复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成最终复核，P0/P1/P2/P3 全 0；
receipt `moonlight-u1-01-03-gpt5-7eaad950b-2026-08-11`。复核独立确认 GPL 正文/hash、SPDX 单文件
verification code、唯一 fallback 映射、RustDesk-only UI 来源和其他组件隔离全部闭环。

#### 15.7.26 U1-04 RustDesk 风格四步本地添加合同 checkpoint（2026-08-11）

`dd6ec9c5` 新增 dormant `MoonlightHostAddFlow.ets` 与 `MoonlightHostAddFlowPolicy.ets`。UI 只采用
RustDesk 既有 20vp 页面留白、36vp 圆形返回、20/12vp 标题层级、模式卡、44vp 字段/主按钮、
错误提示与单 add Sheet owner；四步为查找→验证→配对与信任→完成。未复制 RustDesk relay、TOTP、
credential 或保存状态，也未建立第二 Sheet owner。

自动发现使用独立 owner/generation key，外部 candidates/running 只有 exact key 匹配才可见；离开、
切手动、验证和重扫均 cancel-before-restart。验证、配对、信任、目录和保存使用 operation generation。
PIN 只接受 4 位数字，绝对 deadline 在 await 返回后再次校验；异常、返回、取消、过期和组件消失统一
停止 timer、取消 owner、增长 generation 并清除 PIN/expiry。证书指纹必须是 64 位 SHA-256；
changed certificate 在调用 trust port 前阻断，显式拒绝清 paired/temporary identity 并要求重新配对，
trust persistence failure 则保留 paired/pending 供安全重试。duplicate UUID 不创建第二条 host。

所有外部 callbacks 默认 fail closed。完成页只有在 local persistence port 返回
`localCommitted=true` 时设置 `savedLocally` 并调用 `onSaved`；当前 `HostListPage` 不传 discovery、
Host Control、trust、catalog 或 repository callback。它只增加 thin dormant route/owner token，并显式
向 picker 传 `moonlightProtocolAvailable: false`，所以组件不会在产品路径挂载，也不会启动 network、
native、repository、timer、thread 或后台工作。Moonlight 云路径继续 parked，在线表仍为既有 8 表。

新增 10 个 policy cases 后聚合为 161 tests / 21 describe；两项 Hvigor、signed HAP、Light、
117-file vendor 与 `git diff --check` PASS。最终 HAP SHA-256 为
`847874f51e54a4bac23c779fcb1c544cda7a6b7d17a6f473ba8c4da9c9937d97`，沙箱外 HDC 安装/启动成功；
点击禁用 Moonlight 后仍只有“添加远程主机”“Moonlight”“即将支持”，没有进入添加页。
复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`，修复 discovery fence、changed certificate、
reject retry 和 PIN lifecycle/deadline 后，最终 P0/P1/P2/P3 全 0。该 checkpoint 当时以 U1-05 为下一
UI 任务；它只能
增加 dormant save-and-open handoff，仍不得开放 picker 或伪造 local/runtime truth。

#### 15.7.27 U1-05 RustDesk 单 Sheet 保存后交接合同 checkpoint（2026-08-11）

`46a2e7d3` 新增 protocol-neutral `HostAddPostSaveHandoff`，只承载 destination、稳定本地主机 ID、
owner token 与 generation；禁止携带 host snapshot、route object、callback、secret 或协议私有状态。
`HostListPage` 只在共享 Add Sheet 的原生 `onDisappear` 后消费 handoff，不增加 fixed delay、第二 Sheet、
Navigation route、timer、network、native、repository 或 cloud 调用。目标页必须在 U1-06 按稳定 ID 从
本地 repository/cache 重读，不能直接信任 Sheet 回调中的对象副本。

`MoonlightLocalSaveResult` 分离 repository 的 `localCommitted` 事实与 `hostId` 的交接资格；正常
“保存并打开”只有已提交且 ID 有效才创建 `moonlight_catalog` handoff。`a73b8959` 在 repository port
前增加 `activeOperation/savedLocally` 门禁，使极快双击只能产生一次写入。`094a8b3b` 修复
`localCommitted=true + blank hostId`：仍保持 terminal committed 并禁止重写，只在 page active、Sheet
未 closing、owner exact 时安全关闭，不创建目录 handoff。所有迟到 owner/generation callback 均拒绝。

共享 handoff policy 当前 8 cases，覆盖 rapid tap、原生 Sheet animation、page close、stale owner、late
generation、invalid payload 与 committed-without-ID；Moonlight 聚合为 162 tests / 21 describe，均只声明
compile-registered。最终代码 `094a8b3b` 后两项 Hvigor、Light、117-file vendor、`git diff --check`、
signed HAP 与沙箱外 HDC 安装/启动/禁用点击均 PASS；HAP SHA-256 为
`89ab30e1327e9f902e2370cfa9308fc5a29f9d559e7aaedf2168becb5e3883af`（当前证书重签）。复用 reviewer task
`019fe966-d99a-7ce1-8b53-4ef725597053`，首轮唯一 P2 修复后最终 P0/P1/P2/P3 全 0。

该 checkpoint 未实现实际目录 Navigation 页面、主机详情、设置页、连接页或串流内浮层，也未开放
picker、真实保存、Host Control、runtime、NAPI 或云。UI 后续继续只以 RustDesk 与通用 Theme token
为设计/交互基线；VNC 只保留跨协议隔离与回归检查意义。U1-06 是唯一下一 UI 任务。

#### 15.7.28 U1-06～U1-12 本地 UI shell closeout（2026-08-11）

代码 checkpoint `2c37b0edf` 将后续 UI 合同落到当前源码，但保持所有真实能力 fail closed：

- `MoonlightHostDetailPage.ets`、`MoonlightAppCatalogPage.ets`、`MoonlightSettingsPage.ets` 和
  `MoonlightStreamPage.ets` 已注册到 Navigation。共享 RustDesk add Sheet 的原生 `onDisappear`
  handoff 只传稳定本地主机 ID；目录/详情按 ID 重读本地 records/cache，并用 owner/generation
  fence 刷新空、旧、部分、离线、主机忙、大目录和坏封面状态。
- `MoonlightLaunchSheet`、`MoonlightConnectStageOverlay`、`MoonlightSessionToolbar`、
  `MoonlightControlCenter`、`MoonlightControllerOverlay` 和 `MoonlightDiagnosticsHud` 已按 RustDesk
  语法与 Theme token 建立 UI 壳。它们不代表真实 launch、RTSP、首帧、OHAudio、实体手柄或 Sunshine
  连接可用；没有 runtime proof 时不发起网络/Host Control。
- Moonlight 设置统一进入一个 surface，共 9 个 section：快速、画面、音频、输入、网络安全、后台、
  诊断、云范围、Trust。公共 display/PIP 不重复，冗余“主机管理”已删除；首页是唯一主机管理入口。
  `SettingsSheetRoutePolicy` 统一解析连续 24–32 leaf route，每个入口都进入同一 bindSheet 生命周期。
- PC 新增独立灰色 Moonlight sidebar slot，FAB 仍传 `moonlightProtocolAvailable=false`；保持 0.58 parent
  opacity、唯一“即将支持”和点击零路由，不创建 timer、network、native、repository、cloud 或后台任务。
- 本次 fresh signed HAP 已由沙箱外 HDC 安装/启动到 PC `127.0.0.1:5555` 和手机 `127.0.0.1:5557`。
  唯一使用的截图证据为 `/private/tmp/moonlight-final-20260811-pc-full.jpeg` 与
  `/private/tmp/moonlight-final-20260811-phone-settings.jpeg`（对应 `.json` UI tree）；PC 证明 RDP
  主页面与独立灰色 Moonlight 栏位并存，手机证明设置副标题为“串流画面、音频、控制与本地安全设置”且
  没有“主机管理”。不引用旧截图。
- 两项强制 Hvigor 与 signed HAP 通过；162 Moonlight focused tests/21 describe 加 8 shared handoff
  cases 为 compile-registered，`ohosTest` 仍受 `00306054` 未注册阻塞。静态增量隔离确认没有改动
  RustDesk、RDP、SSH/SFTP、VNC 业务源、native、`CloudSyncPolicy` 或在线 8 表注册；用户未提交的
  `CloudStore.ets` 云同步改动明确不在本 checkpoint 内。

U1-06～U1-12 的完成含义是“本地 UI/路由/设置合同已落地”，不是产品已开放 Moonlight。当前 S1-01/S1-02
的唯一 remote-session registry/coordinator dormant contract 已在 `8b1ccd22` 完成；下一实现边界为 S1-03。
S1-05A 才接真实 HarmonyOS GameController
listener 与窄 typed NAPI，N2-09 才能由真实 Sunshine 与用户 ARM64 设备提供媒体/生命周期回执。

#### 15.7.29 U1 UI review-fix closeout（2026-08-11）

`6b0c1aa8` 收口了 U1 UI 增量复核发现，并保持所有 Moonlight 真实能力 fail closed：

- `MoonlightRecordPolicy.ets` 将旧记录可读字段与新写入 allowlist 分离；旧记录允许读入后 normalize，新写入拒绝旧设置路径；`MoonlightRecordPolicy.test.ets` 增加 baseline replay/normalization 回归。
- `MoonlightSettingsPage.ets` 的两个证书变化开关按安全合同固定为开启且不可操作，并解释变化时必须重新核对与配对；保存以 `localCommitted` 作为本地提交终态，即使回读确认暂失败也清理 dirty，避免重复写入；`MoonlightSettingsLocalService.test.ets` 覆盖 `readback_failed + localCommitted`。
- `MoonlightStreamPage.ets` 负责 bindSheet reopen timer 的 page-active、generation、取消和离开清理，避免离页后旧 timer 重开浮窗；PC sidebar 使用 `MoonlightBrandIcon` 官方几何可着色资源/回退图标，仍为 0.58 灰态、唯一“即将支持”、点击无 route。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 对 `2c37b0edf..6b0c1aa8` 复核，P0/P1/P2/P3 全 0；RDP、RustDesk、SSH/SFTP、VNC、公共输入、native/CMake/NAPI、`CloudSyncPolicy` 和现有云表注册未变更，用户 `CloudStore.ets` 排除且未暂存。
- 最新 fresh r2 证据只使用本次最新 HAP 重装后生成的文件：PC `/private/tmp/moonlight-final-20260811-r2-pc-full.jpeg`；phone `/private/tmp/moonlight-final-20260811-r2-phone-settings.jpeg`、`...-scroll.jpeg`；accordion `/private/tmp/moonlight-final-20260811-r2-moonlight-accordion.jpeg`、`...-lower.jpeg`；quick `/private/tmp/moonlight-final-20260811-r2-quick-sheet.jpeg`；network `/private/tmp/moonlight-final-20260811-r2-network-sheet.jpeg`，每项均有对应 `.json` UI tree。它们证明 RDP 主页未受影响、Moonlight 独立灰栏位存在、手机九段设置统一排版、无重复“主机管理”、网络安全开关为不可操作的安全状态。
- `default@OhosTestCompileArkTS`、`assembleHap` 均按强制命令重新 BUILD SUCCESSFUL；最终签名 HAP SHA-256 为 `7a723ce9b300d6b8e131006472ed2efa8d7985a8cd672385857e468a84181b87`；沙箱外 HDC 已在 `127.0.0.1:5555` 与 `127.0.0.1:5557` 安装并启动。`ohosTest` 仍因 `00306054` 未注册而不宣称设备 PASS。

本节完成的是 U1 UI shell 的审查收口，不是 Moonlight 串流能力发布。下一实现边界仍为 S1-01/S1-02；真实
Sunshine、媒体首帧、OHAudio/Surface、实体手柄和 ARM64 长稳验收仍需外部 runtime receipt。

#### 15.7.30 S1-01/S1-02 dormant session coordinator closeout（2026-08-12）

`8b1ccd22` 将 S1-01/S1-02 落成可复核但仍 dormant 的连接合同，未打开 Moonlight 产品能力：

- `RemoteProtocol.moonlight` 已进入通用状态/能力类型；clipboard、file transfer、multi-display 明确 unavailable，Moonlight streaming 需要 runtime、Host Control、streaming transport 三项 truth 同时成立，当前因无 runtime port 继续为 false。
- `ActiveRemoteSessionRegistry` 保持唯一 active-session owner。Moonlight 只在 future native launch accepted 后写入最小 marker，endpoint 固定为空；transient host address 不进 AppStorage、registry、local record 或云。清理要求 exact ownerScopeId/accountGeneration/sessionId/protocol，避免 stale callback 影响其他协议。
- 新 `MoonlightSessionCoordinator` 负责 scope/request validation、discovery/launch/first-frame/stream-stable/transport-loss/stop/cancel 过渡、generation/sequence fence、Surface ID 校验、跨协议仲裁和 owner/account 失效；无 socket、native handle、media queue、secret、cloud 或 background work。
- `MoonlightAppCatalogPage` 是唯一薄入口，未来只把一次性 host address 交给 runtime port；`MoonlightStreamPage` 监听 `AccountSessionCoordinator`，账户切换使旧 session 失效，页面退出取消 route-owned session 并退订。没有改 CloudStore 或任何现有协议业务实现。
- 新增 9 个 coordinator focused cases、1 个 capability case并注册测试列表；exact `default@OhosTestCompileArkTS` 与 `assembleHap` 在 `4548499c` 后均通过，签名 HAP SHA-256 为 `c4af9e1396acada1a213ba68bce9ce999f3cec9c3ffac7525a57382ffb866d0d`。HDC 已在 PC `127.0.0.1:5555` 和手机 `127.0.0.1:5557` 安装/启动。
- 本次视觉验收只使用 2026-08-12 新截图及 UI tree：`/private/tmp/moonlight-final-20260812-s1-final-pc-root.jpeg`、`...-pc-picker.jpeg`、`...-pc-picker-click.jpeg`。PC RDP 页面仍正常，Moonlight 维持灰色官方可着色图标与“即将支持”；点击后 route 仍为 `pages/HostListPage`。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 对 `6b0c1aa8..8b1ccd22` 做增量复核；在回执确认前，该条只记为 pending，不提前写成 review PASS。唯一下一实现边界为 S1-03，N2-09 与 S1-05A 仍需真实外部/设备证据。
- `4548499c` closes the first review findings: atomic shared-session reservation/promotion, prelaunch cancel and stop failure local-terminal cleanup, and strict post-launch native-session callback fencing. `647113a5` adds the actual 5-second watchdog and corrects the prelaunch-cancel contract test. The coordinator suite now has nine cases; exact gates after the final code checkpoint passed and the final deployed signed HAP SHA-256 is `95d9cc17067981b7e5c4bdae3ec7fe3d0de14060a0dc75e87b638dca328fe504`.
- The latest visual acceptance uses only fresh 2026-08-12 files captured after installing that final `647113a5` HAP: PC large-screen sidebar `/private/tmp/moonlight-final-20260812-s1-final4-pc-maximized2.jpeg`, PC picker/disabled-click `/private/tmp/moonlight-final-20260812-s1-final4-pc-picker2.jpeg` and `/private/tmp/moonlight-final-20260812-s1-final4-pc-picker-click.jpeg`, phone root/picker/disabled-click `/private/tmp/moonlight-final-20260812-s1-final4-phone-root.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-picker2.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-picker-click.jpeg`, and phone settings/accordion/bindSheet `/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-top.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-lower2.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-moonlight-accordion2.jpeg`, `/private/tmp/moonlight-final-20260812-s1-final4-phone-quick-sheet3.jpeg`; each was viewed during this checkpoint. PC RDP remains unchanged, the separate Moonlight sidebar slot is grey with “即将支持”, disabled clicks are no-ops, and the phone keeps the consolidated Moonlight settings section without a duplicate host-management entry.
- The reused reviewer task rechecked `6b0c1aa8..647113a5` and returned PASS with no actionable findings. The next implementation boundary remains S1-03; N2-09 and S1-05A still require external/runtime evidence.

### 15.8 N2：RTSP、视频、音频和媒体时钟

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| N2-01 | **CONTRACT PASS / DORMANT `db5865c53`**：定义 `MoonlightStreamConfig` requested/effective/offer，严格区分 capability intersection 与 negotiated | 36 focused；全量与 ASan/UBSan 476/476；双 ABI/HAP/NAPI 隔离不变 | UI 后续同时显示 requested/D1 effective/runtime effective，不猜测；当前无 runtime caller |
| N2-02 | **CONTRACT PASS / DORMANT `248e704ab`**：唯一 hidden adapter 把 N2-01 offer 映射到官方 common-c，并复用既有 owner 收束 process-global callbacks、11-stage/deadline/termination、setup-derived video/audio 与 secret cleanse | 21 focused；普通/ASan/UBSan 497/497；strict/analyzer/race harness、双 ABI/HAP/NAPI/include、双 Hvigor与合规通过；最终 `sol low` review 无 P0/P1/P2 | product media port unavailable，无 NAPI/UI/cloud caller；transport-ready 不是 first-frame；N2-03 只接 decode-unit bridge |
| N2-03 | **CONTRACT PASS / DORMANT `34d2ffa7a`**：bounded `DECODE_UNIT/LENTRY` projection、owned AU、SPS/PPS/VPS generation、IDR/backpressure/teardown；上游无 offset/decodeNumber | 8 focused；普通/strict/TSan 506/506、ASan/UBSan 三轮、analyzer、双 ABI/HAP/NAPI/include、双 Hvigor与合规通过 | product sink unavailable、first-frame 恒 false；N2-04 只接既有 decoder owner |
| N2-04 | **CONTRACT PASS / DORMANT `bee0ac1da`**：窄 sink/port 复用既有 decoder/renderer exact owner；H.264 Annex-B、typed admission/config recreate、output→NativeImage→actual swap 三段首帧 | 9 focused；全量/strict/TSan 515/515、ASan 三轮、analyzer、双 ABI/callback/HAP/NAPI/双 Hvigor通过 | archive 无 caller，不新增 singleton/NAPI/UI；HAP runtime proof 前仍 unavailable，N2-05 只加 Surface lifecycle |
| N2-05 | **CONTRACT PASS / DORMANT `7992279c7`**：pure-native exact-generation Surface lifecycle；无 Surface copy 前 typed drop，temporary suspend 保留 connection/decoder handle，exact rebind 后等新 IDR，同 generation resize 不清首帧 | 8 focused；全量/strict/TSan 523/523、ASan 三轮、analyzer、双 ABI/callback/HAP/NAPI/双 Hvigor通过 | 无 ArkTS/PIP/NAPI/product caller；423 paths、ABI、8 表、灰 FAB 和六项 truth 不变；S1-08 才接产品生命周期 |
| N2-06 | **CONTRACT PASS / DORMANT `8d2fd15b3`**：hidden `MoonlightAudioBridge` 完成 48 kHz exact stereo family-1 Opus multistream→interleaved S16LE；修正官方 null+0 PLC seam，冻结 owner/config/operation generation、有界 ownership、typed result 与 teardown | host normal 533 total/517 pass/16 既有 VNC fixture fail；10 个新增 audio tests 全 PASS；strict native、arm64/x86_64 native product、两 ABI Opus link probe PASS；后续 N2-07 已重新通过双 Hvigor | 只复用现有 pinned 1.5.2，不直接接 `audio_player`/OHAudio/NAPI/UI；audio ready 永不替代视频首帧；N2-07 已用独立 sink 复用现有 owner/queue；FAB、8 表、六项 truth 仍关闭 |
| N2-07 | **CONTRACT PASS / DORMANT `9272f1c9c`**：hidden exact-owner sink 只委托现有 `DispatchActiveNative`/`SuspendActiveNative`/`TakeActiveNative` 和 owner lease；完成 48 kHz stereo PCM、mute/focus/background/pause/resume/stop/cleanup generation fence | 10 focused 全 PASS；normal/strict/ASan/UBSan/最终 TSan 为 532 pass/16 既有 VNC fixture fail；双 ABI、双 Hvigor、signed HAP、Light 通过 | 不新增 renderer/registry/queue/worker/singleton/NAPI/ArkTS/product caller；音频不改变视频首帧或发布 truth；N2-08 已完成 |
| N2-08 | **CONTRACT PASS / DORMANT `57b1d7da4`**：hidden exact-generation media clock/stats；最多 256 槽，absent/zero 分离，network/decode/render/end-to-end/audio queue p50/p95/max，RTP/FEC/audio counter reset、节流和饱和合同 | 13 focused 全 PASS；normal/strict/ASan/UBSan/TSan 545 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 精确不变、双 Hvigor、signed HAP、Light 通过 | 私有 archive 无 caller 时不进入 `rdpnapi`；无 NAPI/ArkTS/UI/cloud/log/product caller；N2-09 外部 pending，N3-01 已完成 |
| N2-09 | **EXTERNAL PENDING**：真实设备完成 720p/1080p、30/60fps、2 小时、温控、前后台/PIP/旋转；H.264+Opus 为唯一 release blocker | 第 10.5 节阈值和录屏/log receipt；必须真实 Sunshine + 用户 ARM64 实机 | HEVC/AV1/HDR/7.1 不通过只保持关闭；外部回执完成后提交 `media-mvp` checkpoint |

### 15.9 N3：键鼠、触摸、实体/虚拟控制器和输入释放

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| N3-01 | **CONTRACT PASS / DORMANT `fe46025ef`**：hidden `MoonlightInputBridge`；exact session/owner/input/source generation、device/source/sequence/timestamp、固定 32 lanes/64-byte body、typed ordering/backpressure 与 neutral-release lifecycle；owner 路由复用唯一 Moonlight owner 和共享跨协议 lease | 12 focused 全 PASS；normal/strict/ASan/UBSan/TSan 557 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light 通过 | 未修改公共 InputHandler；archive 无 caller 时不进入 `rdpnapi`；无 NAPI/ArkTS/UI/cloud/product caller；N3-02 下一 |
| N3-02 | **CONTRACT PASS / DORMANT `a552b30a2`**：hidden bounded keyboard mapper；HarmonyOS namespace→官方 prefixed VK、双侧 modifier once/lock、严格 UTF-8 text、逐命令状态提交、精确续传、跨设备 key-up 拒绝、16-command 全释放、物理 Esc 本地逃生 | 15 focused 全 PASS；normal/strict/ASan/UBSan/TSan 572 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light 通过 | archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-03 下一 |
| N3-03 | **CONTRACT PASS / DORMANT `1787da821`**：hidden bounded pointer mapper；absolute/relative、官方五键与双轴滚轮、physical-pixel content rect、letterbox/fill/1:1/pan、四向旋转、DPI/fraction residual、exact generation 与精确续传 | 18 focused 全 PASS；normal/strict/ASan/UBSan/最终 TSan 590 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light 通过 | capture/constraint/raw-relative 仅解析能力且平台 unavailable；archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-04 下一 |
| N3-04 | **CONTRACT PASS / DORMANT `ebd2fa0bc5`**：官方 28-byte direct touch、稳定 10-contact id、cancel/cancel-all、rotation/content transform 与 overlay lifetime ownership；触控板复用 pointer mapper 完成一/双/三指和拖拽，固定 3 contacts/16 lanes、exact generation 与 retry | 21 focused 全 PASS；normal/strict/ASan/UBSan/最终 TSan 611 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light/vendor 通过 | host direct capability 与平台 listener 均 fail closed；archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-05 下一 |
| N3-05 | **CONTRACT PASS / DORMANT `1aadfba24`**：official arrival/full-state 参数投影；API 23 button/axis/trigger/hat、7%/13% deadzone、Y 反向、stable slot 0、background neutral、disconnect active-mask clear、exact generation 与 retry | 16 focused 全 PASS；normal/strict/ASan/UBSan/最终 TSan 627 pass/16 既有 VNC fixture fail；analyzer、GameControllerKit 双 ABI probe、ABI 不变、双 Hvigor、signed HAP、Light/vendor/TOTP 通过 | 一槽直到双手柄真机证据；archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-06 下一 |
| N3-06 | **CONTRACT PASS / DORMANT `baa9cafef`**：official API∩physical-device evidence；rumble/trigger rumble/RGB LED/adaptive trigger/motion/battery typed command、single retry、200Hz/120s、exact owner/device/operation generation 与 release lifecycle | 16 focused 全 PASS；normal/strict/ASan/UBSan/TSan 643 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light/vendor/TOTP 通过 | API 23 evidence 全 false，unsupported 零 port 调用；archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-07 下一 |
| N3-07 | **CONTRACT PASS / DORMANT `02cb13aae` + `36b4e13df` + `337c4f35e` + `ee073afcb`**：bridge admission 在 mapper release 前原子关闭且只放行 lifecycle release；统一 touch→pointer→keyboard→controller→bridge，覆盖 12 trigger、component failure/owner loss、pending/suspended stop、exact terminal replay、stale stop 和 local-terminal | 26 focused 全 PASS；normal/strict/ASan/UBSan/TSan 669 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light/vendor/TOTP 通过 | archive 无 caller 时不进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/product caller；N3-08 下一 |
| N3-08 | **CONTRACT PASS / DORMANT `fef723770` + `6787cc3fb`**：fixed-capacity physical/virtual aggregator/layout validator；独立 boundary retry/resume、retired-lane tombstone；full-state 只走 N3-05→N3-01→common-c | 28 aggregator/17 mapper tests 全 PASS；normal/strict/ASan/UBSan/TSan 698 pass/16 既有 VNC fixture fail；analyzer、双 ABI、ABI 不变、双 Hvigor、signed HAP、Light/vendor/TOTP 通过 | 20 次双向换源与旧回放；真实 listener/NAPI 留到 S1-05A；无第二 owner/port/slot/queue、公共 InputHandler/ArkTS/UI/云/product caller；U1-05 已完成，U1-06 下一 |

### 15.10 U1：统一视觉、添加流程、主机/目录与设置

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| U1-01 | **PASS `c38ff6265` + `71e9902c9` + `7eaad950b`**：冻结 RustDesk FAB→`HostProtocolPicker`→`RustDeskAddFlow` 的单 Sheet 路由和视觉合同；新增纯 `HostProtocolPickerPolicy`，不重构 RustDesk 业务状态 | RustDesk/Moonlight enabled route 等价；Moonlight disabled callback=0；single owner/返回/关闭 | 未修改 RustDesk 或其他协议页面；入口提交可独立回滚 |
| U1-02 | **PASS `c38ff6265` + `71e9902c9` + `7eaad950b`**：固定 Moonlight Qt 官方 SVG 的确定性单色可着色转换、provenance/SHA/NOTICE/SPDX/source offer/REUSE/license text；扩展 `ProtocolIconPolicy` 为 system/branded descriptor | 原始 SHA `6fd0ee4f...`、本地 SHA `4f5ef547...`、package verification；exact Light/vendor/HDC 渲染通过 | 加载失败保留 `gamecontroller_fill`；不凭记忆重绘 |
| U1-03 | **PASS `c38ff6265` + `71e9902c9` + `7eaad950b`**：Moonlight 继续调用 RustDesk 同款 `protocolOption`：末项、灰色、0.58 opacity、唯一“即将支持”、点击零副作用；只由 `moonlightProtocolAvailable` 控制未来启用 | disabled/enabled dispatch、唯一 fallback resource、tint policy、HDC 点击零导航；双 Hvigor与 signed HAP 通过 | `ResourceFabPicker` 未改；默认 false，不开放添加页或 runtime |
| U1-04 | **CONTRACT PASS / DORMANT `dd6ec9c5`**：新增 `MoonlightHostAddFlow.ets` 与纯四步 state policy；RustDesk header/步骤/模式卡/字段/按钮和同一 add Sheet owner；所有外部 port 默认 fail closed | 10 cases：自动/手动、重复 host、PIN/deadline、trust/change/reject、dirty dismiss、operation/discovery owner-generation；双 Hvigor、HDC、Light/vendor/review PASS | picker 仍 false；只有 `localCommitted=true` 才成功；未接 Host Control/repository/native/cloud，U1-05 已完成 |
| U1-05 | **CONTRACT PASS / LOCAL ONLY `46a2e7d3` + `a73b8959` + `094a8b3b` + `db750cdb`**：“保存并打开”复用 `HostAddConnectionHandoffPolicy.onDisappear`；本地主机保存通过现有 `MoonlightRepositoryPort`，只交接稳定 ID + owner/generation，禁止 fixed delay、第二 Sheet、快照传递；提交事实、恢复状态和目录资格分离 | shared handoff 加 1 个 existing-host detail case；新增 8 个本地 persistence cases 与 1 个 partial/uncertain retry case；双 Hvigor、HDC、review PASS | 只写已有 `moonlightlocalrecords` 的 `localOnly=1` host/trust rows；不注册云表、不上传、不接 Host Control/runtime/cloud；partial/uncertain 禁止普通重试 |
| U1-06 | **UI CONTRACT PASS / DORMANT `6b0c1aa8`**：`MoonlightHostDetailPage.ets`/`MoonlightAppCatalogPage.ets` 已注册；HostList 只做稳定 ID handoff/薄导航；目录读 local records/cache 并 owner/generation-fenced 刷新 | 空/旧缓存/部分失败/离线/主机忙/大目录/封面坏/搜索/焦点 | app cache 失败不删 profile；真实 Host Control/online status 仍关闭 |
| U1-07 | **UI CONTRACT PASS / DORMANT `6b0c1aa8`**：`MoonlightLaunchSheet`、connect-stage overlay 与 preflight 壳已接目录；显示 effective config/网络/输入/主机忙，runtime proof 前不 launch | 400ms/3s/10s、取消、降级、重复开始、主机现有 app | UI 不宣称真实 launch/RTSP/首帧；S1-01/S1-02 装配 coordinator |
| U1-08 | **UI CONTRACT PASS `6b0c1aa8`**：`SettingsAccordionPolicy` 在 VNC 后、安全前增加 Moonlight；单 card、RustDesk/Theme token、64vp header/20vp radius 语法一致 | section order、折叠互斥、light/dark/xl/大字号 | 公共 display/PIP 不重复；不在 HostListPage 硬编码独立视觉 |
| U1-09 | **UI CONTRACT PASS `6b0c1aa8`**：`SettingsSheetRoutePolicy` 统一解析连续 24–32 Moonlight leaf routes，所有入口进入同一 bindSheet 生命周期 | 无重复/无 magic number/返回/rapid route | 不复用 VNC 12–22/Terminal 23；不允许大杂烩跨入口跳转 |
| U1-10 | **UI CONTRACT PASS / LOCAL ONLY `6b0c1aa8`**：快速、画面、音频、输入、网络安全、后台、诊断、云范围、身份 Trust 九个 leaf；本地 settings service 负责 normalize/read/save；legacy readable metadata 与 new-write allowlist 已分离 | global/host/profile/session、能力禁用原因、draft/commit failure、reset inheritance | 删除冗余“主机管理”；首页负责 host management；session 值不自动上云 |
| U1-11 | **UI CONTRACT PASS / PARKED CLOUD `6b0c1aa8`**：云范围页消费 D3 状态并明确 local-only/disabled；不显示物理表、不注册 `moonlightrecordv1` | 无账号/未验证账号/crypto off/bootstrap/pending/error/delete cloud | 本轮不改 CloudStore；queued/quarantine 不得宣称 synced |
| U1-12 | **PARTIAL VISUAL ACCEPTANCE `6b0c1aa8`**：Theme/Breakpoint/无障碍 token、PC 300vp 独立 sidebar、latest fresh r2 PC/phone/accordion/quick/network/lower sheets 已验收；证书变化开关显示为强制安全且不可操作 | light/dark/accent/wallpaper/halo/reduce motion/transparency、200% 字体、读屏、键盘/手柄焦点 | 真实能力开放后仍需重做可达 add/connection/stream runtime 验收；只使用当次 fresh evidence |
| U1-13 | **CONTRACT PASS / LOCAL ONLY `db750cdb`**：`MoonlightLocalHostService` 将 RustDesk 风格四步添加流的完成态接入已有本地仓储；host/trust 两行使用 stable ID、lease/generation fence、readback 与前向补偿/复活；Sheet `onDisappear` 后才进入详情/目录 | 8 local host persistence cases、1 recovery policy case、1 detail handoff case；双 Hvigor、signed HAP、HDC PC/phone、增量 reviewer PASS | Moonlight 仍 `moonlightProtocolAvailable=false`；无 network/native/media/input/cache/cloud/release truth；云同步继续 parked |

### 15.11 S1：连接页、浮层、PIP、后台和全生命周期

| ID | 文件与精确动作 | 必须验证 | 完成证据/提交点 |
| --- | --- | --- | --- |
| S1-01 | **CONTRACT PASS / DORMANT `647113a5`**：在 `RemoteSessionState.ets`、`ActiveRemoteSessionRegistry.ets`、`RemoteSessionCapabilityPolicy.ets` 增加 Moonlight；registry 只存最小、无 endpoint 的恢复 marker，并用 owner/account/session/protocol 精确清理；reservation/promotion 防止跨协议覆盖 | protocol union、account generation、capability truth、旧版本 marker；9 个 coordinator cases 加入 compile-registered suite | clipboard/file transfer/multi-display 等不支持能力明确 false；host address 只允许作为未来 runtime 输入，不能进入 registry/AppStorage |
| S1-02 | **CONTRACT PASS / DORMANT `647113a5`**：新建 `MoonlightSessionCoordinator.ets`，串起 discovery→launchAccepted→firstFrame→streamStable→stop/cancel/transportLost；`MoonlightAppCatalogPage` 与 `MoonlightStreamPage` 仅做薄装配；stop failure/actual watchdog timeout 与 native session callback fence 已补齐 | runtime/Host Control/transport 三重 gate、runtime port 缺失、重复 start、跨协议仲裁、surface 顺序、迟到 callback、owner/account 切换、精确 stop 清理；复用 reviewer PASS | 不建立第二个 active remote session；无 common-c/NAPI/OHAudio/Surface/product caller，真实能力与 picker 继续关闭 |
| S1-03 | **CONTRACT PASS / DORMANT `75d769c2`**：`MoonlightSessionCoordinator` 增加 owner/account/host/app 精确过滤的 snapshot subscription；`MoonlightStreamPage` 按页面/账号生命周期绑定、退订、取消和清理 elapsed timer，连接浮层消费真实 phase/error/degradation/first-frame；disconnected 文案单独收束 | 快照立即回放、foreign route 不可见、scope 变化清 null、首帧前不显示 connected、取消/stop/failed/disconnected 收束、监听器异常隔离；新增 coordinator scoped-delivery case，UI policy 增加 disconnected 断言；复用 reviewer PASS | 仍不打开 picker、Host Control、transport、media、input、OHAudio/Surface、NAPI、云或 release truth；技术码保持脱敏/可诊断 |
| S1-04 | **CONTRACT PASS / DORMANT `665df714`**：`MoonlightSessionToolbar` 完成 sm phone/pad edge rail、md/lg 5/7 项、xl 顶部工具条与 RustDesk 主题 token；edge rail 使用 360vp 上限滚动，non-xl 使用显式收起，xl 才使用 pin/5 秒自动收起；`MoonlightStreamPage` 传入 Sheet 状态并按 breakpoint/menuOpen watch 协调 timer | responsive layout、bounded Scroll、collapse/pin/hover、queued callback 最新策略复核、safe area/44–50vp/危险间距；新增 Sheet 开关与 xl→lg policy cases；fresh PC/phone HDC evidence | 不复制 `RemoteSessionTopBar` 的硬编码白色；不接 runtime/media/native/input/cloud/release truth |
| S1-05 | 复用 `RemoteModifierHandle/Panel`、`RemoteShortcutSurface`，通过 capability/catalog 配置；打开 L3 前统一 input flush | once/locked、拖动/吸附、组合键完整、关闭归零 | 不 fork 修饰键状态机 |
| S1-05A | 将实体 GameController native listener 与 `MoonlightControllerOverlay` 的窄 typed NAPI ingress 接到 N3-05/N3-08；实体 arrival/state 和虚拟语义事件均由 native 聚合 full-state，再只走 N3-01/common-c | connected/disconnected、ABXY/dpad/stick/trigger、active-mask=0 source handoff、failed removal 禁止接管、编辑零发送、backpressure、20 次前后台/模式切换 | ArkTS 不编码/直发协议；不接公共 `InputHandler`，不建第二 owner/slot/queue；真实设备 receipt 前 capability false |
| S1-06 | **PASS `1af10374`**：复用现有单 Sheet owner，将设置收敛为画面、音频、控制与手柄、网络与安全、诊断、配对与信任六个 Moonlight 专属 bindSheet；删除隐藏 quick/background/cloud 路由，协议独有后台/重连项归位 | 草稿/保存、异常保护、账号 lease、commit 后 durable readback、手机进程重启回读、PC/手机逐页最新截图 | 不嵌套 bindSheet；公共显示/PIP/音量/主机管理去重；云同步 PARKED |
| S1-07 | 新建 `MoonlightDiagnosticsHud.ets`，复用现有 drag/snap/safe-area policy；native 低频 snapshot，compact/expanded | unavailable=`—`、采样节流、拖动不触发远端输入、脱敏复制 | 默认关闭，性能开销达标 |
| S1-08 | 接 `NativeSessionHandles`、PIP policy、background task、音频焦点、Surface rebind；无 Surface 时按 N2 策略，回前台请求 IDR | 前后台/PIP/锁屏/旋转/折叠/自由窗/来电/焦点/强杀 | 20 次循环无旧画面/残音/悬挂输入 |
| S1-09 | 实现有限预算重连与网络切换：冻结输入、停止旧 generation、重新协商、保留静帧并标“画面已暂停” | Wi-Fi↔蜂窝、IPv4↔IPv6、断网/恢复、用户取消、预算耗尽 | 不并行两个 common-c connection |
| S1-10 | 实现 disconnect/quit 两命令和 teardown 序：input neutral→stop new callbacks→media/control/network→audio/decoder/renderer→background/PIP→registry marker；主机 quit 结果独立 | 每阶段失败/超时、重复 stop、账号切换、进程回收 | 本地 cleanup 不被远端无响应阻塞；`session-lifecycle` checkpoint |

### 15.12 R1：端到端矩阵、安全、性能、合规和灰度

| ID | 工作包 | 必须通过 | 失败处理 |
| --- | --- | --- | --- |
| R1-01 | 自动测试总矩阵 | Moonlight unit/contract/fuzz/native；现有 RDP/RustDesk/SSH/VNC/cloud/backup/settings/session 全回归 | 任一旧协议回归先修复，不以“无关”跳过 |
| R1-02 | 仓库强制门禁 | `git diff --check`、`default@OhosTestCompileArkTS`、`assembleHap`、双 ABI/native tests、Light compliance | 任何失败记录 blocker，不引用旧 session |
| R1-03 | 真机/主机功能矩阵 | 新装、升级、device-local、验证/未验证账号、配对、目录、launch/resume/disconnect/quit、H.264+Opus、键鼠/触摸/手柄 | 单格 pending 不进入支持声明 |
| R1-04 | 网络和长期稳定 | LAN/IPv6/NAT64 可用场景、丢包/抖动/乱序/MTU、切网、2h/8h、20/100 次连接循环 | 明确 capability/范围降级或 blocker |
| R1-05 | 数据生命周期 | 双设备并发、账号 A↔B、登出/清数据/卸载、cloud-first、tombstone、selection、restore、磁盘满/强杀 | 任何跨 owner/secret 泄漏为发布阻断 |
| R1-06 | 安全评审 | TLS/cert change/pairing/legacy SHA-1/secure store/memory zero/log redaction/fuzz/advisory/minimum Sunshine | 高危项不允许灰度豁免 |
| R1-07 | UI/人因/无障碍 | 第 8.14 节任务录屏、热区、误触、读屏、焦点、四断点、主题、减少动效/透明度 | 入口可发现但危险动作必须防误触 |
| R1-08 | 合规交付 | exact source archive、patches、SBOM、licenses/notices、官方品牌 provenance、隐私/数据安全说明 | `NOASSERTION` 或缺失 source offer 保持 blocker |
| R1-09 | 独立复核 | reviewer 按代码范围和本计划逐项检查 owner/generation、云、native teardown、UI capability truth；修复后重跑受影响及全门禁 | 未解决 P0/P1 问题不合并 |
| R1-10 | 灰度顺序 | 先内部 host-control→内部 streaming→小比例 LAN H.264→扩大设备矩阵；cloud physical/table scope 后开，identity 永远最后且可继续关闭 | crash/黑屏/数据错误/安全信号触发远端 UI 开关关闭和版本回滚，不删除用户本地数据 |

### 15.13 每阶段交接单和最终 Definition of Done

每个阶段结束时必须留下同一种交接单，后续模型只从该交接单和仓库状态继续，不凭聊天记忆重做：

~~~text
阶段/任务 ID：
基线 branch / HEAD / main：
本提交修改文件：
明确未修改的相邻系统：
合同已实现：
定向测试与结果：
全量门禁与结果：
真机/AGC/主机证据路径：
许可证/SBOM/品牌证据：
当前 feature flags：
已知限制与 blocker：
下一任务唯一入口条件：
回滚 commit/动作：
~~~

Moonlight 能从“即将支持”变成可点击，仅当下列事实同时成立：

- 官方品牌资产与协议依赖 provenance 完整，许可证/SBOM/source offer/Light 通过；
- 当前 local-only rollout 的 owner-scoped 本地存储、账号切换、删除和备份恢复无数据越界；
  parked 的 `moonlightrecordv1`/CloudSync 不作为本轮入口前置，也不得被入口代码创建或注册；
- 真实 Sunshine 安全版本完成配对、目录、launch、H.264+Opus、至少键鼠/触控和一类已承诺手柄；
- 视频首帧、音频、输入释放、Surface/PIP/后台/切网/停止的 owner+generation 证据完整；
- 添加、设置、目录、启动、浮层、错误和删除流程在四断点、主题、无障碍下通过；
- 两项 Hvigor、native 双 ABI/测试、`git diff --check`、Light、独立复核和旧协议回归全部为当次新结果；
- 所有未完成高级能力保持隐藏/禁用并有真实原因，不影响 MVP 的诚实交付。

在此之前，当前灰色 Moonlight FAB 入口和“即将支持”就是唯一正确的用户可见状态。

### 15.14 当前源码事实、已创建文件与唯一继续点（2026-08-12）

本节是后续执行者进入仓库后的防漂移索引。它只记录当前分支中已经存在且有证据的事实；UI shell 文件已经创建，但
“已存在”只代表代码合同与本地 UI 壳落地，不代表真实 Sunshine、Host Control、首帧、实体手柄或云能力开放。

| 层次 | 当前源码事实 | 当前可声明能力 | 下一任务边界 |
| --- | --- | --- | --- |
| 领域模型 | `MoonlightModels.ets`、`MoonlightRecord.ets`、领域 policy/state、删除影响/执行、云状态和备份策略已存在；D1-D3 共 138 个测试用例 | DTO、canonical/hash、19/20 列 envelope、冲突、设置裁剪、feature truth、session 状态、删除 exact preview/partial terminal 和备份/恢复裁决可编译 | D1 合同只有发现缺陷时才回开；U1 删除确认只消费既有 preview/impact/result，不再平行定义语义 |
| 本地数据 | `MoonlightStoragePolicy.ets`、`MoonlightRepository.ets`、`MoonlightAppCache.ets`、`MoonlightAppCacheService.ets`、`MoonlightDeletionCommandService.ets` 已存在；`CloudStore.ets` owner schema 为 v5 | owner-store 中 19/20/16 三表、lease fenced local-first upsert/tombstone、目录 cache 与有界 LRU；V3 restore 最终只写 local overlay；本地删除 exact set 单事务并清关联 journal/runtime state | D3 本地命令不再回开；N1 secure identity/Host Control 只实现端口，D2-07 后才实现 cloud terminal port；不得另建删除存储或偷偷注册云表 |
| 账户生命周期 | `MoonlightDataLifecycleBarrier` 已接入 `SensitiveDataBarrier` 和 `AccountSessionCoordinator`；无 runtime port 时安全 no-op | 账户切换顺序、失败回开旧 gate 和新 lease bind 的纯合同已编译 | N1/S1 注册唯一 runtime port 后补真实 session/pairing/native drain；页面不得旁路 barrier |
| 云适配 | exact 19 列 adapter、row-sensitive transfer、五 scope selection store、dormant materializer 和独立云状态 policy 已存在；`CloudSyncPolicy.TABLES` 仍是原有 8 表 | 可以验证/隔离/本地物化候选 row，所有结果明确 `cloudAttempted=false`；状态不会把 pending/quarantine 伪装成 synced | D2-07 必须等三环境 AGC receipt；之后才做 D3-01 coordinator、cloud-first promotion 和 D3-08 |
| 云数据 | `moonlightrecordv1` 是唯一未来分布式物理表；`moonlightlocalrecords` 和 `moonlightappcache` 永远本地 | 19 列 schema 已在 ARM64 API 24 owner-store 实例化和重开验证 | cache 不进云/备份；local mirror 只有 promotion 后才投影；identity 继续默认关闭 |
| 便携备份 | Backup V3 optional Moonlight descriptor、cloud/local 双 section、exact admission 和 local-only resolver 已存在 | redacted=settings/host/profile，full 额外 trust candidate；identity/secret/cache/marker 永远排除；旧 V3 可读 | cloud-enabled restore promotion 与设备故障矩阵仍 pending；不能另建含 identity 的“完整备份”旁路 |
| Native | N1-01～N1-08、N2-01～N2-08、N3-01～N3-08 均已 checkpoint；N3-08 `fef723770` + `6787cc3fb` 增加 fixed-capacity physical/virtual aggregator、layout validator、native full-state seam、staged handoff 与 retired-lane tombstone；product 无 caller，archive object 未进入 `rdpnapi` | 可声明固定上游、official common-c compile-link、owned video/PCM、共享 audio owner、有界 stats、exact generation-fenced dormant input admission/release、各 mapper、feedback、统一 lifecycle flush 与控制器 source arbitration 合同；HAP runtime backend 仍 unavailable，不能声明真实配对、目录、launch、解码、音频、实体手柄、输入、feedback 或首帧可用 | N2-09 等真实 Sunshine/ARM64 外部回执；S1-05A 才接真实 GameController listener/typed NAPI；U1-06 不解除 runtime、云表或发布 truth 门禁 |
| UI | U1-01～03 提供 RustDesk 同款灰色 picker、PC 独立 sidebar slot 与官方图标；U1-04/05 建立 RustDesk 风格四步 add 与原生 Sheet `onDisappear` 稳定 ID handoff；`2c37b0edf` 完成 U1-06～U1-12 本地-only UI shell；`75d769c2` 完成 S1-03 snapshot binding；`fae7c36dd` + `f7f39c0f` + `665df714` 完成 S1-04 toolbar/control-center contract，并保持 `moonlightProtocolAvailable=false` | 可声明统一 RustDesk/Theme UI 合同、首页主机管理、local records/cache 读取、9 section bindSheet 路由、connection overlay 的 dormant state、响应式 session toolbar/control center 和 fresh PC/phone 壳验收；不能声明真实配对、保存、Host Control、online catalog、launch、首帧、实体 listener、云同步或串流可用 | S1-05A 接 native GameController/typed NAPI；S1-06/S1-07/S1-08 按 runtime 前置继续；N2-09 需真实 Sunshine/ARM64 receipt；picker enable 仍需所有 runtime truth |
| 品牌 | Moonlight Qt 官方 SVG 与确定性单色转换已固定原始/本地 hash，provenance/NOTICE/SPDX/source offer 已落盘，系统 Symbol 保留为加载失败回退 | HDC light/disabled 视觉、资源打包和 Light 合规门通过，可声明入口品牌资产完成 | 图标存在不代表协议可用或官方背书；runtime truth 继续关闭 |
| 验证 | `665df714` 后两项 exact Hvigor、signed HAP、diff/isolation 与 fresh sandbox-external HDC 安装/启动均通过；最终当前工作区 HAP SHA-256 为 `cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`；只使用本次最终 HAP 新抓取并查看的 `moonlight-s104-final-cb1086-*` PC/phone root、max、picker、disabled-click 截图；165 个 documented Moonlight focused tests/21 describe + 8 个 shared handoff cases 仅 compile-registered；reviewer PASS P0/P1/P2=0，P3=1 为可接受的 ArkUI timer 单测可测性限制 | 可声明 local-only UI shell、RustDesk 风格 add/save handoff、settings consolidation、disabled fail-closed 隔离、dormant connection-stage snapshot binding 和 S1-04 toolbar/control-center contract；不声明 Hypium、真实添加/保存/配对/目录在线刷新、实体 listener、真实 Sunshine、首帧或串流可用 | `ohosTest` 任务仍未注册；S1-05A、S1-06/S1-08 和 N2-09 等待后续 runtime/外部阶段；用户 `CloudStore.ets` 改动不属于本 checkpoint |

当前数据流只能是：

~~~text
UI（首页主机管理；目录/详情/设置/串流 shell 已存在；FAB 仍禁用，所有 runtime port fail-closed）
  -> MoonlightLocalViewService / MoonlightSettingsLocalService（按稳定 host ID 读本地 records/cache）
  -> MoonlightHostService / MoonlightRepository（真实 Host Control/runtime 仍 unavailable）
  -> moonlightlocalrecords + cloudsyncjournal（仅已有 local commit path；不创建云表）
  -> D3 lifecycle barrier（账号切换前 drain；runtime port 尚未注册）
  -> D3 deletion exact preview -> local transaction / fail-closed external port
  -> D2-08～D2-10 dormant validate/materialize/projection（已实现，零 cloud I/O）
  -> Backup V3（cloud/local 双 section）-> restore resolver -> localonly=1
  -> [D2-07 尚关闭：不得调用 Moonlight setDistributedTables]
  -> [AGC dev/test/prod receipt 齐全后才可能启用 moonlightrecordv1]

Sunshine common-c runtime / production transport / media / input 当前仍不在这条已实现链路
中；N1-08 typed NAPI 可以被加载，但 product runtime port 会在 DNS/socket/TLS 前返回
`runtime_proof_required`，不会实例化可用的 N1-06/N1-07 pairing/Host Control backend。
因此不能据此声明 serverinfo、pairing、catalog、launch 或 streaming 可用。
~~~

后续模型每次只领取一个最小任务 ID，并严格执行以下循环：

1. 运行 workspace status，读取 `CURRENT.md`、`QUEUE.md`、`STATE.json` 和实施台账；以 Git 和文件为准，不以聊天摘要猜测。
2. 在台账中确认该 ID 的前置任务均为 `PASS`；如果前置是 `EXTERNAL PENDING`，只做被计划明确允许的 dormant/fail-closed 部分。
3. 列出本任务允许修改的精确文件和明确不允许触碰的邻接协议；发现公共抽象需要改动时，先在计划中补充原因和回归面。
4. 先增加能失败的定向测试或可重复探针，再实现最小合同；不使用硬编码 true、空回调、虚构 receipt 或仅 UI 演示推进状态。
5. 核对 owner、account generation、storeInstance/session generation、取消、迟到 callback、事务失败、日志脱敏、能力降级和 teardown；任何一项无合同就不提交。
6. 执行定向验证、`git diff --check`；阶段检查点执行项目规定的 `default@OhosTestCompileArkTS`、`assembleHap`、受影响 native/双 ABI 和 Light 门禁。
7. 需要运行时事实的任务必须保存 HAP/AppSpawn、RDB、AGC、Sunshine 或用户真机 receipt；模拟器证据不得冒充 API 23/实体手柄/用户实机结果。
8. 更新实施台账中的状态、证据、blocker 和唯一下一任务；同步 `CURRENT/QUEUE/STATE`，再用精确文件列表形成一个可回滚提交。
9. 只有当任务合同、测试和对应门禁均通过时标记 `PASS`；“代码写完”“构建通过”“请求已排队”均不是产品能力完成。

N2-08、N3-01～N3-08 已完成并保持 dormant。N2-09 只能由真实 Sunshine 与用户 ARM64 实机
提供媒体、温控、网络和生命周期回执，当前为 EXTERNAL PENDING。N3-08 已固定纯 native
physical/virtual full-state 聚合、remove-first handoff 与布局 validator；真实 HarmonyOS GameController
listener 和窄 typed NAPI 仍只在 S1-05A 接线。U1-01～U1-12 已完成 local-only UI shell：Moonlight
直接复用 RustDesk FAB/现代协议选择/单 Sheet 路由基线，接入官方几何可着色图标，以 `dd6ec9c5` 建立四步
本地添加 component/policy，并以 `46a2e7d3` + `a73b8959` + `094a8b3b` 建立无 fixed delay/第二 Sheet
的稳定 ID 保存后交接合同；`2c37b0edf` 再落地首页主机管理、主机详情/应用目录、9 段设置和
launch/连接/串流 UI shell。picker 仍保持灰色“即将支持”点击零副作用，全部外部 port 默认 fail closed。
S1-01/S1-02/S1-03/S1-04 已完成 dormant registry/coordinator、connection-stage snapshot contract 和 RustDesk
风格 session toolbar/control-center；不得把 cache 或请求态伪装成在线/已刷新，也不接真实 Host Control/runtime/cloud。
当前唯一直接实现边界改为 S1-05A：只接真实 HarmonyOS GameController listener 与窄 typed NAPI，保持
ArkTS 不编码/直发控制器线协议；不得因此打开 streaming、媒体、首帧、FAB 或 cloud truth。
MVP feature flag 保持 false，不接 Moonlight runtime、NAPI 或云，也不改变 video
first-frame、FAB、streaming 或 protocolAvailable。
D2-05/06 由 AGC 外部环境提供证据，D2-07 依赖二者；D3 的 cloud terminal、真实
unpair 和多设备矩阵分别等待 D2-07、N1 Host Control 和外部设备。任何执行者都
不得因为云端受阻而把 `moonlightrecordv1` 塞入现有八表注册清单，也不得因为
UI shell 或模拟器截图已存在就打开 runtime、media、input、first-frame 或 release truth。

### 15.15 S1-03 实际落地与验收交接单（2026-08-12）

阶段/任务 ID：S1-03 connection-stage snapshot contract

基线 branch / HEAD / main：`codex/moonlight-complete-upgrade` / `75d769c2` / `main@aeb0cdac5`

本提交修改文件：

- `entry/src/main/ets/pages/MoonlightStreamPage.ets`
- `entry/src/main/ets/services/MoonlightSessionCoordinator.ets`
- `entry/src/main/ets/services/MoonlightUiPolicy.ets`
- `entry/src/test/MoonlightSessionCoordinator.test.ets`
- `entry/src/test/MoonlightUiPolicy.test.ets`

明确未修改的相邻系统：`CloudStore.ets`（用户未提交改动）、RDP/RustDesk/SSH/SFTP/VNC 业务页、
公共 `InputHandler`、common-c/native/CMake/NAPI、GameController/OHAudio/Surface、CloudSyncPolicy、
现有 8 张云表和其它模块的性能路径。

合同已实现：

1. coordinator 的订阅按 owner scope、account generation、host ID、app ID 精确可见；立即回放、scope 变化
   清 null、监听器异常隔离、退订和 reset 都有合同。
2. 页面出现、账号切换、消失、cancel/stop 和 terminal cleanup 均与订阅/timer 对齐；只以 snapshot 的真实
   phase/error/degradation/firstFrame 驱动 overlay，首帧前不显示 connected，disconnected 有独立终态文案。
3. 真实 runtime port 缺失时继续 fail closed；重试只提示运行时未开放，不开启 transport、media、input、
   native、cloud 或后台工作。

定向测试与结果：新增 scoped snapshot delivery coordinator case；UI policy 增加 disconnected presentation
断言。文档聚合为 163 个 focused Moonlight tests / 21 describe，加 8 个 shared handoff cases，均已编译注册；
`ohosTest@OhosTestCompileArkTS` 仍因 `00306054` 未注册，未宣称 Hypium 执行。

全量门禁与结果：精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 `BUILD SUCCESSFUL`；
`git diff --check`、`node scripts/codex_state.mjs validate` 和静态隔离通过。signed HAP SHA-256：
`a89fc076f3edc9ca502d94fd53b0fdbb4b61c14c14bf242a250225f76917e077`。

真机/AGC/主机证据路径：最终 HAP 通过沙箱外 HDC 安装/启动于 PC `127.0.0.1:5555` 与手机
`127.0.0.1:5557`。本次只查看新截图：`/private/tmp/moonlight-s103-final-20260812-pc-root.jpeg`、
`...-pc-max.jpeg`、`...-pc-picker.jpeg`、`...-pc-picker-click.jpeg`、`...-phone-root.jpeg`、
`...-phone-picker.jpeg`。PC 侧栏与两端 picker 中 Moonlight 保持灰色官方可着色图标和“即将支持”；点击禁用项
无导航副作用，PC RDP 页面保持原样。上述只是模拟器 UI 证据，不是 Sunshine/ARM64/实体手柄能力证据。

许可证/SBOM/品牌证据：本 checkpoint 不修改品牌、vendor、SBOM、NOTICE、SPDX 或上游来源资产；沿用已审计
的官方 Moonlight Qt 几何可着色资源和系统 Symbol fallback。

当前 feature flags：`moonlightProtocolAvailable=false`；runtime、media、input、first-frame、streaming、
cloud 和 release truth 继续关闭；Moonlight 仍 local-only。

已知限制与 blocker：未有真实 Sunshine transport/media/首帧、OHAudio/Surface、HarmonyOS GameController
listener/typed NAPI、AppSpawn secure identity、on-device Hypium、长稳/功耗/网络/用户 ARM64 证据；云同步继续
parked，CloudStore 用户改动不在本任务。

上一阶段交接已由 S1-04 的 RustDesk 风格 session toolbar/control-center contract 完成；当前下一任务唯一入口为
S1-05A，继续复用现有 session/overlay/input policy，不新建第二 owner/queue。

回滚 commit/动作：回滚 `75d769c2` 即可撤销前一 checkpoint；S1-04 代码可按 `fae7c36dd`、`f7f39c0f`、
`665df714` 逐级回滚；不触碰 `CloudStore.ets` 用户改动。

### 15.16 S1-04 session toolbar/control-center 实际落地与验收交接单（2026-08-12）

阶段/任务 ID：S1-04 RustDesk-aligned session toolbar/control-center contract

基线 branch / HEAD / main：`codex/moonlight-complete-upgrade` / `665df714` / `main@aeb0cdac5`

本提交修改文件：

- `entry/src/main/ets/services/MoonlightUiPolicy.ets`
- `entry/src/main/ets/components/moonlight/MoonlightSessionToolbar.ets`
- `entry/src/main/ets/pages/MoonlightStreamPage.ets`
- `entry/src/test/MoonlightUiPolicy.test.ets`

其中 `fae7c36dd` 落地 responsive toolbar/control-center contract，`f7f39c0f` 补齐 edge-rail bounded
Scroll 与 non-xl explicit collapse，`665df714` 修复 Sheet/breakpoint 变化时的 timer reconciliation。

明确未修改的相邻系统：用户未提交的 `entry/src/main/ets/services/CloudStore.ets`、RDP/RustDesk/SSH/SFTP
业务页与共享协议业务、公共输入 owner、common-c/native/CMake/NAPI、GameController/OHAudio/Surface、
CloudSyncPolicy、现有云表注册和 product runtime caller。

合同已实现：

1. phone 与 pad edge rail 使用 360vp `maxHeight` 和 `Scroll`，避免短窗口裁切；desktop md/lg 采用 5/7
   项响应式布局，desktop xl 采用顶部工具条；颜色、浮层、危险动作和无障碍文本沿用 RustDesk/Theme 语法。
2. non-xl 布局显示明确的收起按钮；只有 xl 布局显示 pin 并使用 5 秒自动隐藏。`menuOpen` 与 breakpoint
   通过 `@Watch` 清理/重建 timer，timer callback 重新读取最新 layout/menuOpen/pin policy 后才折叠。
3. `MoonlightStreamPage` 传递 Sheet ownership，control center 按断点计算宽度、padding、section gap 和行高；
   diagnostics、controller、audio、PIP 和所有 runtime action 仍以真实 capability false fail closed。

定向测试与结果：新增 responsive layout/edge-rail boundary 与 Sheet-open、close、xl→lg auto-hide policy
cases；Moonlight documented focused aggregate 为 165 tests / 21 describe，加 8 个 shared handoff cases，
均 compile-registered。纯策略测试无法直接实例化 ArkUI timer，复核记录为一个不阻塞的 P3。

全量门禁与结果：精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 `BUILD SUCCESSFUL`；当前工作区
signed HAP SHA-256：`cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`。

真机/AGC/主机证据路径：最新 signed HAP 由沙箱外 HDC 安装/启动于 PC `127.0.0.1:5555` 与手机
`127.0.0.1:5557`。只查看本次 HAP 新抓取的证据：
`/private/tmp/moonlight-s104-final-cb1086-20260812-pc-root.jpeg`、
`...-pc-max2.jpeg`、`...-pc-picker2.jpeg`、`...-pc-picker-click.jpeg`、
`...-phone-root.jpeg`、`...-phone-picker2.jpeg`、`...-phone-picker-click.jpeg`。
PC 大屏有独立灰色 Moonlight 侧栏；PC/手机 picker 显示灰色图标与“即将支持”；两端点击禁用行后仍停留
在添加弹层；PC RDP 页面保持原样。所有图片均为本次最新 HAP 重新抓取并查看，不使用旧截图；这些只是模拟器
UI 证据，不是 Sunshine/ARM64/实体手柄能力证据。

许可证/SBOM/品牌证据：本 checkpoint 不修改品牌、vendor、SBOM、NOTICE、SPDX 或上游来源资产；沿用已审计
的官方 Moonlight Qt 几何可着色资源和系统 Symbol fallback。

当前 feature flags：`moonlightProtocolAvailable=false`；runtime、media、input、first-frame、streaming、
cloud 和 release truth 继续关闭；Moonlight 仍 local-only。

已知限制与 blocker：真实 Sunshine transport/media/首帧、OHAudio/Surface、HarmonyOS GameController
listener/typed NAPI、AppSpawn secure identity、on-device Hypium、长稳/功耗/网络/用户 ARM64 证据仍缺失；
云同步继续 parked，CloudStore 用户改动不属于本任务。

下一任务唯一入口条件：S1-05A 只接 HarmonyOS GameController listener 与窄 typed NAPI，复用 N3-08/N3-05/N3-01/
common-c 链，保持真实设备 capability false 直到 receipts 完整；不得创建公共 InputHandler 的第二 owner/queue，
不得把 ArkTS 变成控制器线协议编码器。

回滚 commit/动作：回滚 `665df714`、`f7f39c0f`、`fae7c36dd` 可逐级撤销 S1-04；不触碰 `CloudStore.ets` 用户改动。

### 15.17 当前收尾复核与 S1-05A 边界（2026-08-12）

本次收尾没有新增 Moonlight 运行时代码，原因是实体手柄的底层链路已经可以精确定位但尚未闭环：

- pinned common-c `src/Limelight.h` 已提供 `LiSendControllerArrivalEvent()` 与
  `LiSendMultiControllerEvent()`；`MoonlightControllerMapper` 已把 API 23 的按钮、轴、扳机、帽子轴
  投影为官方 full-state/arrival 语义，`MoonlightControllerAggregator` 已完成物理/虚拟源仲裁、neutral、
  disconnect、retired-lane 与 generation fence。
- 当前 `ProductDriverPort` 在 `MoonlightCommonCAdapter.cpp` 只装配视频、音频和连接回调，没有
  session-owned controller input port；工程也没有把 HarmonyOS GameControllerKit 的 device monitor/button/axis
  listener 接到 typed NAPI。因此当前不能声称实体手柄信号已经发送到 Sunshine。
- S1-05A 的正确实现顺序固定为：GameControllerKit listener（设备上下线、按钮、轴、生命周期）→ 单一
  session-owned typed input port → N3-08 aggregator → N3-05 mapper → N3-01 bridge → common-c arrival/state
  API。不得在 ArkTS 编码线协议，不得复用公共输入 owner 建第二队列，也不得在没有真实设备 receipt 时
  将 `api23InputAvailable` 或 `moonlightProtocolAvailable` 改为 true。
- listener 必须只向注入的 typed sink 投递 bounded full-state，必须处理全量 neutral/disconnect、回调注册
  失败回滚、设备 ID 稳定化、重复/迟到事件、前后台和 stop drain；GameControllerKit 返回的设备信息必须
  按 SDK destroy contract 释放，不能直接释放返回的字符串指针。产品 port 才能在 exact session owner、
  input/source/operation generation 都匹配时调用 common-c。

本次只用当前工作区 HAP 重新抓取并查看的证据，不用历史截图：

- `/private/tmp/moonlight-current-pc-20260812-01.png`、`moonlight-current-phone-20260812-01.png`：
  PC/手机添加主机协议选择器均显示灰色 Moonlight 与“即将支持”。
- `/private/tmp/moonlight-current-pc-20260812-02.png`、`moonlight-current-phone-20260812-02.png`：
  首页仍是主机管理唯一入口；PC 保留大屏主机列表，手机保留空状态和底部 FAB。
- `/private/tmp/moonlight-settings-phone-real-20260812-06.png`：
  Moonlight 设置展开后只有快速设置、画面、音频、控制与手柄、网络与安全、后台串流、诊断、云同步范围
  和 Trust 对应的协议设置内容，没有重复的“主机管理”项；公共“主页与主机列表”仍由应用公共设置拥有。

### 15.18 U1-13 本地主机保存实际落地与最终 UI/隔离验收（2026-08-12）

阶段/任务 ID：U1-13 local-only Moonlight host-add persistence and closeout

代码 checkpoint：`db750cdb`，基线为 `codex/moonlight-complete-upgrade` / `main@aeb0cdac5`。

本 checkpoint 修改范围严格限定为：

- `entry/src/main/ets/components/hostadd/MoonlightHostAddFlow.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/services/HostAddConnectionHandoffPolicy.ets`
- `entry/src/main/ets/services/MoonlightHostAddFlowPolicy.ets`
- `entry/src/main/ets/services/MoonlightLocalHostService.ets`
- 对应的 `MoonlightLocalHostService`、`MoonlightHostAddFlowPolicy`、`HostAddConnectionHandoffPolicy` 定向测试及 `List.test.ets` 注册

用户的 `entry/src/main/ets/services/CloudStore.ets` 明确未修改、未暂存、未提交。

实现合同：

1. `MoonlightLocalHostService` 只接入现有 `MoonlightRepositoryPort`，不接 CloudStore 的云同步方法、不新增表、
   不写 `moonlightrecordv1`。它在保存前检查 step 4、paired、trusted、证书 SHA-256、owner token、account lease、
   state generation 和 save operation；同一账户下按 `ownerScopeId + serverUuid` 生成稳定 host ID，trust ID 由 host ID
   派生，重复 UUID 只返回已有 host，不创建第二条。
2. host/trust 的 business record 在第一条本地写入前全部构造完成。每条写入都由现有 repository readback 确认；
   第二条失败、readback 失败或异常时，使用更高 `syncVersion` 的前向 tombstone/restore candidate 补偿。新主机失败
   可在后续有效保存中以 `resetEpoch + 1` 显式复活，已有主机失败恢复旧业务 payload；结果分为 `not_committed`、`partial`、
   `uncertain`，后两者设置 recovery lock，保存按钮和普通目录 handoff 均停止，避免重复写入/错误导航。
3. `HostListPage` 只负责 thin adapter 与生命周期交接：普通保存写入本地 host/trust；“保存并打开目录”和重复主机“查看已有主机”
   只携带稳定 host ID、owner token、generation，并在共享 add Sheet 原生 `onDisappear` 后导航到现有目录/详情 shell。没有
   fixed delay、第二 Sheet、snapshot callback、网络、native、media、audio、input、cache 或后台调用。
4. `localOnly=1` 是本 checkpoint 的唯一持久化模式；新 Moonlight 数据不进入云选择、云传输、secret recovery、备份 promotion 或
   其它协议数据路径。首页继续是主机管理唯一入口，设置页不再增加“主机管理”，公共 display/PIP 仍由公共设置拥有。

定向验证：新增 8 个 local persistence cases（成功写入、trust 失败补偿、untrusted/stale lease、replayed generation、tombstone revival、
existing-host restore、host readback rollback、partial compensation），新增 1 个 recovery policy case 和 1 个 existing-host detail handoff case。
全部 compile-registered；`ohosTest@OhosTestCompileArkTS` 仍因 `00306054` 未注册，未宣称设备 Hypium PASS。

强制门禁与部署：精确 `default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon` 和
`assembleHap --analyze=normal --parallel --incremental --no-daemon` 均 `BUILD SUCCESSFUL`。最终 HAP 为
`entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 为
`8b54784ac3112b30a5630ef074d35150fd7271099920e54ab97809ef1546263e`；已通过沙箱外 HDC 安装/启动于 PC `127.0.0.1:5555` 和手机
`127.0.0.1:5557`。

最终 UI 验收只使用并查看本次最新 HAP 安装后新生成的 `/private/tmp/moonlight-final-gate.bIGtZD/`：

- `pc-root.png`、`phone-root.png`：PC/手机首页主机管理保持原状，主机管理仍归首页；
- `pc-picker-open.png`、`phone-picker-open.png`：RustDesk 风格 FAB 协议选择器中 Moonlight 使用灰色可着色图标并显示“即将支持”；
- `pc-max.png`：PC 大屏侧栏拥有独立的灰色 Moonlight 栏位，显示“即将支持”；
- `phone-settings-open.png`：公共“主页与主机列表”仍是主机管理入口，Moonlight 作为独立协议设置分组；
- `phone-moon-expanded.png`：Moonlight 展开为快速设置、画面、音频、控制与手柄、网络与安全、后台串流、诊断等专属子项；
- `phone-quick.png`：实际打开 Moonlight“快速设置”bindSheet，含低延迟/均衡/画质优先、接收音频、自动重连和保存入口；
  所有截图均来自当前 HAP，不使用旧截图。

复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成 `665df714..db750cdb` 增量复核，结果 PASS，
P0/P1/P2=0；唯一 P3 是测试端口尚未直接抛异常导致的外层 catch/补偿异常分支覆盖限制，不阻塞当前本地数据收口。
审查确认本 checkpoint 没有改变 RDP、RustDesk、SSH/SFTP、VNC、公共输入、native/CMake/NAPI、CloudSyncPolicy、既有云表、
video first-frame、streaming、FAB availability 或 release truth。

当前可交付范围：RustDesk 统一视觉的首页主机管理、本地主机详情/目录 shell、九段设置 bindSheet、连接/串流 UI 壳、灰色 FAB/PC
栏位、dormant native/session contracts，以及已接入现有本地仓储的安全 host/trust 保存。当前不可交付范围仍是：真实配对、在线目录刷新、
launch、视频首帧、OHAudio、实体手柄、Sunshine 串流和 release truth。下一任务唯一入口为 S1-05A；其完成后还必须通过真实设备手柄 receipt，
再由 N2-09/S1-08 继续媒体和生命周期运行时验收。

回滚 commit/动作：回滚 `db750cdb` 可撤销 U1-13 本地主机保存适配；不触碰用户 `CloudStore.ets` 改动。

### 15.19 设置/FAB/本地数据最终收口复核（2026-08-12）

本轮只做当前 HAP 的 UI 和数据边界复核，没有新增代码，也没有触碰用户的 `CloudStore.ets`。最新沙箱外 HDC 证据保存在
`/private/tmp/moonlight-ui-closeout2.PFyRlJ/`，并已实际查看截图与对应 UI tree：

- `root-5557.jpeg`：手机首页仍是主机管理唯一入口，空状态与底部 FAB 正常；此前同一当前 HAP 的 `root-5555.jpeg` 证明 PC 大屏首页连续性。
- `settings-toggle-check.jpeg`：Moonlight 行真实展开，图标、标题、副标题、旋转箭头和 RustDesk/Theme 卡片排版一致；展开内容进入同一设置容器，不产生第二页面或重复主机管理。
- `settings-lower-closeout.jpeg` 与其 UI tree：九个 Moonlight leaf 全部可见且顺序固定为快速设置、画面、音频、控制与手柄、网络与安全、后台串流、诊断、云同步范围、配对与信任。
- `moonlight-quick-sheet-closeout.jpeg`：快速设置从唯一 `bindSheet` 真实打开，三档体验预设、接收音频、自动重连和保存状态可见；副标题明确当前账号为本地范围。

收口判定：设置入口已经完成“应用公共设置 → Moonlight 协议分组 → leaf → 单 bindSheet”链路；FAB/PC 栏位继续由
`moonlightProtocolAvailable=false` fail-closed，灰色可着色官方图标与“即将支持”是当前正确产品状态；本地主机保存继续只写已有本地
`MoonlightRepositoryPort` 的 host/trust 记录，`localOnly=1`，不注册或上传 `moonlightrecordv1`。本轮未改 RDP、RustDesk、SSH/SFTP、VNC、
公共输入、native/CMake/NAPI、CloudSyncPolicy 或既有云表。

本轮不会把 UI/HAP 验收扩大为真实 Moonlight 发布能力：真实 Sunshine 配对、Host Control、视频首帧、OHAudio/Surface、实体手柄
GameControllerKit→typed NAPI→common-c、网络/温控/长稳和 device Hypium 仍分别由 S1-05A、S1-08、N2-09 与设备门禁负责。

### 15.20 当前签名 HAP 最终验收（2026-08-12）

为避免把历史包误当作当前包，本次最终验收只认最新签名 HAP：
`entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 为
`8a5209d438b253ccb78df6e29734bb1afdde2eb3da281aea8e3ed30c04862419`。该包已通过沙箱外 HDC 安装/启动于 PC
`127.0.0.1:5555` 和手机 `127.0.0.1:5557`。

当前包截图和 UI tree 全部落在 `/private/tmp/moonlight-current-hap-20260812/`：PC/手机首页、PC/手机 FAB 协议选择器、
手机 Moonlight 展开、设置下半段和快速设置 bindSheet 均已重新抓取并实际查看。它们确认 Moonlight 官方可着色图标、灰态“即将支持”、
首页主机管理归属、PC 大屏连续性、九个协议 leaf、单一 bindSheet 以及本地-only 设置文案；本条记录替代此前包的 UI 证据，不能用旧截图
替代当前验收。

本次仍为文档/验收收口，没有新增代码；`CloudStore.ets` 仍是用户-owned 未暂存修改。构建、HDC 安装启动和 UI 检查不改变
`moonlightProtocolAvailable=false`、本地主机 `host/trust` 仓储边界或实体手柄 S1-05A 的未开放状态。

### 15.21 U1-14 adaptive FAB/add-shell and S1-05A isolation closeout（2026-08-12）

本节覆盖此前 U1-14 工作树增量，并以本节取代旧的“FAB 仍为 `即将支持`/不可进入”描述。

#### 产品/UI 合同

- Moonlight FAB 入口沿用 RustDesk 的“FAB → 单协议选择 Sheet → 单添加 Sheet”路由，首页仍是主机管理唯一入口；不新增设置页主机管理、不新增第二个主机列表。
- `moonlightFabEntryAvailable` 只代表可审查的四步本地添加壳入口；`moonlightProtocolAvailable` 仍为 `false`，不能由入口可达性推导 pairing、Host Control、目录、串流、保存或 release truth 已开放。
- 为避免“可点击即代表可串流”的误导，协议选择卡在 shell-only 状态显示官方可着色 Moonlight 图标与 `仅添加`，不显示运行能力 chevron；点击仍只进入添加壳，壳内运行时步骤继续 fail closed。
- `MoonlightHostAddFlow` 按 RustDesk 的自适应结构使用 `currentBreakpoint`、intrinsic `FIT_CONTENT` 高度和统一 Theme token；动态发现候选单独放入手机 260vp/大屏 320vp 有界 `Scroll`，发现/完成操作组在 Scroll 外以至少 12vp（大屏 10vp）间距排列，底部按钮不再粘连且始终可见。

#### 原生边界与实体手柄合同

- GameControllerKit listener 仅保留为 test-only/future-session native foundation，不进入产品 `MOONLIGHT_SOURCES`、`rdpnapi`、共享 NAPI、ArkTS 类型声明或 common-c product input port；不注册进其他协议进程路径，不引入公共输入 owner、第二队列或新的线程。
- listener 的注册失败路径会关闭 admission、等待已获得 callback lease 的回调排空后再返回；`start/stop` 继续由 lifecycle mutex 串行化；所有 GameControllerKit callback 通过单一 dispatch mutex 完成有序 sink transaction，防止断开/重连时 generation/sequence 乱序。
- S1-05A 仍是唯一的后续实体手柄落地点：listener → 单一 session-owned typed sink → N3-08 aggregator → N3-05 mapper → N3-01/common-c；在真实 session port 和实体设备 receipt 之前保持 controller/runtime capability false。

#### 当前验证与隔离事实

- 精确 `default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon` 与 `assembleHap --analyze=normal --parallel --incremental --no-daemon` 均 `BUILD SUCCESSFUL`；当前签名 HAP SHA-256 为 `dfb5ec2c4dd9e67630c805fcce34b6d3eb9871765fccc910a77d86d6cbb1f16d`。
- 当前 HAP 已通过沙箱外 HDC 安装/启动于 PC `127.0.0.1:5555` 与手机 `127.0.0.1:5557`；只使用新抓取并实际查看的 `/private/tmp/moonlight-fab-final2-20260812/` 证据。PC/手机 picker UI tree 均记录 Moonlight、官方图标和 `仅添加`；首页未受影响。
- native focused target 编译成功；全量结果为 `701 passed, 16 failed, 717 total`，16 个失败均为既有本地 TLS fixture 启动失败，Moonlight listener/controller 合同测试通过。
- 本 checkpoint 未改用户 `CloudStore.ets` 的业务内容，不接入云同步；未改 RDP、RustDesk、SSH/SFTP 的业务实现、公共输入路径或其性能/功能开关。`git diff --check` 通过。

#### 收口边界

本节完成的是自适应 UI/本地添加壳和原生隔离安全收口，不是 Moonlight 串流发布。真实 Sunshine 配对、Host Control、视频/Opus 首帧、OHAudio/Surface、session-owned 手柄发送、网络/温控/长稳及设备 Hypium 仍由 S1-05A、S1-08、N2-09 和设备门禁负责；下一实现任务唯一为 S1-05A。

### 15.22 最终提交前验证收口（2026-08-12）

- listener 的 callback registry 现在以 `shared_ptr<Impl>` 保持已进入 SDK callback 的对象存活；注册失败会排空 admitted callback lease，注销会释放 registry owner；sink 内同步 `stop()` 只标记 deferred stop，实际注销由 callback lease 在最外层 callback 返回后执行，避免自等待和悬空对象。
- 当前产品精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 `BUILD SUCCESSFUL`。最新签名 HAP 为
  `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 为
  `dfa10941f60946e30a7f288688da655c53c5f50b98a13bdcbc563b555267377d`；最终包已重新安装/启动于 PC `5555` 与手机 `5557`，新首页证据为
  `/private/tmp/moonlight-final-committed-ui.JX0JXs/`；详细 FAB/add-sheet 证据仍只认
  `/private/tmp/moonlight-fab-final2-20260812/`。
- host `rdp_native_tests` 从当前工作树重新配置/编译/运行，结果 `701 passed, 16 failed, 717 total`；失败仍为既有本地 TLS fixture 启动失败，Moonlight listener/controller 用例通过；API 23 arm64 listener syntax check 通过。
- 本次提交继续只收口 Moonlight UI/隔离 foundation；`CloudStore.ets` 不暂存、不修改、不接入 Moonlight 云同步。产品不含 listener、GameControllerKit link、公共 controller NAPI 或 common-c controller port，因此不改变其他协议的性能/功能路径。真实 session-owned 手柄传输仍属于后续 S1-05A。

### 15.23 S1-05A 与 N2-09 产品可行性接线交接单（2026-08-13）

本节是当前实施事实的最高优先级补丁，并取代此前“FAB 仅添加/即将支持、产品无 Host Control/media/input
caller、GameController listener 仅测试”的旧当前态描述。历史 checkpoint 不删除，但后续模型必须从本节继续。

#### A. 当前完成范围

- UI/用户流：RustDesk 风格 FAB→添加 Sheet、本地主机目录/详情/重命名/删除、按主机应用目录、launch Sheet、
  connection/stream page、toolbar/control center、虚拟手柄、手机与 PC 独立 Moonlight tab 均已产品接线。首页
  仍是唯一主机管理入口；Moonlight 设置不重复公共 display/PIP/主机管理。
- 数据：只使用 owner-scoped local repository、host/trust/profile/settings 和 local app cache；Moonlight 云表、
  CloudSync 注册/selection/transfer/secret recovery 继续 PARKED。用户-owned `CloudStore.ets` 增量不属于本任务。
- Host Control：LAN discovery/verify、pair、catalog、launch 使用现有 `MoonlightHostService` typed NAPI；所有请求
  绑定 owner token、operation generation、current account lease、installation ID、store identity/instance，离页、
  换账号、导航或 reservation 失败会取消 owner，迟到 completion 不得改 UI/缓存/路由。
- Media：官方 common-c transport→HarmonyOS Surface H.264 decoder、Opus→OHAudio 已进入产品。当前唯一可声明
  offer 是 H.264/8-bit/YUV420/stereo/low-latency；bitrate live。video/audio readiness 读取真实 sink live receipt；
  streaming truth 仍要求 first frame；stop 使用 worker terminal teardown 和可轮询 terminal receipt。
- Input：keyboard/pointer/touch/virtual/physical controller 共用一个 native session owner 和 common-c ingress；
  ArkTS 只发送语义事件。backpressure 只保留一个 exact pending；source handoff remove-first；终态 neutral/release
  不在 UI 线程执行。实体 GameControllerKit 只在 Moonlight 会话激活时动态解析，失败只降级实体手柄。
- Isolation：主页渲染保持 capability=false 且不查询 Moonlight runtime；只在用户明确点击 FAB 后执行真实 capability
  探测，因此普通首页/其他协议不初始化 Moonlight identity/Asset。双 ABI `librdpnapi.so` 无 GameControllerKit `DT_NEEDED` 和 unresolved GameController symbol；
  相邻协议业务文件、公共 input owner、云注册和 feature flags 未被复用为 Moonlight 实现。

#### B. 当前门禁事实

| 门禁 | 2026-08-13 结果 |
|---|---|
| exact ArkTS test compile | PASS |
| exact signed assembleHap | PASS，SHA-256 `3ec6e5abb4c685d83097ce49793c408301679d8aed19f8376f611456b8a26d85` |
| arm64-v8a / x86_64 native product | PASS / PASS |
| 双 ABI GameController ELF 隔离 | PASS，无 mandatory dependency / unresolved symbol |
| host native | 711/727 PASS；Moonlight 全 PASS，16 个无关的既有 local TLS fixture start failure |
| diff/isolation | PASS；CloudStore 用户 diff 排除 |
| 双 reviewer | PASS，ArkTS/UI 与 native/media 均 P0/P1/P2=0；最终 checkpoint `bc630af34` |
| 当前包设备部署/UI | PASS：精确 HAP 已安装/启动于手机 5555 与 PC 5557；当前包新截图通过 FAB、添加/发现页、PC 分类和六个可见设置 Sheet 验收 |

#### C. 后续模型一步一验收执行顺序

1. **N2-09A 安全身份门禁**：当前包已完成 PC/手机部署与基础 UI 验收；下一步在目标设备证明或修复 Asset Store
   安全身份。FAB 只以 `bridgeCompiled && transportReady` 开放 LAN discovery/HTTP verify；PIN pairing 必须重新检查
   `hostControlReady`，不可用时在 PIN 和任何 trust/save mutation 前 fail closed。
2. **N2-09B Sunshine 最小闭环**：同一 LAN 搜索 Sunshine；verify UUID/证书；PIN pair；保存 local host/trust；
   online catalog；launch 一个已知应用；要求 common-c transport ready、真实 videoReady/audioReady/inputReady、
   firstFrame；发送键鼠、触摸、虚拟控制器；stop 必须在 5 秒内收到 native terminal receipt且 registry 清空。
3. **N2-09C 实体手柄**：连接一个物理手柄，证明 dynamic library 在 Moonlight 激活前不加载；激活后记录 arrival、
   full-state、neutral/remove；virtual↔physical 两向 handoff 均 remove-first；拔出/后台/stop 无卡键。再在缺库或
   listener start failure 注入下证明视频、音频、键鼠、触摸和虚拟手柄继续可用。
4. **S1-06 settings closeout — 已完成 `1af10374`**：六个 Moonlight 专属 bindSheet 已接本地设置；隐藏旧路由与 builder
   已删除，后台音频、无 Surface 画面策略、重连和诊断已归位；公共 display/PIP/系统音量/主机管理保持去重。
5. **S1-07 lifecycle**：逐项验证 rotation/surface recreate、foreground/background、network loss/recovery、owner/account
   switch、host app exit、stop during startup、late callback、PIP 公共路由；每项必须证明 neutral、media release、owner
   cleanup、无旧 generation 写回。
6. **S1-08 / R1 acceptance**：720p/1080p、30/60fps，弱网/切网、热状态、内存、两小时长稳、ARM64 真机、PC/phone
   UI fresh screenshots、许可证/SBOM 和回滚。只有全部 PASS 后才能把“产品可行性框架”升级为“发布可用”。
7. **Cloud remains parked**：上述任何步骤不得新增 `moonlightrecordv1`、云表注册、云同步 selection/transfer 或 secret
   recovery；云恢复必须由用户另行显式解除。

#### D. 当前不可宣称

在真实 Sunshine、安全身份、首帧/音频/输入/实体手柄和长稳回执完成前，不得宣称完整 Moonlight 模组、
发布级串流、全设置 live、物理手柄实机支持或 PC/手机 UI 最终验收。当前准确说法是：本地-only discovery、Host
Control、catalog/launch、保守 H.264/Opus stream 和统一 input/controller 的可测试产品框架已完成编译与隔离门禁。

### 15.24 N2-09A 安全身份与 Host Control 运行时关闭（2026-08-13）

本节取代 15.23 中“N2-09A 待证明或修复安全身份”的当前态；历史描述保留作 checkpoint 证据。

1. API-23 Asset Store identity/probe 的 add、exact query、remove、inventory 统一选择 credential-encrypted 数据库。
   无 alias 的批量操作只返回 attributes；manifest 明文仅通过精确 alias/identity/kind/owner 查询。
2. runtime probe 使用时间戳+随机 owner。live probe 不互删；崩溃孤儿在五分钟后以持续取得进展的批次回收；
   identity list 对跨进程 erase 使用两次有界快照尝试，无法稳定时返回 Busy 而不是 Corrupt。
3. capability probe 仍只由显式 FAB 动作触发，不进入首页 render/startup。手机与 PC 模拟器均实测
   `bridge=identity=transport=pairing=hostControl=1 blocker=none`；这只关闭 Host Control 本机运行时门禁，不等于
   已有真实 Sunshine pairing/stream receipt。
4. 最终 checkpoint `ef13ca19`；签名 HAP SHA-256
   `7e84303d06b33926fa702a2384584010612a2517b88aa38aad8d7e4c23096318`。双 Hvigor、双 ABI probe、vendor
   117 files、Light、GameControllerKit ELF 隔离和 diff 均 PASS；复用 Luna Max reviewer 后 P0/P1/P2/P3=0。
5. 本步只修改 Moonlight secure identity、Moonlight capability truth 和显式 FAB 诊断；用户 `CloudStore.ets`、
   云注册、相邻协议业务实现、公共输入 owner 和首页性能路径均未改变。

### 15.25 S1-06 六路设置与本地保存关闭（2026-08-13）

1. `1af10374` 将 Moonlight 设置收敛为画面、音频、控制与手柄、网络与安全、诊断、配对与信任六路；删除隐藏
   quick/background/cloud route 与 builder。预设和无 Surface 策略归画面，后台音频归音频，重连归网络与安全。
2. Moonlight 设置继续按当前账号本地保存。空 public ciphertext 校验不再经过设备空 TextEncoder；本地 record 与
   mutation journal 原子提交后做 owner-scoped durable readback。手机实测保存、重启回读与恢复默认通过。
3. 公共显示、PIP、系统音量和首页主机管理不复制；Moonlight 未加入云表注册、云选择、传输或恢复。
4. 手机和 PC 六页 bindSheet、PC 独立栏位、手机 FAB picker、自动发现、手动地址和自定义端口均使用最终包最新截图
   验收。双 Hvigor PASS；签名 HAP SHA-256 `83815f082b62dbe1f773a64ffcb224facd9b30cf8253298f36530e3a1cd4e027`，
   已安装并启动于两个模拟器。
5. 本增量不修改 native/session 热路径或相邻协议业务文件。后续唯一顺序为 N2-09B 真实 Sunshine 最小闭环，随后
   N2-09C 实体手柄与 S1-07/S1-08/R1 生命周期、ARM64 和长稳验收；云同步继续 PARKED。



### 15.26 设置诚实状态与计费网络启动闸门（2026-08-18）

1. 未接线选项改为诚实状态行，不再保存假可用开关：HDR/YUV444、后台音频、HUD/日志、震动、
   系统快捷键转发、重连预算、Surface 销毁策略。
2. 计费网络成为真实启动闸门。未知网络按计费处理；`ask` 需要启动页一次性批准；`startSelected()`
   启动前再次检查。
3. `CloudStore.commitMoonlightLocalRecord()` 只报告事务提交真值；readback/lease 校验回到
   `MoonlightRepository`，避免 durable write 后被误报成未提交。
4. 本增量仍为本地-only，不接入云同步。精确 compile/assemble 已通过；当前签名 HAP SHA-256
   `93a666c1e35ba539132231758816baf0312b4abff6e6f542a0bfcb24f765e662`。启动确认 Sheet 的动作区已改为
   纵向自适应栈，不再让计费网络的四个动作横向粘连；不可用设置状态统一弱化为灰色。`hdc list targets`
   已恢复，但 `hdc install -r` 仍被外部审批服务拒绝，设备安装与 PC 六页新截图尚未完成，不得用旧截图代替。

### 15.27 非云产品实现关闭与统一验收边界（2026-08-19）

本节取代 15.26 中“重连、后台音频、HUD 等仍未接线”的旧当前态；旧节仅保留历史增量证据。

1. FAB/主机面：Moonlight 入口按用户显式打开 FAB 后的真实 transport capability 决定可达性；可达时进入与
   RustDesk 同构的自适应添加流程，不再固定显示“即将支持”。发现、手动地址、验证、PIN、证书信任、本地
   host/trust 原子保存、详情、重命名、忘记、远端 unpair、按主机应用目录和 launch 均使用同一 owner/account/
   generation/store fence。
2. 串流面：官方 pinned common-c、H.264 Surface 解码、Opus/OHAudio、首帧、音视频 readiness、计费网络一次
   放行、显式只断开/退出主机应用、终态回执均进入产品调用链。自动重连使用有限预算和新 session generation；
   页面/Surface/PIP/后台/网络变化先冻结并释放输入，再执行媒体生命周期变化。
3. 输入面：键盘、文本、鼠标、触摸、触控板、虚拟手柄和 GameControllerKit 实体手柄统一进入 native
   `MoonlightProductInputRuntime`。终态只在远端 neutral、boundary 与 teardown 三项均有正向证据时才报告安全；
   permanent backpressure、port failure、owner loss/local-only 与重复 terminal receipt 均保持保守失败。
4. 生命周期面：有限自动重连、崩溃恢复的 Resume/结束主机应用/清除标记、Surface 重建、PIP、后台音频、
   host rename/forget/unpair、local records/cache/recovery/secure identity 删除均已接入生产 service；账号切换通过
   `MoonlightDataLifecycleRuntime` 排空运行态，旧 lease/callback 不能写入新 owner。
5. 设置/UI 面：六个协议设置 leaf（画面、音频、控制与手柄、网络与安全、诊断、配对与信任）和一个数据管理
   leaf 继续使用统一 bindSheet；公共显示/PIP/系统音量/首页主机管理不重复。HDR、YUV444、系统保留快捷键转发
   与手柄反馈属于首版明确关闭的能力，不以假开关宣称支持；普通键鼠/触控/控制器输入不受影响。
6. 隔离与验证：精确 `default@OhosTestCompileArkTS`、`assembleHap`、`git diff --check`、117-file vendor gate
   全部 PASS；signed HAP SHA-256 为
   `fe3ecf3b7c2b70f23d1e658fc6d5836710dff7f0e8f84700712b92293661ad9e`。沙箱外 host native 为
   `773 passed, 0 failed`；双 ABI 均无 GameControllerKit `DT_NEEDED` 或未解析 `OH_Game*` 符号。最终 product-input/
   runtime 复审 P0/P1/P2/P3 全 0。
7. 云与验收边界：`MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION` 继续为 0；用户明确确认目标 AGC 中 19 列
   `moonlightrecordv1` 建表前不得启用。非云代码已经关闭，但按用户要求不在此时安装 HAP、截图或做阶段性
   UI 验收；云接入完成后，统一执行 PC/手机、真实 Sunshine、实体手柄、ARM64、切网/生命周期和长稳验收。

<!-- PLAN_BODY_END -->
