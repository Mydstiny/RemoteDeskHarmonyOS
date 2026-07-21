# RustDesk 连接诊断与专业性能显示（Pro）实施计划

- 版本：v0.3（同步 2026-07-21 RustDesk 诊断链路实现检查点）
- 复核日期：2026-07-21
- 公共实现基线：`main` / `origin/main` = `1f16f361a`
- 复核工作区：`codex/rustdesk-performance-diagnostics` @ `1f16f361a`，实现代码尚未提交，用户自有截图/日志/其他任务文档保持未触碰
- 文档状态：计划与代码复核已同步；本地实现链路和自动化验证已完成，剩余是 Light 合规复核、受控提交和真实 HarmonyOS 设备验收
- 交付边界：本检查点交付本机连接诊断与专业性能显示；远端 CPU/内存/GPU、首帧/重连/输入拖放真机证据仍不纳入“已验收”
- 文档中的 `Pro`：仅表示“专业性能显示”，与 RustDesk Server Pro、Pro 地址簿和授权版本无关

## 1. 结论先行

当前工作树已经落地从 Rust 协议统计到会话 HUD 的完整本地链路：每个 FFI 连接有 `RustDeskStreamStats`，streaming 线程更新视频/音频/TestDelay/cadence，C++/NAPI/ExtensionLoader 提供查询，RemoteDesktop 每秒轮询并显示 HUD；设置 Row、Pro 依赖、ABI 校验、decoder/render 统计、资源采样门控和 session/attempt 代际隔离均已实现。

第一版建议交付两级显示：

1. `显示连接诊断信息`：显示协议延迟、接收 FPS、展示 FPS、实时码率、实际分辨率、实际 codec、解码器后端和连接路径。
2. `专业性能数据（Pro）`：在基础信息之上显示队列、丢帧、关键帧、帧间隔、解码/渲染 p50、p95、max，以及本机应用 CPU、内存和可用时的 GPU 负载。

远端 CPU、内存和 GPU 实时负载不纳入第一版完成定义。当前 HarmonyOS 客户端是控制端，现有 RustDesk FFI 没有远端实时资源上报消息；远端负载必须由被控端 Agent、兼容的 RustDesk core 扩展或独立监控服务配合，并经过能力协商和授权。

## 2. 产品契约

### 2.1 设置层级与位置

在“设置 → RustDesk”卡片底部、现有 `远端音频` 后新增：

```text
显示连接诊断信息                           [开关]
连接时显示延迟、帧率、码率、分辨率和编码信息

    专业性能数据（Pro）                    [开关]
    进一步显示解码、渲染、队列和本机资源负载
```

规则：

- 设置键使用 `rustdeskShowDiagnostics` 和 `rustdeskShowProDiagnostics`。
- 两个开关默认都为 `false`。
- Pro 是基础诊断的子开关；基础诊断关闭时，Pro 行置灰且不生效。
- 关闭基础诊断时保留 Pro 的上次选择；再次开启基础诊断后恢复原状态。
- 两个设置仅写入 `RemoteDesktopAppPrefs` 和 `AppStorage`，不进入 `CloudStore`、云同步、主机 JSON 或 Server Pro 账户数据。
- 不使用 `rustdeskProEnabled` 等容易与 Server Pro 混淆的命名。

当前工作树已经落地两个键的 `@StorageLink`、Preferences/AppStorage 读取回写、`persistLocalRustDeskBooleanPref()`、RustDesk 设置卡片两行 Row 和 Pro 置灰依赖；RemoteDesktop 消费这些状态启动/停止 HUD/poll。阶段 1 已完成代码实现，仍需在设备上确认展开高度和重启保持效果。

### 2.2 基础显示字段

| 字段 | 数据来源 | 展示规则 |
| --- | --- | --- |
| 协议延迟 | RustDesk `TestDelay.last_delay` | 有效值前显示 `--`；文案为“延迟”，内部字段命名为 `protocolDelayMs` |
| 接收 FPS | 编码帧进入 native 视频回调的滚动窗口 | 一位小数或整数，窗口无数据时显示 `--` |
| 展示 FPS | 硬解/软解输出进入实际渲染路径后的滚动窗口 | 与接收 FPS 分开显示，禁止用解码提交数冒充 |
| 实时码率 | 编码帧字节数 / 滚动窗口 | 小于 1 Mbps 显示 Kbps，否则显示 Mbps |
| 实际分辨率 | `FfiVideoFrame.width/height` | 显示远端实际帧尺寸，不使用初始化期望尺寸 |
| 实际 codec | `FfiVideoFrame.codec` | 显示 H264/H265/VP8/VP9/AV1；不使用用户偏好代替实际值 |
| 画质 | `rustdeskImageQuality` + 实际分辨率/码率 | 只显示速度/平衡/质量档位，不虚构客观画质评分 |
| 解码器 | 当前 `DecoderContext` | 显示“硬件”或“软件” |
| 连接路径 | 会话配置与 RustDesk 建链结果 | 第一版至少区分直连与 ID/中继；无法确定真实 NAT 路径时标注“配置路径” |

### 2.3 Pro 显示字段

第一版 Pro 字段固定为：

