# PIP RustDesk 恢复卡住与 RDP 无法启动排查

日期：2026-07-23（Asia/Shanghai）
范围：1.0.8 后台视频、VIDEO_PLAY 画中画、RustDesk 前后台恢复、RDP GDI 画面管线
结论性质：源码排查、官方 API 23 语义核对和运行时修复记录。

## 结论

当前两个现象不是同一个问题：

1. **RustDesk 在 PIP 返回全屏后卡住**：PIP 内画面持续刷新，说明远端连接和解码线程仍在工作；恢复全屏时，PIP renderer、页面 renderer 和 decoder pipeline 的切换没有形成严格的生命周期屏障。系统还处于 `ABOUT_TO_RESTORE` 等过渡态时，页面可能已经开始重建 renderer；同时状态回调可能先把 `renderPreservedInPip` 清零，导致旧 PIP renderer 的释放分支被跳过。随后新 renderer 覆盖旧句柄，恢复请求即使发送成功，也可能仍指向旧 surface/generation，因此画面不再刷新。

2. **RDP PIP 直接启动不了**：PIP 策略和 attach 入口硬性要求 `decoderHandle > 0`。RDP 的实际视频路径没有使用 RustDesk/VP9 decoder，而是 FreeRDP GDI `EndPaint` 将帧写入 damage accumulator，再由 `RdpFramePump` 调用 `PresentRawBgra*`。因此 RDP 即使已经有正常画面，也会在 PIP 准备/启动前被判定为无视频，或者在 attach 阶段被拒绝。这是明确的协议路径错配。

## RustDesk 恢复卡住

### 现有时序

RustDesk 进入后台时，`detachForBackground()` 将 renderer 从页面 surface 转移到 PIP free-node XComponent，并在成功后保留连接、decoder 和 `rendererHandle`。PIP attach 入口位于：

- `entry/src/main/ets/pages/RemoteDesktop.ets:5040`
- `entry/src/main/ets/pages/RemoteDesktop.ets:5170`

该入口当前会执行以下顺序：

1. 从当前 renderer 读取远端媒体比例；
2. 调用 `detachVideoPipelineForBackground()`；
3. detach 或销毁页面 renderer；
4. 为 PIP surface 创建新的 renderer；
5. 重新 bind decoder pipeline；
6. 请求 decoder recovery 和 frame refresh；
7. 让 PIP controller 报告 attach 成功。

PIP 返回前台时，`restoreFromBackground()` 先停止实况窗/后台任务，然后继续释放 PIP renderer，最后由 `doBackgroundRestoreRender()` 重新绑定页面 surface。相关位置：

- `entry/src/main/ets/pages/RemoteDesktop.ets:5293`
- `entry/src/main/ets/pages/RemoteDesktop.ets:5338`
- `entry/src/main/ets/pages/RemoteDesktop.ets:5402`
- `entry/src/main/ets/pages/RemoteDesktop.ets:2945`

### 已确认的生命周期缺口

#### 1. `ABOUT_TO_RESTORE` 被当成了可继续恢复的状态

`RemoteSessionPipService` 的停止流程允许在系统尚未达到 `STOPPED` 时继续后续逻辑，并对过渡态使用有界等待。官方 API 语义中，`ABOUT_TO_RESTORE` 只表示 WMS 正在恢复，`STOPPED` 才表示 PIP 已停止完成。

这意味着页面侧可能出现如下时序：

```text
PIP: ABOUT_TO_RESTORE
页面: stopSessionLiveView() 返回/超时
页面: 开始销毁或重建 renderer
WMS: 仍在完成 PIP controller/surface 的恢复
PIP: STOPPED
```

在这个窗口中切换 EGL/native surface，容易留下仍被 PIP 使用的旧 target，或者让下一次绑定拿到已经失效的 surface generation。单纯再次调用 `requestFrameRefresh()` 不能修复 target 所有权错误。

#### 2. 状态回调可能先清除 `renderPreservedInPip`

`handleRemoteSessionPipStopped()` 在收到停止回调时会先将 `renderPreservedInPip` 设为 `false`。而 `restoreFromBackground()` 的后续释放逻辑又以该标志作为“是否释放 PIP renderer”的条件。

因此存在明确的代码级竞态：

```text
PIP 停止回调: renderPreservedInPip = false
restoreFromBackground(): 进入 continueRestore()
continueRestore(): 跳过“释放 PIP renderer”分支
doBackgroundRestoreRender(): 重新创建/覆盖 rendererHandle
```

