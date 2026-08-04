# 诊断日志导出 Implementation Plan

> **Status:** design only. This plan was written after a read-only repository
> evaluation on 2026-08-04. No production code is changed by this document.

## Goal

为用户提供一个本地诊断包导出功能：用户选择最近 1 到 30 分钟的时间窗口和一个或多个诊断模块，应用生成脱敏、可检索的 UTF-8 `jsonl` 文件并通过系统文件选择器保存到本地，方便用户手动附加给开发者定位问题。

产品名称建议使用“导出诊断信息”或“导出诊断包”，而不是“导出系统日志”。第一版不读取系统 HiLog、不自动上传、不导出终端内容和原始用户数据。

## Baseline

- 当前日志来源分散在 ArkTS `hilog`、native `OH_LOG_*`、Rust `eprintln!` 和 Rust helper 独立进程，不能依赖一次性读取系统日志来获得完整记录。
- `entry/src/main/cpp/common/log_config.h` 只定义了日志宏和级别变量，现有调用点大量直接调用 `OH_LOG_*`，不能作为统一采集出口。
- `getSessionDiagnostics`、RDP render stats、SSH terminal diagnostics 和 local resource stats 都是导出时快照，不包含时间窗口内的事件历史。
- SSH 诊断接口已经明确不暴露终端字节、命令文本、凭据或渲染输出；该 payload-free 原则应扩展到所有协议。
- `LocalBackupService` 已经具备临时文件、`fsync`、完整性校验和 `DocumentViewPicker.save()` 的可靠保存模式。诊断导出应复用文件 I/O 模式和 `BoundedDocumentIo`，但不应耦合 CloudStore 账号备份语义。
- 当前反馈入口可以打开邮件编辑器，但邮件参数只有收件人、主题和正文，没有附件/分享文件链路。因此第一版保存后由用户手动附加文件。

## Global Constraints

- 用户可选时间只能是 `1 / 3 / 5 / 10 / 15 / 30` 分钟；不提供任意日期范围。
- 导出窗口使用固定截止时间：`endExclusive = exportStart`，事件按 `startInclusive <= eventTime < endExclusive` 筛选。
- 内部只保留约 40 分钟事件，给 30 分钟导出窗口留出时钟变化、导出耗时和事件排序余量；不保留 24 小时历史。
- 事件缓冲区同时受时间、总字节数和每条事件大小限制。建议总上限 16 MiB，单条序列化事件上限 2 KiB，满后 FIFO 淘汰并记录淘汰数量。
- 采集不能阻塞 ArkUI、输入、渲染、解码或网络 fast path；高频帧、鼠标移动、键盘文本和终端输出必须聚合为计数/时间/错误码。
- 模块过滤必须使用稳定的 `moduleId`，不能只依赖 HiLog domain 或 tag；domain 在现有代码中存在复用。
- 采集时即执行字段白名单和脱敏，不能先保存原文再在导出阶段用正则清洗。
- 不导出密码、Token、私钥、认证响应、剪贴板文本、键盘文本、鼠标轨迹、终端输入输出、命令、屏幕帧、音频内容、远端路径原文、URL 查询参数或完整主机地址。
- 不把诊断包放入云同步表，不改变现有备份格式，不把诊断包视为用户配置备份。
- 第一版不自动发送邮件或上传开发者服务；任何后续发送都必须单独取得用户确认。

## Product Contract

### Entry points

- 设置页“反馈”区域增加“导出诊断信息”。
- 连接错误、首帧超时、认证失败、终端异常等用户已经看到错误的入口可以提供同一个导出动作，并传入当前协议作为默认模块。
- 远程会话页面不要求用户打开性能 HUD 才开始采集；采集与 HUD 展示解耦。

### Time selection

- 选择项：`最近 1 分钟`、`最近 3 分钟`、`最近 5 分钟`、`最近 10 分钟`、`最近 15 分钟`、`最近 30 分钟`。
- 从错误入口打开时默认 `最近 15 分钟`；从普通设置进入时默认 `最近 10 分钟`。
- 如果应用启动时间晚于用户选择的起点，界面显示“当前仅可导出应用启动后的记录”，不能伪造完整窗口。
- 导出确认前展示：实际可用起始时间、选中模块、预计事件数、预计文件大小、是否存在淘汰事件。

