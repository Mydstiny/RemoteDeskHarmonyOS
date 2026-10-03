# RDP/RustDesk 可观测性、EasyTier 直连与画质生效合并计划

- 日期：2026-10-03（Asia/Shanghai）
- 计划状态：IMPLEMENTING（2026-10-04 用户授权完整落地）；仍不授权发布、打开 H.264 默认路径或开启 RustDesk AUTO。实施记录见第 13 节
- 合并来源：
  - [RDP 可观测性、AI 取证与 GFX/H.264 升级](2026-10-03-rdp-observability-ai-gfx-upgrade.md)
  - [RustDesk EasyTier 直连修复](2026-10-03-rustdesk-easytier-direct-connection-repair.md)
  - 2026-10-03 新增用户反馈：RustDesk “画质优先”在连接中侧栏选择后无明显效果（本文首次纳入）
- 当前基线：`codex/pro-purchase-foundation`（HEAD `0ea628e18`，22 处未提交 Pro/AI 修改，`review=REVIEW_REQUIRED`）；本计划不包含这些修改
- 开发基准：HarmonyOS API 26；保留 API 23 兼容核对

## 1. 要解决的三个问题

| 编号 | 用户可见问题 | 当前能否定位 | 本计划处理方式 |
|---|---|---|---|
| R | RDP 线上实际走 GDI、GFX/RFX 还是 H.264 无法判断；服务端开 H.264 组策略无效 | 否：诊断标签混淆本地呈现与线协议 | 先补证据，再稳定 GFX/RFX，最后单独实验 AVC420 |
| E | 官方 RustDesk 能通过 EasyTier 连接，RemoteDesktop 直连失败 | 否：用户 capture 中 `connection.rustdesk` 为 0 条 | 先修入口语义和早期失败取证，再按失败阶段修 native/网络 |
| Q | RustDesk “画质优先”选择后看不出变化 | 部分：客户端链路已确认，远端是否生效无证据 | 先补生效证据，再做低成本可见性修复，4:4:4 单独评估 |

三者共享同一原则：**先让结构化诊断能回答“实际发生了什么”，再修改行为**。

## 2. 共同原则与边界

1. 配置值、请求值、实际观测值、远端确认值分开记录，不用一个字段代替另一个。
2. 证据等级统一为：`observed_native`、`observed_arkts`、`derived`、`configured`、`inferred`、`missing`。只有前三类可作为确认事实。
3. 诊断不得包含密码、用户名、服务器 Key、token、证书 PEM、完整 IP、RustDesk ID、RDP/RustDesk payload、屏幕像素、音频、剪贴板或终端正文。
4. 不通过删除门禁伪造能力：不删除 `rdpGfxH264PathSafe()` 门禁、不删除 RustDesk `auto_unavailable`、不把 `graphicsMode=gfx` 称为 H.264、不把本地 BGRA 拷贝字节称为线上字节。
5. 一次失败的回退只作用于当前 session 或明确作用域，不污染其他主机或后续无关 session。
6. 编译/HAP 证据不能替代网络、服务端和真机证据；旧日志不能替代新 schema 和新 buildId 的证据。

## 3. 已核实的当前代码事实

### 3.1 诊断层（R/E/Q 共用）

- capture schema v8、event catalog v1、redaction policy v3；runtime 默认 5 秒采样，full capture 1 秒。
- RDP runtime facts 通过 [ExtensionLoader.ets:387](../../../entry/src/main/ets/services/ExtensionLoader.ets:387) `mergeRdpRenderDiagnostics()` 合并 render stats，但：
  - `receivedBytes = max(receivedBytes, copiedBytes)`（[ExtensionLoader.ets:394](../../../entry/src/main/ets/services/ExtensionLoader.ets:394)），本地 BGRA 拷贝字节混入“接收字节”；
  - 未合并 `graphicsMode`、`gfxChannelConnected`、FreeRDP 能力协商、wire codec。
- RDP HUD 在 GFX 通道未连接时直接显示 `gdi`（[RdpDiagnosticsHud.ets:231](../../../entry/src/main/ets/components/RdpDiagnosticsHud.ets:231)）。
- native hilog 与 capture 的 session/generation/elapsed timeline 不关联；capture 丢弃、采样跳过、native source 不可用没有覆盖率结论。
- AI bundle 约 1 MiB，仅为事件安全映射后的 JSON，没有证据覆盖率、缺失项、来源可信度和 evidenceRef。

### 3.2 RDP（R）

