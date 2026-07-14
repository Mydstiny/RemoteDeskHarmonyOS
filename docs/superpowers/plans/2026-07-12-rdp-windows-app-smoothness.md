# RDP 长连接稳定性与 Windows App 流畅度实施计划

更新日期：2026-07-14
代码基线：`main@8b44687e8`
计划分支：`codex/rdp-performance-replan`

## 1. 目标与边界

本计划同时解决两个不可拆开的目标：

1. RDP 长时间连接后显式退出不能卡住 ArkTS UI 线程，不能因后台线程、FreeRDP 回调或渲染资源销毁而导致应用无响应或崩溃。
2. 在相同 Windows 主机、HarmonyOS 设备、网络、分辨率和刷新率下，使前台 RDP 的滚动、窗口动画、视频与输入回显接近 Windows App。

实施顺序固定为“退出稳定性 -> 可观测性 -> GDI 数据所有权与脏区 -> 调度与上传 -> RDPGFX/H.264”。在退出稳定性未通过长连接压力门之前，不允许启用新的图形通道或硬件输出。

不在本计划中修改认证、证书确认顺序、剪贴板、音频、共享盘、输入语义、后台保活策略或其他协议行为；这些能力只作为回归矩阵验证。

## 2. 当前代码事实

### 2.1 长连接退出链路

当前显式退出链路为：

`RemoteDesktop.disconnectAndCleanup()` -> `loader.disconnect()` -> `NapiDisconnect()` -> `ProtocolAdapter::disconnect()` -> `FreeRdpAdapter::disconnect()`。

以下事实已由当前代码确认：

- ArkTS 在 UI 线程同步调用 `loader.disconnect()`，返回后才继续销毁 decoder、renderer 和 audio。
- `NapiDisconnect()` 同步执行 adapter 的完整断连，再删除 `g_sessions`；因此所有 native `join`、FreeRDP disconnect 和回调耗时都会直接阻塞 UI。
- `disconnectActiveInstance()` 持有 `Impl::instanceMutex` 调用 `freerdp_abort_connect_context()` 和 `freerdp_disconnect()`。
- FreeRDP 可在 `freerdp_disconnect()` 内同步进入 `PostDisconnect`；项目的 `cbPostDisconnect()` 会停止并 `join` 输入线程、延迟帧线程和帧泵。
- 输入线程在 `sendQueuedInputEvent()` 中先持有 `inputQueueMutex`，再申请 `instanceMutex`。
- 因此存在确定的锁反转窗口：UI/NAPI 线程持有 `instanceMutex` 等待输入线程退出，输入线程等待 `instanceMutex`。长连接后输入队列、共享盘线程和事件线程更活跃，触发概率随运行时间增加。
- `cleanupInstance()` 同样持有 `instanceMutex` 后执行多个 worker stop/join 和 `gdi_free()`，扩大了回调、join 与锁交叠面。
- `stopEventLoop()`、`joinDriveThread()`、`joinConnectThread()` 都是无超时同步等待；当前没有统一 session ID、阶段耗时或线程退出边界日志，现场只能看到“开始断开”而无法定位卡在哪个 join。
- `stopRequested`、`connecting`、部分 thread-started 标志跨线程访问但不是原子变量；需通过线程所有权或原子状态消除数据竞争，而不是只增加超时。

### 2.2 当前画面链路

当前前台链路为：

`FreeRDP software GDI BGRA primary buffer` -> `cbEndPaint()` -> `RdpFramePump` 全帧复制 -> `GLRenderer::RenderRawBGRAInternal()` -> `glTexSubImage2D()` -> draw -> `eglSwapBuffers()`。

已确认的性能与正确性约束：

