# RustDesk 最高画质与多屏能力闭环升级计划

状态：代码实施与自动化门禁完成；真实设备/远端 peer 发布验收待执行

日期：2026-08-29

评估基线：`RemoteDeskHarmonyOS@1051588dd`；RustDesk 官方对照 `master@03a7fc599`

## 1. 目标与结论

本计划关闭两项已确认的功能缺口，并分两个可独立发布的里程碑交付：

| 能力 | 当前状态 | 目标状态 | 发布门槛 |
| --- | --- | --- | --- |
| 最高画质 `Best` | UI 可选，但被固定 `Balanced` profile 钳制为均衡画质 | 首次连接、重连和会话内切换均能把用户选择准确发送到 RustDesk 核心 | 远端真实会话和诊断证据确认 effective/sent quality 为 `Best` |
| 单画布多屏切换 | 代码链路与单元测试已具备，真机矩阵未完成 | 作为默认可发布能力，可靠选择任一在线远端屏幕 | 双屏/三屏、旋转/DPI、直连/中继和生命周期矩阵全部通过 |
| 多画布同时显示 | 未实现，当前固定单画布、单解码器 | PC 端可按资源预算同时显示并控制多个远端屏幕 | 独立资源模型、压力测试和降级策略通过后单独发布 |

第一里程碑交付“Best 画质 + 单画布切屏 GA”；第二里程碑交付“多画布并行显示”。第二里程碑不阻塞第一里程碑发布。

## 2. 已确认的根因

1. `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp` 将 `profile` 固定为 `Balanced`；`rustdesk_ffi/src/lib.rs` 再以 `min(profile, image_quality)` 解析参数，因此 `Best(2)` 实际变为 `Balanced(1)`。
2. 画质设置目前以持久化和重连生效为主，缺少与官方 `sessionSetImageQuality` 等价、可观测的会话内更新闭环。
3. 一期多屏切换已经贯通 Rust、FFI、C++、NAPI、ArkTS 和输入几何门控，但真实双屏/三屏验收尚未完成。
4. 当前渲染能力显式为 `multiMonitor: false`，只维护一个 active canvas/decoder；多画布与 IPC parity 尚未实现。详细历史见 `docs/rustdesk-multimonitor-upgrade-plan.md`。

## 3. 范围与非目标

范围：

- 对齐官方 `Low / Balanced / Best / Custom` 的参数语义；本轮至少保证现有三档准确生效。
- 支持首次连接、重连及会话内画质切换，并暴露 raw/effective/sent 三层诊断值。
- 完成单画布显示器选择的真机验收、异常恢复和默认能力发布。
- 在第二里程碑引入按显示器隔离的解码、Surface、纹理、渲染和输入路由。

非目标：

- 不全量同步 RustDesk master，不修改官方 protobuf 字段编号。
- 不把网络自适应降质误定义为故障；但自适应不得永久覆盖用户设置的质量上限，且必须可诊断。
- IPC helper 未接入真实 RustDesk core 前继续准确报告“不支持”，不得以 skeleton 冒充 parity。
- Phone/Pad 首期不开放多画布；资源和交互模型验收后另行评估。

## 4. 实施阶段

### M0：冻结契约与回归基线

- 为画质优先级建立单一规则：用户档位决定质量上限，网络/解码保护只允许临时降级并可恢复。
- 固化 `UI value -> FFI raw -> effective -> protocol enum` 参数表和测试。
- 保留现有显示器 generation、ACK、目标屏关键帧和输入释放契约，补齐失败/超时状态表。

### M1：修复并闭环最高画质

- 消除硬编码 `Balanced` 对 `Best` 的静默钳制；profile 与用户画质使用显式、可测试的优先级。
- 接通会话内画质更新；发送失败时保留上次已确认状态并给出非误导提示。
- 诊断信息记录用户选择、effective quality、实际发送值、FPS/profile、降级原因和恢复结果。
- 覆盖冷启动、重连、会话内三档往返、网络降级恢复及旧端兼容。