- [freerdp_adapter.cpp:3375](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp:3375) `rdpGfxH264PathSafe()` 固定返回 false，`FreeRDP_GfxH264` 因此不通告；服务端组策略无法覆盖客户端门禁。
- FreeRDP 构建包含 RDPGFX/H.264 编译能力；RDPGFX channel callback、GDI graphics pipeline、graphics lifecycle、GDI frame pump 已存在。
- **合并评审新增**：[freerdp_adapter.cpp:3312](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp:3312) `g_nextConnectionGfxFallback` 是进程全局的一次性回退标志（`mark()` 位于 4751/5898/5955，`consume()` 位于 3383）。主机 A 的 GFX 失败会让下一次连接——即使是主机 B——降级为 GDI，且不进入任何诊断事件。这与“回退不污染下一 session”的目标冲突。

### 3.3 RustDesk 直连（E）

- 添加流程一级入口为“中继连接 / 局域网直连”（[RustDeskAddFlow.ets:263](../../../entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets:263)），直连内再分“手动配置 / 局域网搜索”（294/299）。EasyTier 应走手动配置，但“局域网直连”命名易误导用户进入 UDP 21119 局域网搜索或填写 RustDesk ID。
- `directEnabled=true → direct_ip`，否则 `force_relay`；`auto` 明确返回 `auto_unavailable`（[RustDeskConnectionStrategyPolicy.ets:28](../../../entry/src/main/ets/services/RustDeskConnectionStrategyPolicy.ets:28)）。
- 直连 endpoint 来自 `rustdeskDirectHost/Port`，默认 21118；直连只接受设备密码，跳过 rendezvous 后执行 TCP + Hash/Login（[connector.rs:1231](../../../rustdesk_ffi/src/connector.rs:1231)）；native 使用规范化直连地址作为 login identity（[lib.rs:2064](../../../rustdesk_ffi/src/lib.rs:2064)）。
- 链路本地 IPv6 当前明确拒绝；动态 IP 策略绑定 RustDesk ID/LAN 语义，不能作为 EasyTier 地址更新机制。
- 用户 capture 约 2.9 秒，只有 `core.app` 开始/停止，`connection.rustdesk` 为 0 条。**合并评审新增**：这本身是待验证缺陷——ArkTS 预检或输入校验阶段被拒的连接可能完全不写 `connection.rustdesk` 事件。

### 3.4 RustDesk 画质（Q，新增）

客户端链路完整：

```text
侧栏 imageQualitySubMenuContent()          RemoteSessionTopBar.ets:1016
→ setRustDeskImageQualityPref()             RemoteDesktop.ets:7916（持久化 + toast）
→ ExtensionLoader.setRustDeskImageQuality() ExtensionLoader.ets:2266
→ NapiSetRustDeskImageQuality()             extension_loader_napi.cpp:7722（失败时 hilog 记录 reason）
→ RustDeskBridge::setImageQuality()         rustdesk_bridge.cpp:2841（Control lane）
→ rustdesk_set_image_quality()              lib.rs:3026（generation + ControlMsg 入队）
→ pump_control_messages()                   connector.rs:2629
→ Session::send_image_quality()             session.rs:501（Misc.option 仅含 ImageQuality::Best）
```

“看不出变化”的已确认/待验证原因：

| # | 原因 | 依据 | 性质 |
|---|---|---|---|
| Q-a | 该选项在远端只改变编码码率倍率，且受远端 ABR/网络延迟约束；静态桌面和文字在两档码率下都会收敛到接近的清晰度 | 上游 RustDesk video QoS 行为（具体倍率需按目标 peer 版本核对） | 协议语义 |
| Q-b | 实时切换后不发送 `refresh_video`，新码率只体现在后续增量帧，没有立即可见的刷新 | session.rs:501 之后无刷新 | 已确认 |
| Q-c | 连接时“平衡”与“画质优先”档位差异极小：均为 60fps，codec H264 vs Auto（也优先 H264）；`max_edge_px` 1600/1920 只在计算参数和打日志时出现，没有实际用到；实时切换不改变 profile | lib.rs:510-550、lib.rs:741、lib.rs:2132 | 已确认 |
| Q-d | 文字发糊的主要来源不受该选项控制：不支持 4:4:4 真彩（`supported_decoding` 从未设置 `i444`，全仓库无引用），本地“适应窗口”缩放、远端分辨率 | session.rs:340 | 已确认 |
| Q-e | UI 无“远端已生效”反馈：toast 只说“已发送，等待远端生效”，勾选只反映本地偏好；远端 TestDelay 中的 `target_bitrate_kbps` 已进入 diagnostics snapshot 与 capture 的 `protocol.targetBitrateKbps`（实施时核对更正），但 HUD 不显示，也没有据此判断是否生效 | connector.rs:3197、DiagnosticRuntimeSnapshotPolicy.ets:161 | 已确认 |
| Q-f | 实时调用可能被拒（`session-not-found`、`session-owner-inactive`、`bridge-unavailable`、`ffi-control-rejected`），此时 toast 为“画质偏好已保存，下次连接生效” | extension_loader_napi.cpp:7722 | 待用户/设备证据 |
| Q-g | 远端硬件编码器可能不支持运行中改码率 | 推测 | 待官方客户端 A/B |