### Module selection

模块使用多选控件。至少包括：

| moduleId | 内容 | 示例事件 |
| --- | --- | --- |
| `core.lifecycle` | 应用/页面/后台/会话生命周期 | foreground、background、connect-start、disconnect |
| `protocol.rdp` | RDP 连接、认证、证书和协议状态 | certificate-probe-failed、first-frame-timeout |
| `protocol.rustdesk` | RustDesk rendezvous、relay、控制和协议状态 | relay-connect-failed、control-queue-full |
| `protocol.ssh` | SSH 握手、认证、PTY 和连接状态 | kex-failed、auth-failed、pty-open-failed |
| `protocol.sftp` | SFTP 目录、读写、校验和任务状态 | init-failed、resume-rejected、verify-failed |
| `protocol.vnc` | VNC/RFB、TLS、Gateway 和连接状态 | tls-failed、rfb-handshake-failed |
| `render.decode` | 解码、画面接收、渲染和送显 | decode-error、presentation-rejected |
| `input.clipboard` | 输入队列、剪贴板和回调链路计数 | queue-full、callback-error |
| `audio` | 音频初始化、播放、采集和生命周期 | player-init-failed、audio-stalled |
| `system.resource` | CPU、内存和必要的设备模式快照 | resource-sample、memory-pressure |

`core.lifecycle` 和导出元数据始终保留，用户选择控制其余事件模块。错误入口默认勾选当前协议、`core.lifecycle` 和 `render.decode`；SSH/SFTP 连接默认同时勾选 SSH 与 SFTP。

### Export result

- 文件名：`RemoteDesktop-diagnostics-YYYYMMDD-HHmmss.jsonl`。
- 文件第一行是 manifest，后续是事件和快照记录；每行都是独立合法 JSON，开发者可以直接用文本工具、脚本或日志平台检索。
- 导出完成后显示“已保存诊断信息，可在邮件或反馈页面中手动附加”。不显示真实缓存路径作为用户操作前提。
- 用户取消文件选择、文件写入短写、校验失败、超出限制或没有可用事件时，都返回明确的可恢复错误状态。

## Architecture

### 1. Stable event protocol

定义统一的 `DiagnosticEvent`，事件只允许结构化字段，不保留自由文本 message：

```text
kind: "event"
schemaVersion: 1
sequence: monotonically increasing process-local number
wallTimeMs: event wall-clock timestamp
monotonicMs: monotonic timestamp used for window ordering
level: debug | info | warn | error
moduleId: stable module identifier
protocol: rdp | rustdesk | ssh | sftp | vnc | none
sessionRef: opaque per-session reference
sessionGeneration: reconnect generation, or 0 when not applicable
eventCode: stable machine-readable code
fields: allow-listed scalar values only
detailTruncated: boolean
```

`sessionRef` 使用不可逆的随机/哈希引用，不能直接使用 host id、账号 id、native session id 或远端地址。`sessionGeneration` 用于区分同一个连接记录被重连后的不同生命周期，避免把旧会话事件拼到新会话上。

### 2. Bounded recorder

新增进程级 `DiagnosticRecorder`，提供以下逻辑接口：

- `record(event)`：非阻塞、无等待外部 I/O；事件字段在入口校验。
- `snapshotWindow(start, end, modules)`：以固定截止时间复制不可变事件视图。
- `capacityStatus()`：返回 capture start、oldest available、dropped count、current bytes 和 truncation 状态。
- `resetSession(sessionRef, generation)`：仅结束当前会话上下文，不清空其他会话事件。

实现要求：

- 事件记录采用有界环形结构，按序列号保证同一毫秒内的稳定排序。
- 使用每模块配额或公平淘汰，避免一个高频模块挤掉所有连接错误。
- 高频路径只记录状态变化、采样窗口和计数器；不为每一帧、每个鼠标移动或每个输入字符创建事件。
- 采集异常不能影响原有连接、渲染、输入或 SFTP 行为；记录失败只增加内部丢弃计数。
- 第一版为进程内存缓冲。应用被系统杀死后，未导出的记录会丢失；持久化 crash ring 作为后续独立任务，不扩大本次范围。