### M2：单画布多屏切换 GA

- 保持 `switch_display -> capture_displays -> refresh_video_display` 原子事务和 latest-generation-wins。
- 仅在目标屏 ACK 与关键帧同时满足后提交画面几何和输入映射；超时回退最后确认屏幕。
- 完成屏幕离线、热插拔、主屏变化、快速连续切换、PIP、前后台、Surface 重建和重连恢复。
- 真机矩阵通过后才开启默认能力；不支持的 peer/传输模式继续显示准确的 capability 状态。

### M3：PC 多画布并行显示

- 引入按 `display` 隔离的 session：队列、decoder、NativeImage、NativeWindow、纹理、renderer、surface generation 和统计信息互不共享。
- 支持单屏、全部屏幕和自选屏幕集合；输入事件必须携带目标 display 并使用该屏几何映射。
- 定义最大并发屏数、像素/码率/显存预算和动态降级顺序；超预算时可回退单画布，不崩溃、不串屏。
- 完成关闭子画布、屏幕离线、解码器失败和应用退后台时的严格资源释放。

## 5. 验收矩阵

| 维度 | 必测组合 |
| --- | --- |
| 画质 | Low/Balanced/Best；首次连接/会话内切换/重连；直连/中继；弱网降级与恢复 |
| 远端显示器 | 1/2/3 屏；主屏与非主屏；横竖屏、旋转、不同分辨率/DPI、负坐标布局、热插拔 |
| 会话生命周期 | 快速连续切屏、PIP、前后台、窗口 resize、Surface 重建、网络断开重连 |
| 输入 | 绝对/相对鼠标、触摸、滚轮、键盘；切屏前释放；目标屏坐标和边界正确 |
| 多画布性能 | 每屏 FPS/延迟/丢帧；CPU/GPU/内存/温度；2/3 屏持续 30 分钟；异常降级与恢复 |
| 兼容性 | 新旧 RustDesk peer；不支持 CaptureDisplays 的旧端 fallback；Windows/Linux/macOS 被控端 |

## 6. 验证与发布门禁

- Rust：画质解析、会话内设置、显示目录/切换、旧端 fallback 和并发顺序定向测试。
- C++：ABI、display switch gate、decoder/renderer 隔离、Surface 生命周期和资源释放测试。
- ArkTS：设置持久化、能力门控、切换状态、错误提示、PIP/前后台和输入策略测试。
- 构建：ARM64 与 x86_64 native 链路、`default@OhosTestCompileArkTS`、`assembleHap`、`git diff --check`、Light 合规门。
- 复核：独立 reviewer 无未关闭 P0/P1/P2；真机矩阵必须附设备、peer 版本、传输路径和诊断证据。
- 发布：M1/M2 可共同发布；M3 先由显式实验开关保护，资源与稳定性门通过后再默认开启。

## 7. 完成定义

- `Best` 不再被 Balanced profile 静默钳制，且 UI、诊断与协议发送值一致。
- 单画布切屏在完整真机矩阵中无串屏、黑屏卡死、错误输入映射或不可恢复超时。
- 多画布每屏资源和输入路由独立，压力场景能够受控降级并完整释放。
- 代码、测试、诊断、用户文案、能力标志和维护文档同步完成；未通过的阶段不得对外宣称完全可用。

## 8. 2026-08-29 执行结果

### 8.1 已完成实现

- M0/M1：显式 `Low / Balanced / Best` 优先于 profile 默认值，`Best` 不再被固定
  `Balanced` 静默钳制；首次连接和会话内 `OptionMessage.image_quality` 使用同一官方枚举映射。
- 画质状态新增 versioned C ABI，贯通 Rust、C++、NAPI、ArkTS 和诊断 HUD，区分
  `raw / effective / sent`、请求/应用 generation 与 `pending / applied / failed`。快速连续切换时，
  每次成功写入都会更新实际 `sent` 值，最新请求失败不会伪报远端已应用。