旧 renderer 的 native/EGL 生命周期没有被当前恢复流程完整消费，句柄覆盖后也无法再通过 `rendererHandle` 找回它。该缺口比 decoder recovery 或远端刷新请求更靠前，是当前 RustDesk 恢复卡住的首要修复对象。

#### 3. decoder 的 recovery 请求缺少 renderer 所有权保证

`runRestoreFrameRefresh()` 和 `doBackgroundRestoreRender()` 会在多个延迟点重新 bind decoder、arm recovery 并请求 refresh。这个机制可以等待关键帧，但前提是 renderer 已经唯一绑定到当前页面 surface。

如果旧 PIP renderer 尚未完成释放，或 surface generation 已经变化，recovery 仍会把帧送到错误 target。日志中出现 `native decode skipped: no active video pipeline` 时只能说明某个时刻 pipeline 没有 active target，不能证明远端连接断开；它与“连接仍在但前台不刷新”相符。

### RustDesk 修复边界

RustDesk 修复必须保证以下不可逆顺序：

```text
收到 PIP 恢复请求
  -> 等待 PIP controller 到达 STOPPED
  -> join/完成 decoder pipeline detach
  -> 释放并确认 PIP renderer handle
  -> 标记旧 surface generation 无效
  -> 创建/绑定页面 renderer
  -> bind decoder
  -> arm recovery + 请求完整刷新
  -> 允许页面继续接收帧
```

`renderPreservedInPip` 应表示 renderer 所有权事实，而不是由某个异步停止回调直接改写的临时状态。停止回调只能记录 terminal state 并唤醒等待者；恢复流程必须自己消费并清除 PIP renderer 所有权。任何超时都应进入明确的 abort/retry 分支，不能继续覆盖 renderer 句柄。

## RDP PIP 无法启动

### RDP 的真实视频管线

RDP 不经过 `SoftwareDecoder`/`HardwareDecoder`。实际链路是：

```text
FreeRDP GDI primary buffer
  -> cbEndPaint()
  -> RdpDamageAccumulator
  -> RdpFramePump worker
  -> RendererNapi::PresentRawBgraActive/RectActive()
```

证据位置：

- `entry/src/main/cpp/rdp/freerdp_adapter.cpp:1565`：`cbEndPaint()` 接收 GDI dirty region、复制 owned frame 并提交 frame pump；
- `entry/src/main/cpp/rdp/rdp_frame_pump.cpp:132`：worker 取 snapshot 后调用 `PresentRawBgra*`；
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp:2548`：`requestFrameRefresh()` 通过 owned frame 和 frame pump 请求完整刷新。

### 已确认的路径错配

当前 `prepareRemoteSessionPipForForeground()` 的视频条件是：

```text
rendererHandle > 0 && decoderHandle > 0 && surfaceReady
```

位置：`entry/src/main/ets/pages/RemoteDesktop.ets:2736`。

`detachForBackground()` 又以同样的 `decoderHandle > 0` 作为启动 PIP 的前置条件，位置：`entry/src/main/ets/pages/RemoteDesktop.ets:5191` 附近。RDP 没有 decoder handle，所以会在 `RemoteSessionPipService.start()` 之前进入禁用/停止路径。

即使绕过前置条件，`attachRendererToPipSurface()` 仍然要求 decoder handle，并会执行 decoder detach/bind，位置：`entry/src/main/ets/pages/RemoteDesktop.ets:5043`、`entry/src/main/ets/pages/RemoteDesktop.ets:5060`、`entry/src/main/ets/pages/RemoteDesktop.ets:5081`。这对 RDP 是错误操作，不能作为通用 renderer attach 逻辑。

### 第二个独立风险：`hasVideo` 的判定时机

全局 `VideoActivityState` 只有在收到并记录真实视频帧后才变为 active：

- `entry/src/main/cpp/video/video_activity_state.cpp:3`
- `entry/src/main/cpp/video/video_activity_state.cpp:24`

如果用户刚建立 RDP 连接就立即退后台，或者切后台瞬间还没有新的 dirty rect，`backgroundMedia.hasVideo` 可能仍为 `false`。这会让生命周期策略返回 `DISABLE`，即使 RDP renderer、GDI owned frame 或 frame pump 已经可用。因此 RDP 的 PIP 能力不能只依赖“最近是否记录过一帧”。

### RDP 修复边界

RDP 需要独立的 PIP attach/restore 分支，核心条件应是：

```text
当前 RDP session 有效
  && RDP renderer 有效
  && 当前 presentation target 有效
  && GDI owned frame 或可恢复的 frame-pump snapshot 有效