## 4. 共享诊断基础

### 4.1 版本策略

- `DIAGNOSTIC_CAPTURE_SCHEMA_VERSION` v8 → v9，保留 v4–v8 读取兼容，不回写旧版本。
- `DIAGNOSTIC_EVENT_CATALOG_VERSION` v1 → v2；`DIAGNOSTIC_REDACTION_POLICY_VERSION` v3 → v4；`DIAGNOSTIC_AI_BUNDLE_SCHEMA_VERSION` v1 → v2。
- 导出 manifest 增加 `producerBuildId`、`sourceVersions`、`captureProfile`、`nativeSinkVersion`、`selectedSessions`、`coverageMask`、`coverageComplete`、`missingEvidence[]`、`droppedNativeEvents`、`droppedArktsEvents`、`clockAlignment`。

### 4.2 事件通用形状

`sequence, elapsedMs, wallTimeMs, moduleId, sessionRef, generation, source, stage, eventCode, level, outcome, code, reason, durationMs, count, bytes, facts, evidenceLevel, provenance`

`bytes` 必须带语义：`wireBytes | callbackBytes | decoderBytes | copiedBytes | uploadBytes | presentedBytes`；无法区分时写 `unknown` 或 `coverage_missing`。

### 4.3 Native Structured Diagnostic Sink

- 每 session ring buffer + 进程级 capture boundary；session/generation 关联，旧 generation 不得污染新 session。
- 回调中不做阻塞 IO、JSON 序列化或网络请求；记录溢出、采样丢弃、source unavailable、clock mismatch。
- NAPI 只提供有界查询，不暴露指针、文件路径或 raw payload。
- 首批来源：`freerdp_adapter.cpp`、RustDesk bridge/FFI、`extension_loader_napi.cpp`、network observer、renderer/frame pump；其他协议先接状态和错误阶段。
- raw hilog 只用于人工复核，不作为 AI 默认输入。

### 4.4 Capture profile

| Profile | 用途 | 采样 |
|---|---|---|
| `minimal` | 普通支持 | 状态转移和低频快照 |
| `rdp-deep` | RDP 协商/编码/黑屏/高流量 | native 阶段全量，runtime 1 秒 |
| `rustdesk-direct` | RustDesk 直连/EasyTier | 输入解析→TCP→Hash/Login→首帧全阶段 |
| `rustdesk-quality` | RustDesk 画质/码率 | 画质请求/发送、TestDelay 码率、codec、分辨率、缩放 |
| `all-protocol` | 跨协议问题 | 按选中模块 |
| `ai-triage` | AI 建议 | 问题分类后最小充分模块，强制补依赖模块 |
| `full` | 用户明确授权的短时深度取证 | 所有允许模块，严格容量上限 |

### 4.5 Capture boundary

- start：创建 owner、绑定 session/generation、清空旧 native cursor；stop/deadline：先采样 native 终止事件再写 summary。
- 账号退出/切换、退款、Pro 撤权：取消未完成 AI capture，清理内存 bundle 和临时附件。
- 容量超限写 `capture_overflow` + `coverage_missing`，不得静默丢失。
- **任何连接尝试（含 ArkTS 预检和输入校验拒绝）必须至少产生一条对应协议模块的 request/failed 事件。**

### 4.6 AI Evidence Bundle v2 与只读接口

- Bundle：`manifest, questionContext, capturePlan, evidenceCoverage, missingEvidence, sessionIndex, factSummary, eventIndex, events, provenance`；`eventIndex` 提供稳定引用（如 `capture-2/session-1/g3/seq-18`）。
- 应用内部 typed 接口：`plan_capture / start_capture / get_capture_status / stop_capture / get_bundle / get_missing_evidence / compare_sessions`。每次调用重新检查账号 owner/generation、Pro 权益、capture lease、页面/浮窗 generation、Provider profile revision、consent。
- 输出契约：`finding, confidence, evidenceRefs, confirmedFacts, hypotheses, missingEvidence, nextSteps, safeActions, unsupportedClaims`；每个结论必须引用 evidenceRef。
- 证据不足是一等结果：缺 `rdp_gfx_caps_confirmed`/`rdp_wire_codec_selected` 时必须返回“协商结果未确认”；缺 `rustdesk_quality_remote_bitrate` 时不得声称“画质已生效”。
- Provider 安全：API Key/OAuth secret 不进 bundle/日志/备份/同步/邮件；只发送二次脱敏 bundle；只记录 providerId、modelId、bundle hash、大小、耗时、结果；禁止任意 URL/redirect/Header/Shell/文件/连接/邮件工具；短 TTL、可一键清理；Provider 返回内容视为不可信文本。