- 解码后端：hardware / software。
- 实际 codec 与当前解码器 codec。
- 解码提交成功、未就绪、codec 不支持、codec 不匹配、其他失败。
- 当前队列深度、窗口最大队列深度。
- 累计丢帧、等待关键帧丢帧、软件队列丢帧、软件跳过展示帧。
- 接收帧、展示帧、关键帧累计数。
- 最近帧间隔、窗口最大帧间隔、超过 200 ms 的 cadence gap 数量。
- 解码提交耗时 p50/p95/max。
- 解码输出到展示耗时或端到端帧耗时 p50/p95/max；只有能够准确打点的字段才显示。
- 渲染上传、绘制、swap、总耗时 p50/p95/max。
- 本机应用 CPU 使用率、本机应用 RSS、可选的系统内存使用率。
- 本机 GPU 使用率；没有稳定公开接口时显示“不可用”，不填 0%。
- 远端资源状态：第一版固定按能力显示“不支持”或“待授权”，不得显示伪造值。

## 3. 当前代码复审

### 3.1 设置与持久化

`entry/src/main/ets/pages/HostListPage.ets` 当前已经读取并维护：

- `rustdeskImageQuality`
- `rustdeskCodec`
- `rustdeskLanDiscovery`
- `rustdeskPrivacyMode`
- `rustdeskAudioEnabled`
- 其他剪贴板、控制模式和鼠标偏好
- `rustdeskShowDiagnostics`、`rustdeskShowProDiagnostics` 两个本地诊断偏好

RustDesk 设置卡片当前依次包含图像质量、编码、控制模式、LAN 发现、隐私模式、远端音频、基础诊断和专业性能数据（Pro）；Pro 行通过 `enabled` 依赖基础开关，基础关闭时保留上次选择但不生效。

现有 `persistRustDeskBooleanPref()` 和 `persistRustDeskNumberPref()` 会同时调用 `CloudStore.upsertUserSetting()`；诊断偏好使用不调用 CloudStore 的 `persistLocalRustDeskBooleanPref()`，因此不会进入云同步或主机数据。Preferences 失败时仍由既有 AppStorage 默认值兜底；设置卡片高度需要设备验收确认。

### 3.2 ArkTS 远程页面

`entry/src/main/ets/pages/RemoteDesktop.ets` 当前：

- 使用 `@StorageLink` 读取 RustDesk 质量、codec、音频、剪贴板和输入设置。
- 在连接成功后启动远端光标轮询，并通过 `RemoteSessionTopBar` 显示会话控制项。
- 当前代码已新增 `RustDeskDiagnosticsHud`，在远程画面 Stack 中以 `HitTestMode.None` 显示基础/Pro 指标，并由 `rustDeskDiagnosticsTimer` 每 1000 ms 查询。
- 轮询已接入普通连接、预鉴权恢复、页面销毁、断开和后台脱附路径，并在查询前后同时校验 `sessionId` 与 `connectAttemptId`；旧同步查询结果不能覆盖新连接。
- HUD 使用 `HitTestMode.None`，固定宽度/位置的安全布局仍属于设备验收项，需确认 Phone/Pad/PC、顶部栏、修饰键和文件拖放不重叠。

### 3.3 C++ NAPI 视频入口

`entry/src/main/cpp/extensions/extension_loader_napi.cpp` 当前在 `NapiConnect()` 中注册统一视频回调：

```text
RustDesk frame
  -> recordRemoteVideoFrame()
  -> g_rustdeskVideoPerf.recordIngressFrame()
  -> DecoderNapi::DecodeActiveNative()
  -> g_rustdeskVideoPerf.recordDecodeResult()
```

当前代码变动已经增加：

1. `SessionContext.diagnostics` 的 per-session ingress 帧数、字节、关键帧、最后 codec/宽高/时间戳和有界 decode duration 样本。
2. `NapiGetRustDeskDiagnostics(sessionId)`，合并 `RustDeskBridge::getDiagnostics()`、session counters 和 `DecoderNapi::GetActiveTelemetry()`，并注册为 `getRustDeskDiagnostics`。
3. `NapiGetLocalResourceStats()`，通过 `/proc/self/stat`、`/proc/stat` 和 `/proc/self/status` 读取本机 CPU/RSS；GPU 明确返回 unavailable。
4. 当前视频回调仍保留 `g_rustdeskVideoPerf.snapshotAndReset()` 的旧日志/压力反馈路径，NAPI 诊断使用 `SessionDiagnosticsCounters` 与 renderer/decoder snapshot，读取不清零 UI 统计；旧路径的 queue/drop 参数仍不是 Pro 统计来源，不能混用。

当前已解决：查询保留 `SessionContext` shared state，teardown 从 `g_sessions` 移除后旧回调仍只写自己的上下文；decoder 查询校验 active session，renderer 从真实 swap/presentation 路径提供成功展示窗口；native 维护 FPS/码率窗口，资源采样支持 `includePro`、首次样本 unavailable 和 1 秒限频。`getRdpRenderStats()` 仍是 RDP 专用接口，RustDesk 不伪装成 RDP 统计。

### 3.4 Rust FFI

`rustdesk_ffi/src/connector.rs::run_streaming()` 当前已经在 streaming 线程中维护：

- `video_count`
- `keyframe_count`
- `encoded_subframe_total`
- `cadence_gap_count`
- `max_cadence_gap_ms`
- `window_video`
- `active_video_codec`
- `test_delay_echo_count`