```

进入 PIP 时应切换 renderer 的 presentation target/generation，并让 `RdpDamageAccumulator` 做一次 full resync；不能调用 RustDesk decoder detach/bind。PIP surface 就绪后，应立即用 owned frame 或缓存帧提交一次完整画面，后续 `cbEndPaint()` 继续进入同一个 PIP target。

返回前台时应：

1. 使 PIP generation 失效；
2. 等待 frame pump 不再提交旧 generation；
3. 绑定页面 target；
4. 请求 `requestFrameRefresh()`；
5. 只有页面 target 首次成功 present 后，才清除恢复中的保护状态。

## 官方 API 约束

本地 API 23 文档：

`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\apis-arkui\js-apis-pipWindow.md`

已核对的约束：

- `setAutoStartEnabled(true)` 必须在前台准备阶段完成；
- `VIDEO_PLAY` 是视频播放场景对应的 PIP 模板；
- 系统设置关闭自动 PIP 时，应用侧开启不能强制创建窗口；
- `ABOUT_TO_RESTORE` 是恢复过渡态，`STOPPED` 才是停止完成态；
- `startPiP` 错误码 `1300013` 表示 PIP 窗口创建失败，不能当作 renderer 已成功 attach。

## 修复计划并入项

### P0：RustDesk 恢复一致性

- 给 PIP service 增加明确的 terminal-state await：恢复流程只接受 `STOPPED`/`ERROR`，禁止以 `ABOUT_TO_RESTORE` 或固定超时作为成功；
- 将 PIP renderer ownership 与 `renderPreservedInPip` 解耦，停止回调不再提前消费释放责任；
- 为 renderer handle 和 surface generation 加 session/transfer token，阻止旧 PIP 回调覆盖新页面绑定；
- 保持 decoder detach、worker join、renderer destroy、页面 reattach 的顺序；
- 恢复后先确认页面 target 成功 present，再恢复普通输入和完成恢复状态。

### P0：RDP 独立 PIP 管线

- 新增 RDP video readiness，不再以 decoder handle 作为 RDP PIP 的前置条件；
- 把 RustDesk decoder attach 与 RDP GDI/frame-pump attach 拆成两条协议分支；
- 为 RDP PIP/前台恢复维护 presentation target generation、full resync 和 owned-frame 首帧提交；
- 没有真实 RDP frame 时不创建空 PIP，但连接已有 owned frame 时不能因 `VideoActivityState` 尚未更新而误判无视频。

### P1：可观测性和回归验证

增加成对日志字段：`sessionId`、`protocol`、`pipState`、`rendererHandle`、`surfaceId`、`generation`、`decoderHandle`、`framePumpSubmitted/Presented/Rejected`，并覆盖以下矩阵：

- RustDesk：首次连接后退后台、PIP 连续刷新、PIP 返回全屏、重复进出后台、关闭 PIP、断开后退出；
- RDP：首帧前退后台、首帧后退后台、PIP 连续刷新、PIP 返回全屏、GDI resize、重复进出后台；
- 所有场景都检查没有连接时不启动 PIP、不残留 PIP 动画、不发生旧 generation 的 present。

## 本轮修复结果

- `RemoteSessionPipService` 现在把 `ABOUT_TO_START`、`ABOUT_TO_STOP`、`ABOUT_TO_RESTORE` 都视为 WMS 持有的过渡态，只在 `STOPPED/ERROR` 后销毁 PIP node；无状态的预注册 controller 才允许直接清理，因此无连接退出不会创建短暂 PIP 动画。
- `EntryAbility.onDestroy()` 与 `onWindowStageDestroy()` 共用同一个异步关闭屏障。PIP 未到终态时不提交 `disconnectAll`，避免 renderer、PIP surface 和协议 worker 并发释放。
- RDP PIP 就绪改用 GDI owned frame（`paintCount/lastRenderBytes`），不再额外要求 graphics lifecycle 的尺寸元数据；内容比例缺少 GDI 尺寸时回退到远端请求尺寸，避免 RDP 直接启动被误判为无视频或出现竖向裁切。
- native renderer handle 绑定 surface owner token。旧 PIP renderer 被延迟销毁时不会清空新 renderer 已接管的全局 SurfaceId/native window；替换 surface 时旧 EGL target 先标记为 detached，新的 surface generation 再重新接管。
- PIP attach 失败后，页面只有在 controller 达到终态后才能走 detached renderer fallback；恢复路径继续等待 PIP terminal barrier 后才释放 PIP renderer、重新获取页面 SurfaceId 并恢复 RustDesk decoder/RDP frame pump。

## 验证状态

- 本轮 `rdp_native_tests` 已通过：`129 passed, 0 failed, 129 total`。覆盖软件解码回调在途等待、回调异常隔离、decoder pipeline detach、surface policy、RDP owned-frame/frame-pump、presentation generation 和恢复策略。
- `default@OhosTestCompileArkTS` 已通过；生产非 daemon `assembleHap` 已通过，完成 Native、ArkTS、PackageHap、PackingCheck、SignHap 和符号收集。
- 本轮 `git diff --check` 已通过（仅有 Windows Git ignore/换行提示）；`verify_open_source_release.ps1 -Mode Light` 已通过。构建输出中的 ArkTS deprecated/API permission 提示均为既有警告，不是本轮编译错误。

## 最终修复契约

本轮实现后的生命周期不变量如下，后续调试应以这些契约检查日志，而不是重新假设 PIP 是普通通知或只依赖 decoder：

1. **RustDesk/VP9**：`detachVideoPipeline()` 先标记 pipeline detached、停止软件解码 worker 并 `join`，再清空 `frameCallback_`；`SoftwareDecoderFrameCallbackGate::ClearAndWait()` 会等待已经捕获回调的 `sws_scale`/render 调用结束，避免 `std::function` 并发清空导致 `bad_function_call` 或 renderer 已销毁后回调。
2. **PIP 状态**：控制器在前台创建并调用 `setAutoStartEnabled(true)`；后台只等待系统 auto-start。`ABOUT_TO_START`、`ABOUT_TO_STOP`、`ABOUT_TO_RESTORE` 都是过渡态，只有 `STOPPED/ERROR` 才允许释放 PIP node、PIP renderer 和继续 native teardown。`ABOUT_TO_START` 的关闭路径只在收到 `STARTED` 后发送一次 `stopPiP()`。
3. **恢复顺序**：PIP terminal barrier 完成后，才释放 PIP renderer、使旧 surface generation 失效、重新取得页面 SurfaceId、创建页面 renderer、绑定 RustDesk decoder 或 RDP frame pump，并请求恢复帧。停止回调不提前消费 `renderPreservedInPip` 的释放责任。
4. **renderer/surface 所有权**：renderer 使用单调不复用的 opaque handle；全局 SurfaceId、NativeWindow 和 owner token 的复合读写由 mutex 保护。旧 renderer 延迟析构时，只有仍持有 owner token 的 renderer 才能清理全局 NativeWindow，不能误清理新 PIP/页面 surface。
5. **RDP**：RDP 不再要求 decoder handle。PIP readiness 使用 `paintCount > 0 && lastRenderBytes > 0` 判断 GDI owned frame；attach/restore 走 `presentRdpCachedFrame()` 与 frame-pump refresh，不调用 RustDesk decoder detach/bind。远端媒体比例和本地 XComponent 尺寸分离，尺寸缺失时使用远端请求尺寸回退，避免竖向大裁切。
6. **无会话退出**：没有 active session 时不准备 PIP；尚未发生可见 PIP 状态的预注册 controller 直接取消，不调用 `stopPiP()`，因此不会在退出应用时产生短暂 PIP 退出动画。

## 官方语义记录

API 23 官方文档为：
`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\apis-arkui\js-apis-pipWindow.md`。

`PiPState` 只有 `ABOUT_TO_START`、`STARTED`、`ABOUT_TO_STOP`、`STOPPED`、`ABOUT_TO_RESTORE`、`ERROR`，不存在 `RESTORED`。因此恢复流程以 `ABOUT_TO_RESTORE -> STOPPED/ERROR` 为终止屏障；不能把收到 `ABOUT_TO_RESTORE` 或固定延迟当作 native surface 已经安全可重建。`VIDEO_PLAY` 是视频播放模板，`setAutoStartEnabled(true)` 必须在主窗口仍可用时设置，系统关闭自动 PIP 开关时应用不能强行创建窗口。

## 设备验收边界

自动化门禁不能替代 WMS、XComponent 和真实远端帧的设备验证。设备 `192.168.3.235:38451` 在本轮仍处于锁屏状态，因此以下项目仍是待执行验收，不报告为已通过：

- RustDesk 冷启动首连后退后台，PIP 连续刷新，PIP 点击恢复全屏后持续刷新，重复进出后台；
- RDP 首帧前/后退后台、PIP 连续刷新、GDI resize、恢复后首帧和输入映射；
- 实况窗/媒体胶囊注册、AVSession 无媒体时的通知回退、PIP 关闭/拖拽关闭；
- 无连接直接退出应用不出现 PIP 动画，断开连接后再退出也不出现延迟 PIP 动画；
- 日志必须能看到同一 `sessionId/protocol/rendererHandle/surfaceId/generation` 的切换，且旧 generation 的 present 只被拒绝、不触碰新 renderer。

## 本次增量修复：首次 PIP 尺寸与 RustDesk 预鉴权恢复（2026-07-23）

### 设备日志证据

`device-logs-38451-pip-cycle-20260723-current.txt` 记录了同一次 PIP 自动启动中的尺寸变化：

- WMS 初始布局为 `2560x1600`（占位的物理显示尺寸）；
- 随后 WMS 把 PIP 窗口调整为 `1239x774`；
- 应用侧同时收到 `PIP XComponent surface changed` 的两次回调。

这说明首个 `SurfaceRect` 不能被视为最终窗口尺寸。若页面 renderer 在首个回调期间仍是 surface owner，后续真实尺寸可能只更新在控制器缓存中，无法触发已完成 attach 的 PIP renderer resize，表现就是首次 PIP 只显示约四分之一；返回前台后重新 attach 才“看起来正常”。

日志还显示 RustDesk 预鉴权交接会在远程页第一次拥有画布时执行 `doBackgroundRestoreRender: preauthenticated session attached`。这条路径与普通前后台恢复不同：普通恢复会暂时释放 PIP renderer，但 decoder/session 仍然存在，不能因为 `getRendererHandle() <= 0` 就再次创建 decoder。重复创建会累积旧 surface/BufferQueue，最终触发旧 EGL target 或整个传输停止。

### 代码修复

- `RemoteSessionPipXComponentController` 新增 `notifyCurrentSurface()`：PIP renderer attach 成功后重新读取当前 `SurfaceRect`，无论尺寸是否与已发布值相同都向页面层发出最终尺寸，确保执行 `setXComponentSurfaceId()` 与 `resizeRenderer()`；首个占位尺寸不会成为永久 renderer 尺寸。
- `RemoteSessionPipService` 在 `VIDEO_PLAY` 自动启动完成后调用上述 reconciliation，保留系统回调中的后续尺寸更新，并继续以远端视频尺寸作为 PIP 内容比例，而不是把本地 XComponent 尺寸当成视频源尺寸。
- `RemoteDesktop` 增加显式的一次性 `rustdeskPreauthenticated` 标记。只有列表页预鉴权交接且 decoder、renderer 都尚未存在时才创建首个 RustDesk pipeline；普通 PIP 恢复通过现有 decoder/renderer reattach 路径，不再用 renderer handle 是否暂时释放来推断预鉴权。
- 显式断开和清理会消费该标记，避免离开会话后迟到的 surface 回调再次创建远程管线。
- `RemoteSessionPipLifecyclePolicy` 增加一次性预鉴权策略测试，覆盖 RustDesk、RDP、已有 decoder/renderer 和标记缺失场景。

### 自动化验证

- `rdp_native_tests`：`129 passed, 0 failed`；
- `default@OhosTestCompileArkTS`：通过；
- 生产 `assembleHap`（含 Native、ArkTS、PackageHap、PackingCheck、SignHap 和符号收集）：通过；
- `git diff --check`：通过；
- `verify_open_source_release.ps1 -Mode Light`：通过。

### 仍需设备验收

设备 `192.168.3.235:38451` 在本轮仍锁屏，以上自动化结果不能替代下列验收：冷启动首次连接后退后台、首次 PIP 尺寸和连续帧、PIP 返回全屏、连续进出后台、RDP PIP、实况窗/媒体胶囊注册，以及无连接退出不出现 PIP 动画。验收时重点确认日志出现 `PIP XComponent final surface reconciliation`，并确认同一 `sessionId` 没有因普通恢复再次出现首个 decoder 初始化。

设备解锁后直接按上述矩阵验证并把 hilog 证据追加到本文件；不需要重新建立问题描述或回滚本轮 native/ArkTS 修复。

## 崩溃跟进：PIP 首次布局回调异常（2026-07-23 18:53）

### 崩溃结论

`C:\Users\14288\Desktop\crash_log.txt` 的进程信息为 `com.example.remotedesktop`、版本 `1.0.8`，退出原因是 ArkTS `TypeError`，不是 VP9 native abort：

- `Error message: undefined is not callable`；
- 栈顶为 `onSurfaceChanged entry (entry/src/main/ets/services/RemoteSessionPipService.ets:65:10)`；
- 18:53:32.734 收到 PIP XComponent 创建，18:53:32.748 WMS 把窗口从 `2560x1600` 调整为 `1239x774`；
- 随后 `onSurfaceChanged` 抛出未捕获异常，ArkCompiler 进入 `HandleUncaughtException`，AppKit 记录 `about to exit due to RuntimeError`。

因此本次“退到后台直接闪退”是上一增量为处理尺寸回调新增的 `this.publishSurfaceInfo()` 调用触发的 ArkUI XComponent 回调代理兼容性问题。API 23 的系统回调可能带有控制器字段但不具备子类的私有 helper 方法；异常发生在 PIP 首次最终布局到达时，时间上与后台切换一致。

### 修复

- `onSurfaceChanged` 恢复为自包含回调：只更新 SurfaceId/尺寸、记录日志，并以内联对象向 handler 发布，避免从系统回调代理调用子类 helper；
- 系统回调和真实 controller reconciliation 两条路径都使用 `typeof handler === 'function'` 检查，`null`、`undefined` 或失效代理都不会抛出调用异常；
- `waitForSurface()` / `notifyCurrentSurface()` 仍在真实 `RemoteSessionPipXComponentController` 实例上执行 `getXComponentSurfaceRect()`，所以不会回退到旧的“四分之一画面”行为；最终 `1239x774` 仍会在 renderer attach 后同步到 renderer。

### 本次增量验证

- `default@OhosTestCompileArkTS`：通过；
- 非 daemon 生产 `assembleHap`：通过，`CompileArkTS`、Native、`PackageHap`、`PackingCheck`、`SignHap` 和符号收集均完成；
- 既有 native `rdp_native_tests`：`129 passed, 0 failed`；
- `git diff --check`：通过（仅有 Windows Git ignore/换行提示）；Light 合规门：通过。

设备重装包含本修复的 HAP 后，仍需复测首次 RustDesk 连接退后台、PIP 从 `2560x1600` 到 `1239x774` 的布局变化、连续前后台恢复及 RDP PIP；未完成这组实机复测前，不宣称设备端崩溃已最终验收通过。

## 前台恢复后性能诊断轮询修复（2026-07-23）

### 根因

进入后台时 `aboutToDisappear()` 和 `detachForBackground()` 都会调用
`stopRustDeskDiagnosticsPolling(true)`，这会同时清除基础诊断快照、本机资源快照和
轮询 timer。RustDesk 预鉴权交接路径会重新启动轮询，但普通
`doBackgroundRestoreRender()` 在 renderer reattach 成功后只恢复视频、输入和剪贴板，
没有重新启动诊断轮询。因此普通前后台恢复后，基础性能面板停止刷新，Pro 面板的
CPU/内存/GPU 采样也停在空值或旧值。

### 修复

- `RemoteDesktop.ets` 新增 `resumeRustDeskDiagnosticsAfterForeground()`，只在当前仍是
  已连接 RustDesk session、基础诊断开关开启时恢复 dock 和轮询；Pro 开关沿用同一次
  refresh 的 `getLocalResourceStats(true)` 采样。
- 普通 renderer reattach 和 RustDesk 预鉴权首次挂载都调用该恢复函数；轮询仍捕获当前
  `sessionId` 与 `connectAttemptId`，旧会话不能向新会话写入数据。
- RustDesk “远端应用双指缩放”现有默认值保持关闭：新 Preferences 缺省值和两个页面的
  初始状态均为 `false`。该设置不走云同步，用户明确打开后的本地选择不会被升级强制覆盖。

### 本次自动化验证

- `default@OhosTestCompileArkTS`：通过；
- 非 daemon 生产 `assembleHap`：通过；
- `git diff --check`：通过；
- `verify_open_source_release.ps1 -Mode Light`：通过。

设备解锁后需在 RustDesk 诊断基础开关和 Pro 开关均开启的情况下执行：连接、退后台、
恢复前台，确认日志出现 `resumeRustDeskDiagnosticsAfterForeground`，基础 FPS/码率和
Pro CPU/内存采样在恢复后继续变化。