### 3. Producers and adapters

- ArkTS：新增统一诊断 facade，先覆盖连接状态、页面生命周期、错误边界和已有诊断轮询，不要求一次迁移全部 `hilog` 调用。
- native：在 extension loader、RDP、VNC、SSH/SFTP、渲染/解码、音频和输入的关键错误/状态边界调用 recorder；现有 `OH_LOG_*` 可继续保留用于开发调试，但不得作为导出数据源。
- RustDesk FFI：增加安全的诊断事件桥接，使用事件码和数值字段，不把 `eprintln!` 原文转发到导出包。
- Rust helper：通过现有 IPC 增加受控的诊断事件消息；禁止把 helper 当前的键盘、鼠标和 wheel 原始调试输出纳入导出包。
- 所有 producer 必须从 session registry 或调用上下文取得 `protocol/sessionRef/generation`，不能由导出层猜测归属。

### 4. Snapshot providers

导出时并行收集当前快照，快照和历史事件分开标记：

- RDP：`RdpRenderStats`、连接/证书状态和首帧状态。
- RustDesk：`RustDeskDiagnosticsSnapshot`、连接路径、帧/解码/控制统计。
- SSH：`SshTerminalDiagnosticsSnapshot`，保持 payload-free，只导出队列、写入、读取、回调和时延计数。
- SFTP：当前任务状态、阶段、错误码、字节数和校验结果，不导出路径原文。
- VNC：TLS/RFB/Gateway 状态和统一渲染快照；现有 HUD 轮询只代表当前值，不能替代历史事件。
- 渲染/解码：错误数、拒绝数、队列深度、延迟分位数和当前几何信息。
- 系统资源：导出时 CPU/RSS、设备模式、应用版本、构建标识；不导出账号或用户配置。

如果某个 provider 不可用，manifest 标记 `supported=false` 和原因码，不能用全 0 快照伪装成正常数据。

### 5. Export service

新增独立的 `DiagnosticExportService`，职责仅包括选择、筛选、序列化和安全保存：

1. 在主线程短暂读取当前过滤条件和 `exportStart`。
2. 从 recorder 得到固定窗口的不可变副本。
3. 收集当前 snapshot，并按 `manifest/event/snapshot/summary` 写入 JSONL。
4. 先写 cache 目录下的私有临时文件，完成 `writeFully`、`fsync`、尺寸/哈希校验后再调用 `DocumentViewPicker.save()`。
5. 写入用户选定 URI 后重新读取并验证长度、哈希和 JSONL manifest。
6. 清理临时文件；任何失败都不留下可误认为成功的半成品。

诊断导出不能直接调用 `LocalBackupService.saveBackup()`，因为该服务会创建账号/云表快照。应抽取或复用其通用的 bounded file I/O 和校验模式。

### 6. Share boundary

第一版只负责本地保存。邮件/分享流程保持用户可控：

- 用户从系统文件选择器保存后，手动在反馈邮件中附加文件。
- 不把诊断文件复制到云同步、剪贴板或应用数据库。
- 第二阶段若增加系统分享，使用只读 URI grant、固定 MIME、发送前确认和撤销授权；不得将本地文件路径直接传给外部 Ability。
- 若以后增加自动提交接口，必须单独设计服务端认证、上传大小、失败重试、隐私同意、删除策略和网络不可用状态。

## Data Schema

### Manifest record

manifest 至少包含：

- `schemaVersion`、`exportId`、`createdAtMs`、`appVersion`、`buildId`。
- `requestedWindowMs`、`rangeStartMs`、`rangeEndMs`、`captureStartedAtMs`、`oldestAvailableAtMs`。
- `selectedModules`、`availableModules`、`droppedEventCount`、`exportTruncated`。
- `deviceMode`、必要的系统能力状态和 `redactionPolicyVersion`。
- 不包含账号标识、host id、host address、邮箱、Token 或用户配置内容。