- `FreeRDP_SoftwareGdi` 固定启用；RDPGFX consumer 代码存在，但 `rdpGfxResetPathSafe()` 固定返回 `false`，发布路径实际为 GDI fallback。
- `cbEndPaint()` 能读取 FreeRDP invalid rect，但 `kEnableDirtyRectUploads=false`，因此所有有效提交仍按完整 primary buffer 处理。
- `RdpFramePump::submitLatest()` 使用 `vector::assign` 复制整个 frame；1920x1080 BGRA 每次约 7.91 MiB，4K 每次约 31.64 MiB。
- latest-frame 单槽可以替换旧帧，但替换 dirty frame 时会升级为 full frame；当前无法在保留最终画面正确性的同时节省复制量。
- `trailingFrameData` 保存 FreeRDP GDI 原始指针并跨 `EndPaint` 回调延迟使用，所有权不成立；断连或下一次更新可能使该指针内容变化或失效。
- 前三帧和帧泵提交失败时仍在 FreeRDP 事件线程同步进入 GL；协议接收可能被 texture upload 或 swap 反压。
- 当前自适应间隔在帧泵成功时主要测到“全帧 CPU copy/入队”耗时，不是 worker 中真实的 upload/draw/swap 耗时，不能据此可靠地从 60fps 降到 30/20fps。
- GL 已具备局部上传接口，但帧泵传入的是完整 buffer 起始地址；若直接打开 dirty 开关，destination 使用 dirty offset，而 source 仍从左上角开始，存在像素错位风险。
- renderer 内部能拒绝 detached surface，但帧泵提交前没有 readiness gate；后台脱附期间仍可能发生无意义的全帧复制。
- GL 内部已有 upload/draw/swap 时间日志，但 NAPI 返回值只有成功/失败，调度层拿不到结构化耗时。

## 3. 验收指标

### 3.1 退出与稳定性

- ArkTS 发起显式退出后，P95 在 50 ms 内恢复事件循环并允许主界面交互；任何单次 UI 同步段不得超过 100 ms。
- native teardown P95 小于 1 s，最长 3 s 内结束并产生明确阶段结果；超时不得阻塞 UI，必须记录卡住阶段。
- 30 分钟和 2 小时连接后退出、持续输入中退出、后台恢复后退出均不得 ANR、崩溃或返回桌面。
- 连续 20 次 connect/disconnect 后无存活的 RDP event/input/frame/trailing/drive/connect worker，无残留 session、renderer、audio 或 FreeRDP context。
- 退出日志必须包含同一 session generation 的 `request`、`input-stop`、`presentation-stop`、`event-stop`、`drive-join`、`connect-join`、`freerdp-disconnect`、`context-free`、`complete`，并带单调时钟耗时。

### 3.2 画面与输入

固定 1920x1080/32-bit/60Hz，分别录制 idle、文本输入、资源管理器滚动、浏览器滚动、窗口拖动/缩放、30fps/60fps 视频各 30 秒。

- 有效上屏率达到同条件 Windows App 的 90% 以上，且不超过服务端更新率或设备刷新率。
- 可测场景的 P95 输入到可见回显不比 Windows App 高 10 ms 以上。
- browser scroll 中 GDI submitted CPU bytes 相对当前 full-frame baseline 至少下降 70%。
- P95 protocol callback 时间小于 2 ms；事件线程不得执行 GL draw/swap。
- 无黑帧、脏块错位、旧纹理残留、动画最终帧丢失、resize 坐标漂移或 GL error。
- 内存进入稳态后 30 分钟增长不超过 5%，2 小时不得持续线性增长。

## 4. 执行与验证规则

- 每个阶段先增加可重复失败测试或可观测证据，再修改行为。
- 不持有 `instanceMutex`、renderer lifecycle mutex 或队列 mutex 调用可能触发回调的 FreeRDP API，也不在持锁状态执行 `join`。
- 协议线程只做边界校验、必要的 owned copy、damage 合并和唤醒；不调用 GL/EGL。
- 所有跨回调数据必须由 adapter/frame pump 自己持有；禁止保存 GDI primary buffer 裸指针供延迟线程使用。
- GDI 是始终可选的安全回退。RDPGFX/H.264 只能在 resize/reset/channel lifecycle 和设备矩阵全部通过后提升为默认。
- 每个 native 行为提交至少执行 focused native tests、受影响 ABI、`assembleHap`、Light 合规门；涉及 ArkTS API 时额外执行 `default@OhosTestCompileArkTS`。
- 只暂存当前任务文件，禁止 `git add -A`。每个阶段形成独立可回滚 commit。