视频帧已经通过 `FfiVideoFrame` 向 C++ 暴露：

- data/size
- width/height
- codec
- timestamp
- is_key_frame

`TestDelay` 当前仅被回包并计数。官方 RustDesk 的 `TestDelay.last_delay` 是控制端可以直接显示的协议延迟值；客户端收到消息到发出回包的本地耗时不是网络 RTT，不能作为“延迟”展示。

当前工作树的 `RustDeskClient` 已新增 `stream_stats: Arc<Mutex<RustDeskStreamStats>>`。`rustdesk_connect()` 按连接创建快照并以 clone 传入 `run_streaming()`；streaming 线程目前更新视频消息/帧/关键帧、编码字节、实际 codec、音频帧、cadence gap、TestDelay 和目标码率，断流时把 state 置为 disconnected。`rustdesk_get_stream_stats(handle, out_stats)` 已通过 C ABI 以 copy snapshot 返回。

当前实现已形成可交付的本地诊断链路：C++ `RustDeskBridge::getDiagnostics()` 通过 FFI snapshot 补充 TestDelay/码率/cadence，NAPI/ExtensionLoader/type wrapper、RemoteDesktop poll、HUD、ABI `static_assert`/version 校验、UI session generation 和 Pro 采样门控均已接入。Rust 结构中的 width/height 仍由连接初始 `peer_display_size()` 填充；UI 优先使用 C++ 视频回调逐帧记录的实际 width/height，但它仍不能替代独立的 `RemoteVideoGeometry` 协议设计。

后续若要支持旋转、stride、裁剪和输入坐标映射，必须另立 `RemoteVideoGeometry` 设计；不得把诊断快照扩展成渲染几何控制面。

### 3.5 解码与渲染

`entry/src/main/cpp/render/hw_decoder.cpp/.h` 当前已经具备：

- 硬件输入队列和队列上限。
- 输入丢帧、等待关键帧丢帧、截断、输出失败、Surface 更新失败计数。
- 输出帧计数。
- `QueuedFrameCount()` 和 `DroppedFrameCount()`。
- software fallback 的 `softQueue`、`softDecoded`、`softDropped`、`softSkippedPresent`。
- `DecoderContext.useSoftware`，可以准确区分硬件和软件后端。
- 当前变动新增 `DecoderTelemetrySnapshot`/`DecoderNapi::GetActiveTelemetry()`，可读取 active decoder 的 backend、codec、尺寸、queueDepth、queueMax、droppedFrames 和 ready 状态。

当前实现边界：

- `DecoderTelemetrySnapshot` 提供 active decoder 的 backend、codec、尺寸、queueDepth、queueMax、drop 和 ready 状态；session 查询会校验 active session，避免重连读到旧 pipeline。
- C++ 会话计数器提供有界 decode submit 样本；硬件 `Decode()` 的 submit 耗时不冒充真实硬件完成耗时。
- GL renderer 的 RustDesk texture/raw-BGRA 路径统一记录真实 draw/swap 结果，并导出成功 presentation 窗口与 p50/p95/max。
- 真实设备上的 decoder 后端、首帧、重连和压力行为仍需按第 12 节矩阵验收；这属于运行证据，不再是接口实现缺口。

### 3.6 当前工作树的实现边界

截至 `codex/rustdesk-performance-diagnostics @ 1f16f361a`，与本计划直接相关的未提交代码只有：

| 文件 | 当前状态 | 不能据此宣称 |
|---|---|---|
| `rustdesk_ffi/src/lib.rs` | `#[repr(C)] RustDeskStreamStats`、每连接 `Arc<Mutex>`、创建/断开状态、copy snapshot 和 size/alignment/version 测试 | width/height 仍是初始 PeerInfo 尺寸；不宣称为完整逐帧 geometry |
| `rustdesk_ffi/src/connector.rs` | video/audio/TestDelay/cadence/编码字节更新快照，并保留原有字符串日志统计 | 协议快照不提供远端 CPU/内存/GPU，也不负责 UI generation |
| `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h` | `getDiagnostics()` 合并 callback 计数和 FFI snapshot，含 ABI `static_assert`/version 校验 | IPC/非 real-core 没有 Rust FFI 统计时按 unsupported/unknown 降级 |
| `entry/src/main/cpp/extensions/extension_loader_napi.cpp` | per-session ingress/decode counters、bounded samples、FPS/码率、session 查询、renderer/decoder 合并和 `includePro` 资源采样 | `/proc` 资源是本机进程指标，不是远端资源 |
| `entry/src/main/cpp/render/hw_decoder.cpp/.h` | active decoder backend/codec/queue/drop/ready 快照，并按 session 校验 | submit latency 不代表硬件完成 latency |
| `entry/src/main/ets/services/ExtensionLoader.ets`、`entry/src/main/ets/types/rdpnapi.d.ts` | 诊断/本机资源 wrapper、完整类型、unavailable 默认值和限频错误日志 | 不保存历史曲线、不上传云端 |
| `entry/src/main/ets/pages/HostListPage.ets` | 两个本地诊断键、读取/保存、设置 Row 和 Pro 依赖置灰 | safe-area/高度需设备验收 |
| `entry/src/main/ets/pages/RemoteDesktop.ets`、`entry/src/main/ets/components/RustDeskDiagnosticsHud.ets` | 1 秒 poll、session/attempt 代际校验、连接/后台/断开清理和不接触 HUD | 固定位置的 Phone/Pad/PC 避让需设备验收 |