## 5. 协议事件与 facts

### 5.1 RDP

事件：`rdp_transport_resolve, rdp_transport_connect_attempt, rdp_transport_connected, rdp_transport_closed, rdp_security_negotiation, rdp_client_capabilities, rdp_server_capabilities, rdp_graphics_settings, rdp_gfx_channel_connected, rdp_gfx_channel_disconnected, rdp_gfx_caps_advertised, rdp_gfx_caps_confirmed, rdp_wire_codec_offered, rdp_wire_codec_selected, rdp_decoder_init, rdp_decoder_reset, rdp_decoder_frame, rdp_surface_created, rdp_surface_deleted, rdp_start_frame, rdp_end_frame, rdp_frame_ack, rdp_presentation, rdp_resize, rdp_fallback, rdp_reconnect, rdp_disconnect, rdp_teardown`

facts：`endpointMode, configuredTransport, observedTransport, endpointFamily, networkGeneration, selectedProtocol, supportDynamicChannels, supportGraphicsPipeline, remoteFxCodec, gfxH264, compiledGfx, compiledH264, gfxResetSafe, h264PathSafe, gfxChannelState, gfxChannelGeneration, capabilityVersions, capabilityFlags, wireCodecOffered, wireCodecSelected, decoderBackend, decoderProfile, decoderInitResult, surfaceCount, frameId, frameAckCount, resetCount, resizeCount, fallbackReason, fallbackScope, fallbackGeneration`

### 5.2 RustDesk 直连

事件：`rustdesk_direct_input_parsed, rustdesk_direct_preflight, rustdesk_direct_tcp_attempt, rustdesk_direct_tcp_result, rustdesk_direct_handshake, rustdesk_direct_login, rustdesk_first_frame, rustdesk_direct_relay_fallback`

facts：`route=direct_ip|force_relay`、`endpointSource=manual_direct|lan_discovery|overlay_direct`、`endpointFamily`、`port`、`scopedIpv6`、`stage`、`errorCategory`、`nativeGeneration`、`durationMs`、`fallbackOccurred`。不记录完整 IP、密码、Key、RustDesk ID。

### 5.3 RustDesk 画质

事件：`rustdesk_quality_requested, rustdesk_quality_rejected, rustdesk_quality_sent, rustdesk_quality_remote_bitrate, rustdesk_stream_options_sent`

facts：`requestedQuality, effectiveQuality, sentQuality, qualityGeneration, rejectionReason, profile, streamFps, preferredCodec, activeCodec, remoteTargetBitrateKbps（来自 TestDelay）, bitrateBefore/After, remoteWidth/Height, viewScaleMode, localScaleFactor, chroma=420|444|unknown`

## 6. 统一实施阶段

阶段按依赖排序；每个阶段独立分支 checkpoint、独立复核、独立回退。

### P0：快速补洞（小改动，先回答“现在到底是什么”）

不升级 schema，直接在现有 v8 capture 和 HUD 中补齐：

1. RDP：把 `graphicsMode`、`gfxChannelConnected`、实际 `SupportGraphicsPipeline/RemoteFxCodec/GfxH264` 设置并入 runtime facts；`copiedBytes` 不再写入 `receivedBytes`，改用独立字段；HUD 未连接 GFX 时显示“GFX 未连接（GDI 呈现）”而非 `gdi`。
2. RDP：`g_nextConnectionGfxFallback` 的 mark/consume 写诊断事件（原因、来源 session、消费 session）。
3. RustDesk：所有连接尝试（含 ArkTS 预检/校验拒绝）至少写一条 `connection.rustdesk` request/failed 事件，携带 route、endpointSource、stage、errorCategory。
4. RustDesk：TestDelay 的 `target_bitrate_kbps`、`last_delay_ms` 进入 diagnostics snapshot、HUD 和 capture；画质 NAPI 拒绝原因进入 capture。

退出条件：同一 Windows RDP 端点能从 capture 区分 GDI 与 GFX；一次失败的 EasyTier 直连 capture 中出现 `connection.rustdesk` 阶段事件；切换画质前后能看到远端目标码率是否变化。

### P1：现场证据基线（无行为修改）