## 5. 阶段 A：P0 长连接退出稳定性

### Task A1：建立 teardown 可观测性和可复现基线

**修改文件：**

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `docs/DEVICE_VERIFICATION_CHECKLIST.md`

**实施：**

- 为每次 RDP connect 分配不复用的 session generation；日志只记录 generation、阶段、线程 ID、单调耗时和结果，不记录主机、用户名、输入或剪贴板内容。
- 在 ArkTS cleanup entry/return、NAPI entry/return、每个 stop/join 前后、FreeRDP disconnect 前后、`cbPostDisconnect` 前后、GDI/free 和 renderer/audio destroy 前后加边界日志。
- 记录每个 worker 的 started/running/joinable/stopped 状态，区分“等待 event loop”“等待 input worker”“等待 drive mount”“等待 GL worker”和“FreeRDP callback 内停住”。
- 先不改变顺序，完成 2 分钟、30 分钟、持续鼠标+键盘输入、共享盘开/关、音频开/关、后台恢复后退出的复现矩阵。

**完成条件：** 至少获得一条完整正常 trace；若复现卡死，trace 能唯一指出最后进入的阶段。不得为了复现反复制造未保留日志的系统崩溃。

### Task A2：消除锁反转和所有 join-under-lock

**新增/修改文件：**

- 新增 `entry/src/main/cpp/rdp/rdp_shutdown_state.h`
- 新增 `entry/src/main/cpp/test/rdp_shutdown_state_test.cpp`
- 修改 `entry/src/main/cpp/rdp/freerdp_adapter.h`
- 修改 `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- 修改 `entry/src/main/cpp/CMakeLists.txt`

**目标顺序：**

1. 原子地进入 `DisconnectRequested`，拒绝新输入、新 frame 和新 drive 操作。
2. 清空 InputHandler active adapter；停止输入队列并在不持有 `instanceMutex` 时 join。
3. 取消 trailing frame，停止 frame pump，并确认 renderer 不再被 RDP worker 调用。
4. 停止 event loop；在不持有 `instanceMutex` 时 join event thread。
5. 停止/等待 drive 和 connect thread；所有等待均不得持有 session/instance 锁。
6. 取得稳定的 `freerdp*` 生命周期所有权后释放 `instanceMutex`，再调用 abort/disconnect。
7. `cbPostDisconnect()` 保持幂等，只释放尚未释放的 GDI/channel 资源，不重复 join 已停止 worker。
8. 所有 worker 完成后才执行 context/free，并进入 `Disconnected`。

**测试：**

- shutdown state 只允许 `Running -> Quiescing -> TransportDisconnecting -> Releasing -> Complete`，重复 disconnect 返回同一进行中结果。
- 明确断言任何 `JoinWorker` 和 `CallFreeRdpDisconnect` 动作都要求 `instanceMutexHeld=false`。
- 构造 input worker 正等待 `instanceMutex` 的确定性测试，断连必须能先关闭输入并完成 join。
- 对 connect 中、connected、远端已断开、PostDisconnect 已执行、重复 disconnect 五种状态验证幂等性。
- 将跨线程 stop/running 标志改为受单一 mutex 管理或原子类型，并用测试验证状态可见性。

**完成条件：** 旧的锁反转路径在代码结构上不再成立；同步 adapter teardown 在压力矩阵中每次都能结束。

### Task A3：让 UI 退出与 native teardown 解耦

即使 A2 消除死锁，网络栈、drive 或 EGL 的正常关闭也不应占用 ArkTS UI 线程。本任务为强制项，不再以 250 ms 测量结果作为可选条件。

**新增/修改文件：**

- 新增 `entry/src/main/cpp/extensions/session_teardown_executor.h/.cpp`
- 修改 `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- 修改 `entry/src/main/cpp/extensions/extension_loader_napi.h` 或对应导出声明
- 修改 `entry/src/main/ets/types/rdpnapi.d.ts`
- 修改 native loader ArkTS wrapper（以当前实际导出文件为准）
- 修改 `entry/src/main/ets/pages/RemoteDesktop.ets`
- 修改 `entry/src/main/cpp/CMakeLists.txt`