此外，当前 `RustDeskStreamStats.width/height` 在 `rustdesk_connect()` 中来自 `peer_display_size()`，而 `FfiVideoFrame` 的 dispatch 仍使用连接时捕获的 `remote_width/remote_height`。因此这些字段只能作为“初始 PeerInfo 显示尺寸”诊断项；Android portrait 修复仍必须按总计划的 `RemoteVideoGeometry` 方案补充逐帧尺寸、rotation、stride 和 geometry epoch。

## 4. 总体架构

已实现的数据流（远端资源和逐帧 geometry 为明确的后续边界）：

```text
RustDesk protocol thread
  ├─ TestDelay / codec / protocol counters
  │    -> RustDeskStreamStats (Rust, per handle)
  │    -> rustdesk_get_stream_stats()
  │
  └─ FfiVideoFrame
       -> SessionContext.diagnostics.recordIngress()
       -> DecoderNapi::DecodeActiveNative()
       -> DecoderTelemetrySnapshot / bounded decode samples
       -> hardware/software output
       -> RendererNapi presentation snapshot

ArkTS RemoteDesktop
  -> getRustDeskDiagnostics(sessionId) + getLocalResourceStats(includePro)
  -> 1000 ms UI polling
  -> RustDeskDiagnosticsHud
```

当前工作树已实现上图中的 Rust snapshot、C++ Bridge 读取、NAPI session ingress/decode/presentation 合并、ArkTS ExtensionLoader/type wrapper、设置开关、RemoteDesktop 轮询和 HUD。固定 HUD safe-area 仍需设备确认；统计快照不是 `RemoteVideoGeometry`，不能驱动渲染器旋转、裁剪或输入坐标。

职责边界：

- Rust 只负责协议层统计：TestDelay、协议帧、实际 codec、协议路径和远端静态信息。
- C++ 负责 ingress、decoder、renderer 和本机资源统计。
- NAPI 按 `sessionId` 合并快照。
- ArkTS 只做轮询、格式化、显示和生命周期控制，不在 UI 层重新计算原始性能数据。

## 5. 数据结构与接口

### 5.1 Rust C ABI 快照

当前工作树已在 `rustdesk_ffi/src/lib.rs` 增加以下固定布局结构：

```text
RustDeskStreamStats { // 当前已实现字段，顺序属于 ABI 合同
  version: u32
  state: u32
  last_delay_ms: u32
  target_bitrate_kbps: u32
  video_messages: u64
  video_frames: u64
  keyframes: u64
  encoded_bytes: u64
  audio_frames: u64
  cadence_gaps: u64
  max_cadence_gap_ms: u64
  test_delay_count: u64
  actual_codec: i32
  width: i32                  // 当前为初始 PeerInfo 尺寸
  height: i32                 // 当前为初始 PeerInfo 尺寸
  connection_path: i32
}
```

当前已实现 `rustdesk_get_stream_stats(handle, out_stats) -> bool`，按值复制快照。C++ 侧已声明同布局并在 `RustDeskBridge::getDiagnostics()` 中读取/转换，但还没有完成 `static_assert`、版本校验、字段来源标记、读失败映射和 IPC/非 real-core 降级。

目标归一化结构仍应是：

```text
RustDeskStreamStats
  valid
  protocol_delay_ms
  target_bitrate_bps
  received_video_messages
  encoded_subframes
  keyframes
  cadence_gaps
  max_cadence_gap_ms
  actual_codec
  remote_width
  remote_height
  connection_path
  updated_at_monotonic_ms
```

目标/兼容接口仍应保持：

```text
rustdesk_get_stream_stats(handle, out_stats) -> bool
```

实现规则：

- 当前已完成 `RustDeskClient` 创建时建立 `Arc<Mutex<RustDeskStreamStats>>` 并 clone 到 streaming 线程；session/attempt generation 由 ArkTS 会话轮询层隔离，native snapshot 通过 sessionId 回传并在 UI 赋值前再次校验。
- streaming 线程只更新整数和枚举，不格式化字符串。
- C ABI 返回值是一次 copy snapshot，不把 Rust 内存指针交给 C++ 长期持有。
- handle 无效、连接结束或锁中毒时返回 `false`。
- 不修改 vendored protobuf 即可完成第一版。

### 5.2 Native 会话快照

本检查点直接复用 `SessionContext.diagnostics`，不再增加第二套 Rust/C++ 统计对象：

```text
SessionContext.diagnostics
  ingressFrames / ingressBytes / keyframes
  lastCodec / lastWidth / lastHeight / lastFrameAtMs
  bounded decodeSamplesUs
  one-second rate baseline -> receivedFps / bitrateKbps
```

实现约束已满足：

- 每个 `SessionContext` 独立持有计数器和有界样本窗口；snapshot 不清零数据。
- FPS/码率使用查询时的单调时钟差分，decode 样本固定上限 128，禁止热路径无界增长。
- decoder 查询带 `expectedSessionId`；ArkTS poll 同时校验 `sessionId`、`connectAttemptId` 和返回快照的 sessionId。
- teardown 从 `g_sessions` 移除 session 后，视频回调闭包仍只持有自己的 `shared_ptr<SessionContext>`，不能写入新会话。
- 旧日志的 `snapshotAndReset()` 与 NAPI snapshot 分离，UI 读取不会清空压力反馈或诊断累计值。