1. RDP：用同一 Windows 服务端对照官方 RDP 客户端，确认 route、GFX channel、wire codec、decoder、presentation/wire bytes、fallback；把问题归类为 GFX/RFX、GDI fallback、H.264 gate、decoder、网络或日志缺口之一。
2. EasyTier：官方 RustDesk 与 RemoteDesktop 使用相同 EasyTier IP、端口、设备密码 A/B；确认官方客户端实际走直连还是 ID/relay；记录 RemoteDesktop 失败阶段。
3. 画质：同一 peer 下记录切换画质时的 toast 文案、HUD“画质 偏好/生效/已发送”、TestDelay 码率前后变化；与官方客户端切换画质、开关“真彩 4:4:4”对照，判断清晰度差异来源（码率、4:4:4、分辨率还是本地缩放）。

退出条件：三个问题各自有可引用的失败阶段或差异来源，不再依赖猜测。

### P2：EasyTier 入口与配置一致性（原计划 A/B）

1. 一级入口改为“直连（局域网 / EasyTier）”；二级为“手动地址”（局域网 IP、EasyTier、VPN、域名）和“局域网搜索”（仅同一二层网络 UDP 21119）。
2. 手动地址页说明：EasyTier 填虚拟 IP 不填 RustDesk ID；端口默认 21118 可改；必须填设备密码；控制 ID 可空。
3. 添加后立即回读 `rustdeskDirectEnabled/Host/Port`；编辑、保存、冷启动、云同步、主机卡片使用同一 canonical endpoint。
4. 增加 `manual_direct / lan_discovery / overlay_direct` 来源标记，不用 `lanAddressMode` 表达 EasyTier。
5. 旧主机只在明确识别为 direct record 时迁移到 `direct_ip`；不把 EasyTier 地址绑定为 relay endpoint；地址变化提示“直连地址已变化，请重新确认”。

### P3：画质可见性与诚实性修复（低成本）

1. 实时切换画质成功发送后补发一次 `refresh_video`，让新码率立即体现在关键帧上（偏离上游的有意行为，需记录并做 VP9/H264/H265 刷新压力回归）。
2. “已生效”判定改为基于证据：发送后在有界窗口内观察 TestDelay `target_bitrate_kbps` 变化；变化则提示“远端码率已调整”，无变化则提示“远端未报告码率变化（可能受网络自适应或编码器限制）”；对端版本不提供该字段时显示“无法确认”。
3. 选项文案说明真实含义：“画质优先：提高远端编码码率；文字锐利度另受真彩(4:4:4)、分辨率和缩放影响”。
4. `max_edge_px`：删除无效字段，或决定由画质档位真正驱动请求分辨率（需与 2026-10-01 显示/分辨率 profile 计划协调，避免覆盖用户显式分辨率）。推荐删除，分辨率由显示计划单独负责。
5. 本地缩放提示：远端分辨率大于窗口且为“适应窗口”时，在画质子菜单显示“当前按 X% 缩放显示”。

### P4：统一 schema v9 与 Native Sink（原计划 M0–M2）

1. M0：schema v9、event catalog v2、redaction v4、RDP/RustDesk facts 类型、证据等级、fixture 与迁移策略。
2. M1：bounded native sink、NAPI 有界查询、ExtensionLoader bridge、native/ArkTS 时间对齐；native 不可用、ring overflow、旧 generation、deadline 都产生可解释事件。
3. M2：`rdp-deep`、`rustdesk-direct`、`rustdesk-quality`、`all-protocol` profile；v9 JSONL、coverage summary、旧 schema 读取、脱敏与容量测试。

退出条件：一次短 capture 能完整导出 RDP 协商→GFX channel→codec→decoder→presentation→fallback→teardown，以及 RustDesk 直连 输入→TCP→Hash/Login→首帧，以及画质 请求→发送→远端码率。

### P5：RustDesk 直连 preflight 与 native 修复（原计划 C/E）

1. 有界直连 preflight，与正式连接复用同一规范化 endpoint：输入解析 → DNS/路由/TCP（无路由、超时、拒绝）→ Hash/Login（首包、peer identity、密码）→ 首帧；每层稳定脱敏错误类别，不再只显示 `-2`。
2. 按 P1/P5 证明的阶段修复：TCP 前失败修 canonicalization、端口、路由可见性；TCP 成功 Hash/Login 失败核对官方 Peer 版本、直连 identity、密码、首包；登录成功无首帧查 decoder/stream，不归因于 EasyTier。

### P6：RDPGFX/RFX 稳定化（原计划 M5）

1. 覆盖 caps、channel、surface、StartFrame/EndFrame、ACK、resize、reset、后台、重连和回退。
2. `g_nextConnectionGfxFallback` 改为按主机/端点作用域（或仅限同一主机的立即重连），回退原因进入 `rdp_fallback` 事件，不修改用户配置。
3. 退出条件：`graphicsMode=gfx` 且 `wireCodec=rfx/RemoteFX` 可由证据确认；GDI fallback 有明确原因且不污染其他主机和后续无关 session。