**接口契约：**

- `beginDisconnect(sessionId)` 在 UI/NAPI 线程只做状态切换、停止新输入/新 presentation、移交 session shared ownership，并立即返回 `disconnectRequestId`。
- 专用 teardown executor 在后台执行 A2 的完整顺序；不能访问已销毁的 NAPI env 或 ArkTS 对象。
- completion 通过受控 TSFN/async work 回到 ArkTS，或由 `getDisconnectState(requestId)` 轮询；页面离开后 completion 仍可安全收尾。
- renderer 销毁必须发生在 RDP presentation 已 quiesced 之后。若同步 renderer destroy 自身可能等待 GL mutex，则将其纳入 native teardown，不在 UI 线程调用。
- `g_sessions` 增加 `Active/Disconnecting/Complete` 状态；不能在 worker 仍引用 adapter 时提前释放，也不能让断连中的 adapter 继续成为 `g_activeConnection`。
- Ability 的 `disconnectAll()` 复用同一 executor 和幂等状态，不建立第二套销毁顺序。

**测试：**

- fake adapter 的 disconnect 阻塞 2 s 时，NAPI 调用仍在 50 ms 内返回，主线程定时器继续执行。
- 重复 back、按钮退出、错误 sheet dismiss、`aboutToDisappear` 和 Ability destroy 只能启动一次 teardown。
- completion 在页面已销毁、renderer 已 detach、应用进入后台时不访问失效对象。
- teardown executor 关闭应用时可 drain 或受控放弃回调，但不能泄漏 adapter/context。

### Task A4：长连接、循环退出和资源收敛门

在 Phone 与 2in1 各执行：

- 30 分钟空闲连接后退出。
- 30 分钟连续滚动/鼠标/键盘后仍在输入时退出。
- 2 小时综合操作后退出。
- Home -> 前台恢复 10 次后退出。
- 共享盘开/关、音频开/关、剪贴板开/关组合。
- 20 次连接/断连循环，以及远端主动断开后本地退出。

记录 UI-return、各 join、FreeRDP disconnect、renderer destroy、总 teardown 时间、线程数、RSS/PSS 和 crash/ANR。任一 UI 卡顿、join 无结束、worker/session 残留都阻塞后续性能阶段。

建议提交：

```powershell
git commit -m "fix(rdp): make long-session teardown non-blocking"
```

## 6. 阶段 B：可信性能基线与 presentation 所有权

### Task B1：分层指标而不是复用失真的 frame bytes

**新增/修改文件：**

- 新增 `entry/src/main/cpp/rdp/rdp_presentation_metrics.h`
- 新增 `entry/src/main/cpp/test/rdp_presentation_metrics_test.cpp`
- 修改 `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- 修改 `entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp`
- 修改 `entry/src/main/cpp/render/gl_renderer.h/.cpp`
- 修改 `entry/src/main/cpp/CMakeLists.txt`

分别记录：invalid events/pixels、copied bytes、submitted/replaced/rejected frames、protocol callback time、queue wait、upload、draw、swap、present result、surface-detached rejection。按 1 秒聚合 P50/P95/max，不输出逐帧 INFO 日志。

`RenderRawBGRAInternal()` 返回结构化 present metrics；queued frame 的节流只使用 worker 的真实成本，不能使用 producer 端 `vector::assign` 耗时冒充渲染成本。

### Task B2：移除裸指针 trailing worker，并建立 surface gate

- 删除 `trailingFrameData`、`trailingFrameThread` 和 `scheduleTrailingFrame()`。
- `RdpFramePump` 接收明确 owned 的 submission，不在 callback 返回后读取 GDI primary buffer。
- 增加原子 `presentationEnabled` 和 renderer generation；detach、disconnect、resize 时先关闭提交并使待处理 job 失效。
- renderer reattach 成功后只允许同 generation 的 job 上屏，并强制一次 full resync。
- `RendererNapi::HasReadyActiveRenderer()` 同时检查 handle、renderer initialized、surface attached 和 generation，避免先复制完整 frame 再在 GL 内拒绝。

**完成条件：** ASAN/设备日志无 use-after-free 特征；后台期间 copied/submitted bytes 接近 0；恢复后第一帧完整且无旧 surface job。

建议提交：

```powershell
git commit -m "fix(rdp): own queued frames and gate detached presentation"
```

## 7. 阶段 C：GDI 路径可交付优化

### Task C1：owned damage accumulator

**新增/修改文件：**

- 新增 `entry/src/main/cpp/rdp/rdp_damage_accumulator.h/.cpp`
- 新增 `entry/src/main/cpp/test/rdp_damage_accumulator_test.cpp`
- 修改 `entry/src/main/cpp/rdp/rdp_render_policy.h`
- 修改 `entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp`
- 修改 `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- 修改 `entry/src/main/cpp/CMakeLists.txt`