### 5.3 Decoder/Renderer 快照

在 `DecoderNapi` 增加内部 C++ 接口，不直接暴露裸 handle 给 ArkTS：

```text
DecoderStatsSnapshot GetActiveDecoderStats()
```

至少包含：

```text
valid
backend
codec
queueDepth
queueMax
decodedFrames
outputFrames
droppedFrames
waitKeyframeDrops
skippedPresentFrames
submitP50Us / submitP95Us / submitMaxUs
outputP50Us / outputP95Us / outputMaxUs（可准确打点时）
```

当前 renderer 已在硬解 texture 与软解 raw-BGRA 的实际 draw/swap 路径记录 presentation 结果；NAPI 只读取成功 swap 窗口和有界耗时分位数。硬解异步 submit 仍不会被误标为 output 完成。

### 5.4 NAPI 与 ArkTS 类型

`entry/src/main/ets/types/rdpnapi.d.ts` 已提供：

```text
RustDeskDiagnosticsSnapshot
getRustDeskDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot
getLocalResourceStats(includePro?: boolean): LocalResourceStats
```

类型包含：

```text
supported / sessionId / latencyMs / receivedFps / displayFps / bitrateKbps
width / height / codec / decoderBackend / connectionPath
queueDepth / queueMax / droppedFrames / keyframes / cadenceGaps / maxCadenceGapMs
decodeP50Us / decodeP95Us / decodeMaxUs
renderP50Us / renderP95Us / renderMaxUs
presentedFrames / presentationWindowSamples
cpuPercent / memoryBytes / gpuPercent / gpuAvailable / sampledAtMs
```

`ExtensionLoader.ets` 增加安全包装：

- native 抛错时返回 `supported: false` 的完整默认对象。
- 不在 1 秒轮询中每次打 error 日志；只在状态从 valid 变 invalid 时做限频日志。
- 保留现有 `getRdpRenderStats()` 原样。

## 6. 本机资源采样

第一版 Pro 的资源负载定义为本机控制端应用负载：

- `localCpuPercent`：应用进程在两个采样点之间的 CPU 时间占比。
- `localRssBytes`：应用进程常驻内存。
- `systemMemoryPercent`：API/权限允许时显示系统内存使用率。
- `localGpuPercent`：只有本地 API 23 文档确认存在稳定、普通应用可用的接口时才启用。

当前实现使用 native `/proc` 读取本机进程 CPU/RSS；没有引入第三方依赖，也没有使用厂商私有 GPU 接口。

规则：

- 仅在 `includePro=true` 且距离上次采样至少 1000 ms 时采样。
- Pro 关闭后不继续后台采样。
- 第一次 CPU 采样没有前一个基线，返回 unavailable 而不是 0%。
- GPU 不使用厂商私有或设备特定 `/sys` 路径作为发布实现。
- HUD 明确写“本机 CPU/内存/GPU”，不让用户误认为是远端负载。

当前实现已满足上述门控：`getLocalResourceStats(includePro)` 在 Pro 关闭时清除 CPU baseline；首次样本返回 `cpuAvailable=false`，后续采样至少间隔 1000 ms；GPU 固定返回 unavailable（`gpuPercent=-1`），不伪造 0%。

## 7. ArkTS HUD 与生命周期

当前工作树已新增组件（代码实现完成，设备布局仍需验收）：

```text
entry/src/main/ets/components/RustDeskDiagnosticsHud.ets
```

基础模式示例：

```text
延迟 32 ms · 接收 58 FPS · 展示 56 FPS
4.8 Mbps · 1920×1080 · H264 · 硬件解码 · 直连
```

Pro 模式示例：

```text
队列 2/12 · 丢帧 3 · Gap 1 / 224 ms
解码 p95 8.2 ms · 渲染 p95 4.1 ms
本机 CPU 18% · RSS 386 MB · GPU 不可用
远端负载：当前连接不支持
```

当前 HUD 已实现半透明深色背景、等宽数字、固定 270 宽度、`hitTestBehavior(HitTestMode.None)` 和基础/Pro 两种字段集合；以下条目是设备验收标准：

- HUD 放在远程画面 Stack 的安全区内，避免和 `RemoteSessionTopBar`、修饰键面板、文件传输状态重叠。
- 使用半透明深色背景、等宽数字，并适配 Phone/Pad/PC 断点。
- `hitTestBehavior(HitTestMode.None)`，不能吞触摸、鼠标、拖拽或键盘焦点。
- 基础模式最多两行；Pro 可以增加到四行，但不能覆盖主要远程内容。
- 无有效值时显示 `--`；unsupported 显示“不可用/不支持”，不能显示 0。

生命周期实现与剩余验收：