### P7：AI 取证接口（原计划 M3）

AI bundle v2、typed capture tools、missing evidence、evidenceRefs、session compare、账号/权益/owner 隔离；AI 无法访问 raw hilog 或任意系统能力；证据不足时不能生成确定性的 H.264、EasyTier 根因或“画质已生效”结论。

### P8：独立实验（各自 gate，默认关闭）

1. RDP AVC420/H.264（原 M6）：decoder runtime probe、AVC420 capability、decoder frame telemetry、reset/resize/reconnect/stress、per-session gate；仅完整矩阵通过的设备/ABI/构建允许 `gfx-h264`，失败回退 AVC420→RFX/GFX→GDI。
2. RustDesk 直连到中继回退（原 F）：仅明确的网络错误允许回退到已配置 relay；密码、权限、peer key、协议错误不回退。AUTO/NAT/TCP 打洞另立计划。
3. RustDesk 4:4:4 真彩：先探测 HarmonyOS 硬件解码器对 YUV444 H264/H265 的支持；不支持时评估 VP9 4:4:4 软解或 H264 High 4:4:4 软解的 CPU/功耗/帧率代价；仅能力探测通过时向远端通告 `i444`，否则选项置灰并说明。
4. RustDesk 自定义画质：评估 `custom_image_quality` + 自定义 FPS，需按目标 peer 版本核对字段编码。

### P9：灰度与发布（原 M7 + 设备矩阵）

双 ABI、Windows 10/11/Server、HarmonyOS PC/Phone/Pad、direct/Gateway、IPv4/IPv6、1080p/2K/4K、EasyTier A/B、画质对照、AI 取证和五协议回归。

## 7. 测试计划

### 7.1 单元/策略测试

- schema v8→v9 兼容读取；event order、generation、clock alignment；native sink 并发、环形缓冲、溢出、清理。
- redaction canary：密码、token、API Key、私钥、地址、RustDesk ID、路径、终端文本。
- RDP facts 映射：GDI、GFX/RFX、AVC420、fallback、decoder fail；wire/copied/presented bytes 分离；全局 GFX fallback 作用域。
- RustDesk 直连：EasyTier IPv4 控制 ID 为空保存正确；自定义端口经编辑/冷启动/云同步不变；局域网搜索仍要求发现 ID；密码为空、请求批准、scoped IPv6、非法端口/地址给出明确错误；direct/relay 字段互斥；预检拒绝必产生 `connection.rustdesk` 事件。
- RustDesk 画质：拒绝原因映射；发送后补发刷新；生效判定（码率变化/无变化/字段缺失三态）；generation 覆盖（快速连切只确认最后一次）。
- AI bundle schema、evidenceRefs、missingEvidence、truncate；capture owner 冲突、账号切换、权益撤销。

### 7.2 Native/FFI fixture

- RDP：GFX disabled、GFX+RFX、H264 compiled not requested、H264 advertised/rejected、AVC420 selected、decoder init/reset failed、GFX timeout、RESET_GRAPHICS、resize、reconnect、stale callback、GFX→GDI fallback、跨主机 fallback 隔离。
- RustDesk 直连：TCP timeout、connection refused、TCP 成功 Hash 错误、密码错误、登录成功无首帧；IPv4、全局 IPv6、hostname；断网、EasyTier 路由变化、取消连接后旧连接不污染新连接。
- RustDesk 画质：TestDelay 带/不带 `target_bitrate`；画质控制消息在握手期间与串流期间入队；刷新与背压降级并发。

### 7.3 真实设备与服务端

- RDP：Windows 10/11/Server；服务端 H.264/RemoteFX 开/关；direct/Gateway；IPv4/IPv6；1080p/2K/4K；resize、前后台、Surface 重建、重连；与官方客户端同端点对照；socket/channel bytes 与 render bytes 分开测量。
- EasyTier：同局域网 IPv4 直连；EasyTier IPv4；EasyTier 地址变化后重连；EasyTier IPv6（若产品支持）；官方客户端 A/B；直连失败 relay 可达时的回退行为。记录设备型号/API、地址族、Peer 版本、监听端口、实际 route、失败阶段。
- 画质：Windows peer 的软件编码与硬件编码各一台；静态文字、滚动网页、视频三类场景；三档画质的远端码率与主观清晰度；与官方客户端“画质/真彩”对照。
- 协议隔离：RustDesk、SSH/SFTP、VNC、Moonlight 回归；AI provider、账号切换、Pro 撤权、bundle 清理与 evidenceRef 回溯。

## 8. 回退与失败处理