### Event fields

允许字段分为：

- 数值：错误码、返回码、计数、字节数、时延、尺寸、队列深度、重试次数。
- 枚举：连接阶段、认证方式类别、连接路径、解码器、渲染后端、失败原因类别。
- 引用：opaque `sessionRef`、路径/主机的不可逆短哈希，仅在定位同一对象确有必要时使用。

禁止字段包括 `rawMessage`、`command`、`terminalText`、`clipboardText`、`inputText`、`url`、`headers`、`path`、`host`、`username`、`password`、`token`、`privateKey` 和任意二进制 payload。

### Representative event codes

- Lifecycle：`app.foreground`、`app.background`、`session.connect_started`、`session.state_changed`、`session.generation_replaced`。
- RDP：`rdp.certificate_probe_failed`、`rdp.auth_failed`、`rdp.first_frame_timeout`、`rdp.transport_closed`。
- RustDesk：`rustdesk.rendezvous_failed`、`rustdesk.relay_failed`、`rustdesk.decode_failed`、`rustdesk.control_backpressure`。
- SSH/SFTP：`ssh.resolve_failed`、`ssh.kex_failed`、`ssh.auth_failed`、`ssh.hostkey_mismatch`、`ssh.pty_failed`、`sftp.verify_failed`。
- VNC：`vnc.tls_failed`、`vnc.rfb_handshake_failed`、`vnc.gateway_failed`、`vnc.first_frame_timeout`。
- Render/input/audio：`render.decode_error`、`render.presentation_rejected`、`input.queue_full`、`input.callback_failed`、`audio.init_failed`。

每个事件码必须有字段白名单、级别、模块归属、是否允许无 session、测试样例和脱敏规则；不得让业务调用方随意传递对象后再由 recorder 猜测内容。

## Implementation Tasks

### Task 1: Event protocol, module catalog and redaction policy

**Files:**

- Create: `entry/src/main/ets/services/DiagnosticEventPolicy.ets`
- Create: `entry/src/main/ets/services/DiagnosticModulePolicy.ets`
- Create: `entry/src/test/DiagnosticEventPolicy.test.ets`
- Create: `entry/src/test/DiagnosticModulePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**

- `diagnosticModules()` and `defaultDiagnosticModules(protocol, source)`.
- `diagnosticWindowOptions()` returning only the six approved durations.
- `validateDiagnosticEvent()` and `sanitizeDiagnosticFields()` using explicit field schemas.
- `diagnosticEventCodeCatalog()` returning module, level, allowed fields and redaction mode.

- [ ] Add tests for module selection, default selections, invalid module rejection and stable event-code metadata.
- [ ] Add tests proving raw host, URL, path, command, clipboard, input and credential fields are rejected rather than partially redacted.
- [ ] Add tests for 1/3/5/10/15/30 minute options and invalid durations.
- [ ] Add tests for session generation separation and stable ordering at equal timestamps.

### Task 2: Bounded recorder and session correlation

**Files:**

- Create: `entry/src/main/cpp/diagnostics/diagnostic_event.h`
- Create: `entry/src/main/cpp/diagnostics/diagnostic_recorder.h`
- Create: `entry/src/main/cpp/diagnostics/diagnostic_recorder.cpp`
- Create: `entry/src/main/cpp/test/diagnostic_recorder_test.cpp`
- Create or modify: `entry/src/main/ets/services/DiagnosticRecorder.ets`
- Modify: `entry/src/main/cpp/extensions/session_registry.h`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`

**Interfaces:**

- Native `recordDiagnosticEvent`, `snapshotDiagnosticWindow`, `diagnosticCapacityStatus`.
- ArkTS facade with no raw string/object escape hatch.
- Session context binding for protocol, opaque session reference and generation.

- [ ] Implement 40-minute time retention, 16 MiB byte cap, 2 KiB event cap and per-module fairness.
- [ ] Implement fixed-window snapshot and deterministic ordering.
- [ ] Test concurrent producers, full buffer, event truncation, stale generation and recorder failure isolation.
- [ ] Verify no allocation or blocking file I/O occurs on the input/render/network hot paths.