1. 当前已在 RustDesk native connected、预鉴权恢复和基础开关开启时启动 1000 ms 轮询。
2. 页面销毁、显式断开、后台脱附和连接失败清理都会停止 timer 并重置 HUD/资源状态；renderer/decoder 重绑仍需设备回归。
3. 基础开关关闭会清 timer/HUD；Pro 动态切换调用 `getLocalResourceStats(true/false)`，关闭时清除 baseline，不继续资源采样。
4. poll 保存 `sessionId` 与 `connectAttemptId`，查询前后以及返回 snapshot 均做代际校验，旧会话不能覆盖新状态。
5. 当前 HUD 位置为 `{ x: 10, y: 58 }`，需完成 topbar/修饰键/文件拖放避让和 Phone/Pad/PC 断点验收。

## 8. 远端 CPU/内存/GPU 后续方案

当前第一版 UI 只预留 `remoteResourceState`：

```text
unsupported
permission_required
available
stale
```

真正实现远端负载至少需要：

1. 被控端采样 CPU、内存和 GPU。
2. 被控端明确声明能力版本和支持字段。
3. 用户或管理员授权采样与展示。
4. 控制端校验时间戳、版本、过期时间和数据范围。
5. 旧端无该消息时兼容继续远控，Pro HUD只显示“不支持”。

可选路径：

- RustDesk 被控端 Agent 增加兼容消息。
- RustDesk Server Pro 或独立监控 API 提供设备实时指标。
- 项目自有 Agent 通过独立加密通道上报。

如果修改 `rustdesk_vendor` protobuf：

- 必须保持旧 peer 兼容。
- 必须更新协议生成物、来源记录和哈希。
- 必须检查 SBOM、NOTICE、provenance 和 AGPL source offer。
- 必须走双 ABI、clean clone 和真实旧版本矩阵。

远端负载建议单独立项，不与本地诊断第一版共用完成状态。

## 9. 分阶段实施

### 阶段 0：任务与基线

1. 当前公共基线已是 `main`/`origin/main` 的 `1f16f361a`；当前工作区分支为 `codex/rustdesk-performance-diagnostics`，已有 FFI、Bridge、NAPI、decoder、ExtensionLoader、类型和本地设置持久化变动，后续先按本计划核对，不覆盖这些用户变动。
2. 保留 `.appanalyzer/`、截图、设备日志和用户任务文档，不删除、不暂存。
3. 当前分支已作为诊断实现 checkpoint；提交前只收敛本任务文件，不把用户自有文档、截图、日志或 `.appanalyzer/` 放入提交。
4. 本次检查点复核基线：native 110/110、RustDesk FFI host 116/116、ArkTS test compile、生产 HAP、`git diff --check`；Light 合规门待本轮执行。

阶段门：工作树只包含明确的本任务文件，真实 RustDesk 密码连接和首帧基线可复现。

### 阶段 1：设置与纯策略

**当前状态：代码实现完成，设备布局/重启保持待验收。**

1. 已增加两个本地-only 偏好键和读取/保存逻辑，不调用 CloudStore。
2. RustDesk 设置卡片已增加基础和 Pro 两行，并实现基础关闭时 Pro 置灰。
3. 抽出 `RustDeskDiagnosticsPolicy.ets`：开关依赖、HUD 可见性、poll 条件和格式化边界。
4. 增加 ArkTS 纯策略测试。
5. 调整 RustDesk accordion 展开高度，确保新增两行不被裁剪。

阶段门：设置可见、重启保持、基础关闭时 Pro 置灰；CloudStore 中不存在这两个键。

### 阶段 2：Rust 协议统计快照

**当前状态：代码实现完成（工作树未提交，待检查点提交）。**

1. 已新增 `RustDeskStreamStats` 和每连接 `Arc<Mutex<...>>`，并有 `#[repr(C)]` size/alignment/version 测试；C++ 侧有对应 `static_assert`/offset 校验。
2. 已在 video frame、audio、TestDelay、cadence 和连接结束点更新快照，断开状态归零且每个 handle 独立。
3. 已新增 `rustdesk_get_stream_stats()`，空 handle/空输出指针安全返回 false。
4. C++ Bridge 已实现 `getDiagnostics()`、版本拒绝和非 FFI unsupported 降级；callback 计数与 FFI 累计值按来源合并。
5. Rust host suite 已覆盖 ABI 默认值/布局和现有连接策略回归；完整并发/真实 handle teardown 仍以 native/设备矩阵为补充验证。

阶段门：代码层已通过；width/height 的初始 PeerInfo 与逐帧 callback 来源边界已写明，真实重连和首帧仍待设备验收。

### 阶段 3：per-session native 统计

**当前状态：代码实现完成（工作树未提交，待检查点提交）。**

1. `SessionContext` 已增加 per-session ingress/decode counters、有界 decode duration 样本和 1 秒速率差分。
2. 视频回调捕获 session shared state；teardown 从 map 移除后旧回调不会写新 session，decoder 查询校验 expected session。
3. 接收 FPS、展示 FPS 和滚动码率已由 session counters 与 renderer 成功 swap 窗口提供。
4. 已接入 active decoder queue/drop/backend 即时快照，并按 sessionId 校验；decode/presentation 分开命名。
5. 硬解 texture 和软解 raw-BGRA 路径均在真实 draw/swap 后记录 presented frame。
6. 保留现有 pressure feedback，不让 UI 查询清零 pressure 日志窗口。

阶段 3 必须消费阶段 2 的 C ABI 快照，而不是重新从日志字符串解析；Rust 快照中的协议累计值与 native 的滚动 FPS/码率、decoder/render 统计要明确区分来源。