**设计：**

- adapter 持有一块完整 owned BGRA staging surface；每次 EndPaint 只复制 invalid rect 对应行并把 pending damage 做 union。
- worker 获取 compact damage snapshot；producer 在短 mutex 内更新 staging 和 pending rect，不与 GL 并行持有同一锁。
- first frame、尺寸变化、surface generation 变化、job replacement 无法合并、非法 rect、分配失败或 union >=70% 时强制 full resync。
- latest-wins 不能丢失最终状态：替换多个 dirty job 时必须合并 damage，并从最新 owned staging 取像素。
- 局部上传 source 指针必须指向 dirty origin；tight compact buffer 使用 `GL_UNPACK_ROW_LENGTH=dirtyWidth`，完整 staging offset 使用原始 stride，并在调用后恢复 pixel-store 状态。

**测试：** rect normalize/clip、相交/不相交 union、replacement 合并、resize/full resync、dirty source origin、stride padding、70% 阈值、allocation failure fallback。

### Task C2：worker-only presentation 与测量驱动调度

- 所有帧包括首帧都由 frame pump worker 上屏；FreeRDP event thread 不再直接调用 GL/EGL。
- 单槽 latest-wins 保留最终 damage；必要时增加一个 in-flight + 一个 pending，而不是无界队列。
- 默认目标 60Hz；只在连续 120 个有效 present 的 P95 upload+draw+swap 超预算时降到 30Hz/20Hz，恢复也要求连续稳定窗口。
- failed/detached/replaced job 不计入慢帧，不因瞬时 resize 永久降频。
- 保证节流窗口结束时最后一个 pending damage 被呈现，不再依赖裸指针 trailing thread。

### Task C3：GL upload 实验门

先比较 CPU damage copy、`glTexSubImage2D`、draw、swap 占比：

- 若 P95 upload+swap 小于总 worker 时间 60%，不引入 PBO。
- 若达到 60%，在 GLES capability 检查后实验 3 个 Pixel Unpack Buffer；任何 GL error 当场回退 direct upload。
- 只有 P95 worker time 改善至少 15%、内存可控且完整视觉矩阵通过时保留 PBO。
- swap interval、buffer age、EGL damage swap 分别作为独立实验，不同时改动，避免无法归因。

**阶段 C 放行条件：** GDI dirty 模式达到第 3.2 节指标，并通过 resize、后台恢复、断连和视觉正确性矩阵。此时已经形成可发布的安全性能版本，不依赖 RDPGFX。

建议提交：

```powershell
git commit -m "perf(rdp): present owned GDI damage from render worker"
```

## 8. 阶段 D：RDPGFX/H.264 对齐 Windows App

该阶段是达到 Windows App 高动态场景体验的主要候选，但不得绕过 GDI 稳定版本。

### Task D1：补齐 ResetGraphics/DesktopResize 安全路径