- native sink 不可用：保留 ArkTS capture 并写 `coverage_missing(native)`；ring overflow 写计数和缺失窗口。
- AI bundle 超限：保留 manifest、summary、evidence index 和最新关键事件，完整 bundle 留本地。
- GFX channel/decoder/renderer 失败：当前 session（或同一主机立即重连）回退，不修改用户配置，不影响其他主机。
- H.264 失败：AVC420→RFX/GFX→GDI，保留精确 fallback reason。
- 直连失败：只在网络类错误且已配置 relay 时提示/执行回退；认证/协议错误直接显示分层错误。
- 画质刷新引发压力：沿用现有背压降级，补发刷新限频；远端不报告码率时显示“无法确认”而非“已生效”。
- AI Provider 失败：本地 bundle、传统日志导出和系统邮件流程仍可用；账号/权益/owner generation 改变时取消受保护请求并清理内存 secret。

## 9. 实现文件边界

首批允许范围（P0–P7）：

```text
entry/src/main/cpp/diagnostics/DiagnosticEventSink.*
entry/src/main/cpp/extensions/extension_loader_napi.cpp
entry/src/main/cpp/extensions/protocol_adapter.h
entry/src/main/cpp/rdp/freerdp_adapter.cpp
entry/src/main/cpp/rdp/rdp_graphics_lifecycle.*
entry/src/main/cpp/rustdesk/rustdesk_bridge.*
entry/src/main/cpp/types/librdpnapi/index.d.ts
entry/src/main/ets/types/rdpnapi.d.ts
entry/src/main/ets/services/DiagnosticCapturePolicy.ets
entry/src/main/ets/services/DiagnosticCaptureRuntime.ets
entry/src/main/ets/services/DiagnosticCaptureExportService.ets
entry/src/main/ets/services/DiagnosticRuntimeSnapshotPolicy.ets
entry/src/main/ets/services/ExtensionLoader.ets
entry/src/main/ets/services/RustDeskConnectionStrategyPolicy.ets
entry/src/main/ets/services/RustDeskHostConfigPolicy.ets
entry/src/main/ets/services/diagnosticAi/DiagnosticAiBundlePolicy.ets
entry/src/main/ets/services/diagnosticAi/DiagnosticAiCaptureOrchestrator.ets
entry/src/main/ets/services/diagnosticAi/DiagnosticAiAgentService.ets
entry/src/main/ets/services/diagnosticAi/DiagnosticAiModels.ets
entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets
entry/src/main/ets/components/RemoteSessionTopBar.ets
entry/src/main/ets/components/RustDeskDiagnosticsHud.ets
entry/src/main/ets/components/RdpDiagnosticsHud.ets
entry/src/main/ets/pages/RemoteDesktop.ets（仅画质与连接诊断相关函数）
rustdesk_ffi/src/lib.rs
rustdesk_ffi/src/connector.rs
rustdesk_ffi/src/protocol/session.rs
entry/src/test/*Diagnostic* entry/src/test/*RustDesk*
scripts/tests/*diagnostic* scripts/tests/*rustdesk*
entry/src/main/cpp/test/*diagnostic*
```

FreeRDP 子模块、FFmpeg、OpenSSL、RustDesk 上游依赖、SSH、VNC、Moonlight 行为在 P0–P7 不升级。仅 P8 明确需要依赖变化时同步 provenance、NOTICE、SBOM、hash 和双 ABI 产物。

## 10. 仓库执行顺序与门禁

1. 本计划仅作为文档保存；当前 session 不实现代码。
2. 当前 `codex/pro-purchase-foundation` 先完成既有任务或由用户明确归档（存在 22 处未提交修改与 `REVIEW_REQUIRED`）。
3. 实现使用新的 `codex/<task>` 分支（建议 `codex/rdp-rustdesk-observability`），不得混入现有脏文件；P0 可作为第一个独立 checkpoint。
4. 每个阶段修改代码后执行 AGENTS.md 规定的两项 Hvigor 门禁（`OhosTestCompileArkTS`、`assembleHap`），以及 Rust FFI 构建、native 测试、diff-check、合规检查和子 agent 复核。
5. 旧日志、旧 HAP 不能替代新 schema、新 buildId 和真实设备/服务端证据。

## 11. 完成定义

- 结构化 capture 能回答 RDP route、capability、wire codec、decoder、presentation、fallback、teardown；`gdi/raw/relay/unknown` 不再被当作线协议事实。
- GFX fallback 不跨主机传播，并以事件形式可追溯。
- RustDesk 直连每次尝试都有分阶段事件；EasyTier 手动地址流程清晰，endpoint 保存/恢复一致；真实 EasyTier A/B 给出可复现结论。
- RustDesk 画质切换有远端码率证据和三态反馈；用户能分辨“码率已调”“远端未调整”“无法确认”；4:4:4 有能力探测结论。
- AI bundle 具有证据来源、覆盖率、缺失项和可回溯 evidenceRef；证据不足时拒绝确定性结论。
- AVC420/H.264、直连→中继回退、4:4:4 仅在各自 gate 通过后放行；所有失败都能回退到当前稳定路径。
- 传统日志导出、反馈邮件和其他协议不回归；双 ABI、构建、合规、真机和服务端证据均来自当前提交。