阶段门：代码层已通过；两次真实重连、后台恢复和 decoder 重绑仍待设备验收。

### 阶段 4：NAPI、HUD 与生命周期

**当前状态：代码实现完成，设备 HUD 布局/交互待验收。**

1. 已增加 NAPI `getRustDeskDiagnostics`/`getLocalResourceStats`、`rdpnapi.d.ts` 类型和 `ExtensionLoader` wrapper。
2. 已新增 `RustDeskDiagnosticsHud`、RemoteDesktop state/timer，并接入普通连接、预鉴权恢复、断开和后台路径。
3. 设置 Row 的两个本地开关与 Pro 依赖置灰已接入 RustDesk accordion。
4. ArkTS poll 已增加 stale session/attempt generation 防护；native query 仍按 sessionId 读取，返回后由 UI 再做代际校验。
5. 真机确认 HUD 不影响远程输入、顶部栏和文件拖放，并完成 safe-area/Phone/Pad/PC 布局。

阶段门：代码层已通过；真实断线重连、输入/拖放不受 HUD 影响和布局避让仍待设备验收。

### 阶段 5：Pro 本机资源与分位数

**当前状态：代码实现完成，压力/设备采样待验收。**

1. 固定容量 decode sample、真实 renderer presentation p50/p95/max 和 decoder queue/drop 已接通 Pro HUD。
2. `getLocalResourceStats()` 通过 `/proc` 读取本机 CPU/RSS；GPU 返回 unavailable，不宣称远端负载。
3. 首次 CPU 样本 unavailable、Pro 关闭清 baseline、采样至少 1000 ms 限频和 mutex 保护已实现。
4. API 23/普通应用能力不足以提供稳定公开 GPU 负载，因此保留明确 unavailable 分支。
5. 30 分钟压力测试、开关前后开销和真实资源读数仍是设备验收任务。

阶段门：代码层已通过；设备压力测试确认 Pro 开关前后开销和无 timer/内存泄漏后关闭。

### 阶段 6：远端资源单独立项

仅在远端 Agent/协议、授权、兼容和合规方案冻结后开始，不阻塞本地诊断功能合并。

## 10. 预计修改文件

### ArkTS

- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/services/ExtensionLoader.ets`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- 新增 `entry/src/main/ets/services/RustDeskDiagnosticsPolicy.ets`
- 新增 `entry/src/main/ets/components/RustDeskDiagnosticsHud.ets`
- 新增/注册对应 `entry/src/ohosTest/ets/test/*.test.ets`

### Native C++

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`
- `entry/src/main/cpp/render/hw_decoder.cpp/.h`
- `entry/src/main/cpp/render/software_decoder.cpp/.h`
- `entry/src/main/cpp/render/gl_renderer.cpp/.h`
- `entry/src/main/cpp/render/video_perf_counters.cpp/.h`（只在需要共享固定窗口工具时修改）
- 新增 `entry/src/main/cpp/rustdesk/rustdesk_session_stats.cpp/.h`
- 可选新增 `entry/src/main/cpp/common/system_resource_sampler.cpp/.h`
- `entry/src/main/cpp/CMakeLists.txt`
- 新增 native 定向测试并注册到 `rdp_native_tests`

### Rust FFI

- `rustdesk_ffi/src/lib.rs`
- `rustdesk_ffi/src/connector.rs`
- 必要时新增纯统计模块和测试文件

第一版不应修改 protobuf 或引入新第三方依赖。

当前工作树实际已修改 `rustdesk_ffi/src/lib.rs`、`rustdesk_ffi/src/connector.rs`、`entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`、`entry/src/main/cpp/extensions/extension_loader_napi.cpp`、`entry/src/main/cpp/render/hw_decoder.cpp/.h`、`entry/src/main/cpp/render/gl_renderer.cpp/.h`、`entry/src/main/ets/services/ExtensionLoader.ets`、`entry/src/main/ets/types/rdpnapi.d.ts`、`entry/src/main/ets/pages/HostListPage.ets` 和 `entry/src/main/ets/pages/RemoteDesktop.ets`，并新增 `RustDeskDiagnosticsHud.ets`、`RustDeskDiagnosticsPolicy.ets` 及策略测试，形成阶段 1/2/3/4/5 的代码实现。剩余工作是 Light、受控提交和真机证据；不应重复创建第二个 Rust snapshot 结构。

## 11. 自动化测试

### ArkTS

1. 两个开关默认值和依赖关系。
2. 基础关闭时 HUD 不可见、poll 不启动。
3. Pro 关闭时只显示基础字段。
4. NaN、Infinity、负数、无效 codec、无效尺寸的安全格式化。
5. Kbps/Mbps、us/ms、bytes/MB 格式边界。
6. sessionId/attemptId 变化时拒绝旧 snapshot。
7. Phone/Pad/PC HUD 布局策略。

### Native

1. 滚动窗口 FPS 和码率计算。
2. 1 秒边界、空窗口、时钟回退/重复时间戳。
3. p50/p95/max 固定容量窗口。
4. snapshot 非破坏读取。
5. reset 与 session generation 隔离。
6. 并发 record/snapshot。
7. decoder backend、queue、drop 映射。
8. presentation count 只在实际渲染成功后增加。

### Rust

1. `TestDelay.last_delay` 与 target bitrate 更新。
2. 实际 codec、帧、关键帧、cadence gap 更新。
3. 默认/断开/空 handle snapshot。
4. streaming 更新与 C ABI snapshot 并发安全。
5. `RustDeskStreamStats` 的 `#[repr(C)]` 字段顺序、size/alignment、version/state 和连接路径编码。
6. 原有 89 个 host tests 不回归。

当前工作树状态：Rust ABI layout/default 测试和 ArkTS 诊断策略测试已加入；本轮验证记录为 Rust 116/116、native 110/110、ArkTS 编译和 HAP 构建通过。native 诊断专用 host 测试尚未单独拆出，真实连接/渲染行为仍由设备矩阵补充。

### 工程门禁

1. native 全套测试，基线不得低于 102/102。
2. RustDesk FFI host tests，基线不得低于 89/89。
3. `default@OhosTestCompileArkTS`。
4. 生产 `assembleHap`。
5. arm64-v8a 与 x86_64 受影响 ABI 构建。
6. `git diff --check`。
7. Light 开源合规门。

## 12. 真机验收矩阵

| 场景 | 验收标准 |
| --- | --- |
| 基础关闭 | 无 HUD、无 ArkTS poll、连接和输入行为不变 |
| 基础开启 | 延迟、接收/展示 FPS、码率、尺寸和 codec 持续更新 |
| Pro 开启 | 队列、丢帧、p95、本机 CPU/RSS 可见；GPU unsupported 文案正确 |
| H264/H265 | 实际 codec 和硬件后端显示正确 |
| VP8/VP9/AV1 | 硬件支持时显示硬件；fallback 时显示软件 |
| 自动 codec 切换 | 实际 codec 随关键帧切换，旧 decoder 数据不残留 |
| 直连 | 显示直连路径，延迟和帧统计有效 |
| ID/Relay | 显示中继/配置路径，不误标直连 |
| Server Pro 主机 | 预鉴权交接后 HUD 正常启动，`Pro` 文案不与账户类型混淆 |
| 后台恢复 | HUD timer 停止/恢复正确，统计不跨 session 污染 |
| 断线重连 | 新 session 从新窗口开始；旧 HUD 不闪回 |
| 输入与拖放 | HUD 不吞鼠标、触控、键盘、文件拖放 |
| 30 分钟压力 | 无 timer 泄漏、统计内存不增长、Pro 开关可动态切换 |

建议至少在真实 RustDesk Windows/macOS/Linux 被控端各执行一次；远端负载未实现不影响第一版本地诊断验收。

## 13. 性能与隐私预算

- 基础开关关闭：除已有日志计数外，不增加 UI poll、资源采样或分位数计算。
- 基础开启：每帧只增加固定数量整数/时间戳更新；UI 每 1000 ms 查询一次。
- Pro 开启：固定容量窗口和最多每秒一次资源采样；不得每帧 JSON 序列化或创建 ArkTS 对象。
- HUD 不保存历史曲线，不落库，不上传云端。
- 不记录主机地址、Peer ID、密码、服务器 key、token、剪贴板或远程画面内容。
- 若未来增加诊断导出，必须由用户显式触发并经过脱敏设计。

## 14. 建议提交顺序

在独立实现分支按可回滚检查点提交：

本检查点将这些互相耦合的变动作为一个可回滚提交，提交前执行 Light；后续若需要拆分，应在新的任务中按设置、FFI、native 统计、HUD、设备回归分别整理。

远端资源监控不得混入上述提交，应另开任务和分支。

## 15. 完成定义

只有同时满足以下条件，第一版本地诊断功能才算完成：

1. 基础开关和 Pro 子开关位于 RustDesk 设置中，默认关闭且仅本地持久化。
2. 基础 HUD 显示协议延迟、接收/展示 FPS、码率、实际分辨率、实际 codec、解码后端和路径。
3. Pro HUD 显示真实 queue/drop/keyframe/gap 和可准确解释的解码/渲染分位数。
4. 本机 CPU/RSS 有真实采样；GPU 不支持时明确显示不可用。
5. 不把本机资源冒充远端资源，不把 Server Pro 与专业性能 Pro 混为一谈。
6. 统计按 session/generation 隔离，日志读取不会清零 UI 数据。
7. 普通连接、Pro 预鉴权、后台恢复、断线重连和动态开关都无 timer/handle 泄漏。
8. ArkTS、native、Rust、双 ABI HAP、diff check 和 Light 门禁全部通过。
9. 真机矩阵有截图/日志证据，且 HUD 不影响远程输入和文件拖放。
10. PR required check 通过并合并，回到同步的 `main`，删除已合并任务分支。

当前代码同步状态：Rust 协议快照、C++ Bridge 读取、NAPI 查询、decoder/renderer 统计、ExtensionLoader/type wrapper、本地设置存储、RemoteDesktop 轮询、HUD、Pro 资源采样门控和 ArkTS 策略测试已完成代码实现。Light 与受控检查点提交是本轮收尾；真实 RustDesk 首帧、断线重连、HUD 安全布局、输入/拖放和压力矩阵仍未验收，因此不能把产品运行验收标记为完成。

远端 CPU/内存/GPU 只有在被控端能力协商、授权、兼容和合规门全部完成后，才能从“当前连接不支持”升级为真实数值。