- 注册并测试 `DesktopResize`、RDPGFX ResetGraphics、channel connected/disconnected 生命周期。
- resize 时停止旧 generation 提交、重建 GDI/texture staging、更新 source size/坐标映射，并强制首个 full frame。
- channel 初始化失败、server 不支持、codec 不支持或 reset 失败时记录 capability 结果；只允许下次连接回退 GDI，不在活跃 session 中反复切换图形栈。
- 只有 GDI、GFX、GFX-H.264 的 connect/resize/Home restore/reconnect/10 分钟动态画面矩阵全部通过，`rdpGfxResetPathSafe()` 才能由常量改为真实 capability gate。

### Task D2：H.264 输出与硬件解码可行性

- 修改 OH_AVCodec/OH_NativeImage 前先查本地 API 23 文档并记录 buffer/surface ownership、flush、resize、detach/reattach 和销毁约束。
- 首先完成隔离的 AVC420 lifecycle proof；AVC444、跨 surface 零拷贝和直接 GPU texture 输出分别验证。
- 硬件路径必须比已验证 GDI-damage 的 P95 presentation time 低至少 30%，并通过 2 小时连接、20 次重连和后台恢复，才可进入生产计划。
- 若设备不支持所需 profile/format，保持 RDPGFX software GDI consumer 或 GDI-damage，不暴露无效的用户画质开关。

建议提交：

```powershell
git commit -m "feat(rdp): gate graphics pipeline on reset and resize safety"
```

## 9. 阶段 E：最终比较与发布决策

### Task E1：完整回归

覆盖密码/NLA/证书接受拒绝、ErrorInfo/no-frame、键鼠/触控、IME、rdpsnd、剪贴板、共享盘、后台恢复、远端 resize、远端主动断开及四协议主界面回归。

按变更风险执行：focused native tests、双 ABI（进入 native 发布候选时）、`default@OhosTestCompileArkTS`、`assembleHap`、Light gate、设备安装与 hilog 证据。

### Task E2：同条件 Windows App A/B

输出一张固定格式表：commit、设备、主机、网络、分辨率、刷新率、graphics mode、有效 FPS、callback P95、queue P95、upload/draw/swap P95、input-visible P95、submitted bytes、replacement、RSS/PSS、GL error、视觉结论和退出耗时。

最终只允许以下四种结论之一：

- 发布 `GDI-damage`。
- 发布 `GDI-damage + PBO`。
- 发布 `RDPGFX`，GDI-damage 为 fallback。
- 发布 `RDPGFX-H.264`，RDPGFX/GDI-damage 为分级 fallback。

没有达到数值门槛时保留最稳定的上一阶段，并基于最大实测瓶颈建立后续任务，不以主观“看起来更流畅”放行。

## 10. 依赖关系与检查点

```text
A1 teardown trace
  -> A2 lock/order fix
  -> A3 async UI teardown
  -> A4 long-session gate
  -> B1 truthful metrics
  -> B2 ownership/surface gate
  -> C1 damage accumulator
  -> C2 worker scheduling
  -> C3 optional GL upload experiment
  -> D1 optional RDPGFX gate
  -> D2 optional hardware output
  -> E1/E2 regression and release decision
```

强制评审点：

- A2 完成后审查所有 mutex/join/FreeRDP callback 边界。
- A3 完成后审查 NAPI、session shared ownership、页面销毁和 Ability destroy 的幂等性。
- B2 完成后审查每一处跨线程像素数据所有权。
- C1 完成后做 dirty 像素正确性设备评审，未通过不得进入调度实验。
- D1/D2 均为能力门，不得阻塞已验证的 GDI-damage 发布。

## 11. 当前下一步

本分支只更新计划，不直接修改运行时代码。计划合并后，下一实现任务应从 **Task A1 + A2** 开始：先补 teardown trace 和 deterministic shutdown tests，再修复 `disconnectActiveInstance()`/`cleanupInstance()` 的持锁回调与 join 顺序；A2 验证通过后立即执行 A3，不继续画面优化。