### Task 3: Producer integration by protocol and subsystem

**Files:**

- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/vnc/vnc_adapter.cpp`
- Modify: `entry/src/main/cpp/vnc/vnc_certificate_probe.cpp`
- Modify: `entry/src/main/cpp/ssh/ssh_adapter.cpp`
- Modify: `entry/src/main/cpp/render/*.cpp`
- Modify: `entry/src/main/cpp/audio/*.cpp`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionState.ets`
- Modify: selected connection/lifecycle services and pages

- [ ] Start with high-value state transitions and failures; do not mechanically migrate all existing logs.
- [ ] Replace raw error payload export candidates with event codes and scalar fields.
- [ ] Preserve existing HiLog calls where useful for developer builds, but make them independent from the export path.
- [ ] Add event coverage for RDP, RustDesk, SSH/SFTP, VNC, render/decode, input/clipboard, audio and lifecycle.
- [ ] Add tests that prove terminal bytes, command text and clipboard/input payload never enter the event record.

### Task 4: RustDesk FFI and helper diagnostics bridge

**Files:**

- Create: `rustdesk_ffi/src/diagnostics.rs`
- Modify: `rustdesk_ffi/src/lib.rs`
- Modify: `rustdesk_ffi/src/connector.rs`
- Modify: `rustdesk_ffi/src/protocol/*.rs`
- Modify: `rustdesk_helper/src/ipc.rs`
- Modify: `rustdesk_helper/src/lib.rs`
- Modify: native RustDesk bridge and IPC declarations as required

- [ ] Expose only catalogued event codes and scalar fields from Rust.
- [ ] Convert useful Rust control/relay/decoder failures into structured events without forwarding `eprintln!` text.
- [ ] Keep helper input diagnostics aggregate-only; never export raw scancodes, coordinates, terminal data or IPC payloads.
- [ ] Add Rust tests for endpoint/path hashing, event field allow-lists and helper message validation.

### Task 5: Snapshot aggregation and export serialization

**Files:**

- Create: `entry/src/main/ets/services/DiagnosticSnapshotPolicy.ets`
- Create: `entry/src/main/ets/services/DiagnosticExportPolicy.ets`
- Create: `entry/src/main/ets/services/DiagnosticExportService.ets`
- Create: `entry/src/test/DiagnosticExportPolicy.test.ets`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: native NAPI declarations/implementations for missing snapshot providers

- [ ] Aggregate existing RDP, RustDesk, SSH and local-resource snapshots without changing their current UI behavior.
- [ ] Define VNC/SFTP snapshot availability and explicit unsupported states.
- [ ] Serialize manifest, events, snapshots and summary as valid UTF-8 JSONL.
- [ ] Enforce export byte limit, truncation marker, hash verification and no-event behavior.
- [ ] Test window boundary inclusion/exclusion, missing provider, invalid event, large export and deterministic manifest fields.

### Task 6: Settings/error UI and local file save

**Files:**

- Modify: `entry/src/main/ets/components/FeedbackSettingsSheet.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: relevant connection error sheets/pages
- Create: `entry/src/test/DiagnosticExportUiPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

- [ ] Add the six time options, multi-module selection and current-protocol defaults.
- [ ] Show actual available window, event count, estimated size and dropped-event warning before save.
- [ ] Reuse the existing cache staging, `BoundedDocumentIo`, `fsync`, `DocumentViewPicker.save()` and post-write verification pattern.
- [ ] Keep export progress and picker cancellation recoverable; prevent duplicate export requests while one is active.
- [ ] Display a clear redaction notice and state that the file is intended for manual attachment.
- [ ] Verify small-screen Sheet behavior and Pad/PC layout without nesting a second settings card/sheet unnecessarily.

### Task 7: Share handoff, optional second phase

**Files:**

- Separate follow-up plan after Task 6 device acceptance.

- [ ] Verify the HarmonyOS API 23 file-share/URI-grant contract on a real device.
- [ ] Add read-only MIME/URI handoff only after the local-save path is stable.
- [ ] Keep email attachment and automatic upload out of the first release unless product explicitly approves the privacy and service contract.

### Task 8: Validation and delivery

- [ ] Run focused ArkTS/policy tests and native/Rust diagnostic tests.
- [ ] Run `git diff --check`.
- [ ] Run the mandatory `default@OhosTestCompileArkTS` gate.
- [ ] Run the mandatory `assembleHap` gate.
- [ ] Test file picker save, short write, cancellation, re-opened file validation and manual email attachment on a real device.
- [ ] Test each protocol's representative failure path and verify selected-module filtering.
- [ ] Record unavailable HDC/device or endpoint evidence as blockers; do not replace it with host-only results.
- [ ] Complete independent review of the declared diagnostic scope before merge.

## Test Matrix

### Pure policy and serialization

- Window options and exact boundary semantics.
- Module selection and default selection from each entry point.
- FIFO/time/byte eviction and dropped-event accounting.
- Per-module fairness under a noisy producer.
- Schema version, malformed JSONL, unknown event code and unsupported snapshot.
- Redaction rejection for credentials, URLs, paths, commands, terminal text, clipboard and input.
- Stable session reference and reconnect generation separation.

### Concurrency and lifecycle

- Simultaneous ArkTS/native/Rust producers.
- Export while events are being recorded.
- Session disconnect during snapshot collection.
- Reconnect with the same native session id but a new generation.
- App foreground/background and page reconstruction.
- Recorder failure or full buffer must not break connection or rendering.

### Protocol scenarios

- RDP certificate/auth/transport/first-frame/render failure.
- RustDesk rendezvous/relay/decode/control backpressure failure.
- SSH DNS/KEX/auth/host-key/PTY failure and SFTP verification failure.
- VNC TLS/RFB/Gateway/first-frame failure.
- Render rejection, input queue full, clipboard callback failure and audio startup failure.

### File and privacy acceptance

- User cancels picker; no success toast and no leftover temp file.
- Short write, read-back mismatch, invalid manifest and oversized export are rejected.
- Saved file is UTF-8 JSONL, readable by a standard parser and contains no prohibited field.
- User can find the file through the chosen local provider and manually attach it to feedback.
- The package contains only selected modules plus mandatory manifest/lifecycle metadata.

## Acceptance Criteria

- 用户只能选择 1–30 分钟的六个预设值，30 分钟窗口在应用正常运行期间可稳定导出。
- 选择的模块决定历史事件集合，过滤不依赖 HiLog domain/tag，且同时会话不会互相污染。
- 导出包同时包含历史事件、明确的窗口元数据和当前快照；历史事件与当前快照有不同的 record kind。
- 任何终端输出、命令、剪贴板、输入文本、密码、Token、私钥、完整主机、路径和 URL 参数都不会进入导出包。
- 导出过程不阻塞连接/渲染/输入，文件写入经过完整写入、`fsync`、回读和校验。
- 应用重启后历史事件丢失的限制在产品文案和 manifest 中明确；持久化 crash ring 不作为本计划隐式承诺。
- 第一版不自动上传、不自动发送邮件；用户可以保存文件并手动附加给开发者。
- 所有代码改动完成后通过项目规定的两项 Hvigor 门禁，并完成独立复核和真实设备保存验证。

## Risks and Follow-ups

- **系统 HiLog 读取不可控：** 保持结构化 recorder 为唯一导出来源；不要把 shell/hilog 命令执行加入应用功能。
- **已有日志迁移量大：** 先覆盖高价值失败边界和快照，不追求一次迁移全部现有日志调用。
- **应用被杀导致记录丢失：** 若实际支持需求包含“崩溃后下次启动导出”，另立持久化 30–40 分钟 crash ring 计划，采用批量写盘和严格权限隔离。
- **脱敏遗漏：** 事件字段白名单、创建时拒绝、导出前 schema 校验和单元测试四层共同防护；不能只依赖当前 `SafeLogger` 正则。
- **邮件/分享 API 差异：** 在本地保存稳定并有设备证据后再立项，不把附件能力混入第一阶段验收。