- RustDesk 协议未提供画质生效 ACK，因此 HUD 使用“已发送”而不是“远端已应用”；远端实际观感仍由
  真机会话验收确认。
- M2：显示能力补齐 `confirmedDisplay`；切换继续采用 latest-generation-wins，只有 ACK 与目标屏
  关键帧同时满足才提交几何并解除输入。超时会向最后确认屏发起新的安全回退事务，回退 ACK/关键帧
  到达前保持输入阻断。
- M3：PC 端增加默认关闭的“实验性双画布预览”，上限 2 屏、总像素预算为 `2 × 3840 × 2160`。
  辅助画布拥有独立 NativeWindow、EGL renderer、NativeImage、硬件 decoder、队列和统计；任一资源或
  预算失败都销毁辅助链路并回退单画布。
- RustDesk 当前 MouseEvent 协议不携带 display 标识，因此辅助画布严格只读；点击辅助画布后复用 M2
  的 ACK/关键帧事务提升为可控主画布。未在非活动屏直接发送输入，避免错误坐标空间和串屏。
- teardown、后台切换、Surface 销毁和会话断开均先摘除 pipeline，再按 exact owner/generation 销毁
  decoder 与 renderer；frame submit、telemetry 和 teardown 由 pipeline 生命周期锁串行化。
- 主/辅 renderer 共用进程级 EGLDisplay 引用所有权，但各自持有独立 EGLContext/EGLSurface；关闭辅助
  画布不会再 `eglTerminate` 主画布的 live display。辅助 renderer 不再受主 XComponent detach 标志或
  process-global renderer generation 牵连。
- 辅助解码提交对短暂 callback 锁窗采用 1 ms 有界重试；仍发生的外部丢帧或 decoder 关键帧请求会按
  display 每秒最多一次触发刷新。首帧和切屏目标帧只进入交互画布，不会重复路由到预览链路。

### 8.2 自动化验证收据

| 门禁 | 结果 |
| --- | --- |
| Rust 画质解析、live generation、官方 `Best` 枚举 3 个定向测试 | PASS，3/3 |
| OHOS RustDesk FFI release | PASS，`arm64-v8a` + `x86_64`；两 ABI 均导出 `rustdesk_set_image_quality` / `rustdesk_get_quality_state` |
| native host suite | RustDesk 新增/受影响用例 PASS；全套 803/819，16 项失败均为既有 VNC TLS `fixture.start()` 基线问题 |
| `default@OhosTestCompileArkTS` | PASS，新增策略测试已注册并编译 |
| `assembleHap` | PASS，native Ninja、打包与签名完成；signed HAP SHA-256 `58d2e44373ed3d16784612b8823ea19f52874ef85d9e1dcdd84d75b2751bd3c5` |
| `git diff --check` | PASS |
| Light 开源合规 | PASS |

### 8.3 尚未关闭的发布门禁

- 真实 RustDesk 直连/中继会话确认 `Best` 的 effective/sent/远端观感，并完成三档往返、重连、弱网降级恢复。
- 双屏/三屏、旋转/DPI/负坐标、热插拔、PIP、前后台、Surface 重建、断线重连和输入矩阵。
- PC 实验性双画布在 Windows/Linux/macOS peer 上的硬件解码兼容、2 屏 30 分钟 CPU/GPU/内存/温度
  压力与反复开关/提升/离线资源释放验证。
- 辅助链路当前仅支持硬件解码；硬件 decoder 不可用时按设计回退单画布，不宣称具备软件预览 fallback。

结论：实现层和自动化工程门禁已闭环；在上述真机矩阵完成前，M1/M2 不标记“发布验收完成”，M3
保持 PC-only、默认关闭、实验性只读预览，不对外宣称完整多屏独立控制。