## 12. 待用户决策

1. 当前 Pro 分支如何收尾（完成复核合并 / 暂存归档），决定新分支何时启动。
2. P0 是否作为最先执行的独立 checkpoint（推荐）。
3. `max_edge_px` 删除还是由画质档位驱动分辨率（推荐删除）。
4. 实时切换画质后补发刷新是否接受（推荐接受，限频）。
5. EasyTier IPv6、4:4:4 真彩、自定义画质是否进入本轮范围（推荐仅做能力探测）。

## 13. 实施记录

### 13.1 Checkpoint A（2026-10-04，P0/P2/P3/P5/P6 中可在本地完成的部分）

| 计划项 | 落地内容 | 主要文件 |
|---|---|---|
| P0-1 RDP 线上编码证据 | 钩住 RDPGFX `CapsAdvertise`/`CapsConfirm`/`SurfaceCommand`，按编码 ID 统计帧命令与负载字节；连接前请求设置与实际确认/线上编码分开导出；HUD 分为“图形管线 / GFX 能力 通告→确认 / 线上编码 / H.264” | `rdp/rdp_gfx_wire_evidence.*`、`freerdp_adapter.cpp`、`RdpGraphicsEvidencePolicy.ets`、`RdpDiagnosticsHud.ets` |
| P0-1 字节语义 | `copiedBytes` 不再写入 `receivedBytes`；RDP 事件 bytes 改为 GFX 线上负载字节；本机拷贝字节只在 `rdpGraphics.copiedBytes` | `ExtensionLoader.ets` |
| P0-2 / P6 GFX 回退 | 进程全局一次性回退改为按主机+端口作用域（最多 32 个），回退原因进入 `rdpGraphics.fallbackReason`；协商变化记 `rdp_graphics_negotiation` | `freerdp_adapter.cpp`、`ExtensionLoader.ets` |
| P0-3 / P5 RustDesk 早期失败与分阶段 | 预检 6 处本地校验失败补写 `rustdesk_preflight` 事件；新增 `rustdesk_direct_stage`（来源、阶段、地址类别，无地址）；native RDERR 拆为 输入/TCP 超时/拒绝/无路由/中断/登录/首帧 并给出面向 EasyTier 的提示 | `RustDeskDirectRoutePolicy.ets`、`HostListPage.ets` |
| P2 EasyTier 入口 | “局域网直连”改为“直连（局域网 / EasyTier）”，二级“手动地址 / 局域网搜索”加说明；添加后从数据库按 ID 回读直连地址/端口，不一致则回滚 | `RustDeskAddFlow.ets`、`HostSyncService.ets`、`CloudStore.ets` |
| P3 画质 | 实时切换成功后合并限频补发 `refresh_video`；依据远端 TestDelay 目标码率给出“升高/降低/未变化/未报告/发送失败”结论并记 `rustdesk_quality_request/result`；菜单标明“降低/提高码率”；缩小显示时提示缩放比例；HUD 显示远端目标码率；删除无效 `max_edge_px`/`req_width` | `connector.rs`、`lib.rs`、`RustDeskQualityConfirmationPolicy.ets`、`RemoteDesktop.ets`、`RemoteSessionTopBar.ets` |
| 契约 | capture schema v9、event catalog v3、redaction v4；新事件全部归入日志子模块并写入 AI 词表 | `DiagnosticCapturePolicy.ets`、`DiagnosticCaptureFacetPolicy.ets`、`DiagnosticAiEventGlossary.ets` |

设计决定：

- “overlay_direct”无法从地址证明，来源只记录配置方式（手动地址 / 局域网搜索），地址只导出闭合类别（私有 IPv4、100.64/10、IPv6 ULA 等），并在词表中注明“地址类别不能证明使用了哪种虚拟网”。
- `max_edge_px` 删除；分辨率继续由 2026-10-01 显示计划负责。
- 补发刷新偏离上游 `sessionSetImageQuality` 的行为，最小间隔 750 ms 合并。

仍未完成、需要设备/服务端：P1 现场基线、P8 实验（H.264、直连→中继回退、4:4:4、自定义画质）、P9 设备矩阵。P4 的覆盖率汇总与 P7 AI bundle v2 在 checkpoint B 实施。
