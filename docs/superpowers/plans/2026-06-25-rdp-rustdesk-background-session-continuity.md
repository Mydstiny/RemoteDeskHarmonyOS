# RDP/RustDesk Background Session Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox format and must be executed in order. Do not skip verification gates.

## Goal

实现 RDP / RustDesk 已连接时的后台连续会话策略：

- 上滑系统导航条 / 回桌面 / UIAbility `onBackground()`：不断开远程协议连接，保留音频管线，前台 UI 与 Surface 可释放或脱附。
- 左右滑动退出 / 返回退出 / 应用内断开按钮：立即执行完整断连，并清理连接状态。
- 用户从最近任务清理后台 / UIAbility `onDestroy()` / WindowStage destroy：彻底断开连接，清理 native session、音频、渲染、剪贴板、键盘状态。
- 从后台重新进入 App：自动重建 XComponent 渲染链路，画面传输刷新恢复；音频连接在后台期间保持输出，不因前台恢复重复创建或断续。
- 前台连接状态展示使用系统允许的后台任务通知/AVSession 能力；不要把远程连接伪装成 dataTransfer live view。文件传输继续使用现有 dataTransfer live task。

## Architecture

新增一层“会话运行态”把协议连接、UI 页面生命周期、native handle、后台任务分开：

- `RemoteSessionState`：纯状态模型，描述 protocol、connection、uiVisibility、backgroundMode、audioState、renderState、exitReason。
- `NativeSessionHandles`：集中管理 native handle 生命周期，区分 `detachForBackground()` 与 `disconnectAndRelease()`。
- `RemoteSessionBackgroundTaskService`：按实际业务启动/停止 HarmonyOS 长时任务，远程连接使用 `multiDeviceConnection`，有真实远端音频时叠加 `audioPlayback`。
- `RemoteDesktop.ets`：页面只负责 UI attach/detach、输入、渲染重建；不再在普通 `aboutToDisappear()` 中无条件断连。
- `EntryAbility.ets`：`onBackground()` 进入 preserve 模式，`onDestroy()` / `onWindowStageDestroy()` 执行 final disconnect。
- NAPI / native：提供可恢复会话状态、渲染 surface 重新绑定、可选刷新/关键帧请求；保持现有 GPU 销毁顺序约束。

## Tech Stack

- ArkTS strict, API 23.
- HarmonyOS backgroundTaskManager continuous task.
- OHAudio renderer for remote audio.
- XComponent + native renderer / decoder.
- FreeRDP adapter + RustDesk FFI bridge.
- ohosTest / Hvigor build verification.

## Global Constraints

- 遵守 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`。
- 不默认启用 `USE_REAL_FREERDP`。
- 不做大重构；每个任务只改必要边界。
- 不改 native release order，除非该任务明确要求并有验证。
- RDP startup 不加 ArkTS TCP preflight。
- RDP session size 与 local surface size 分离。
- 销毁 surface 前必须保留 `markXComponentSurfaceDestroyed()` 优先于 renderer destroy 的规则。
- 不把远程连接状态伪装成文件传输 live view；dataTransfer 只用于文件传输。
- 如果没有真实远端音频，不要启动 `audioPlayback` 作为保活手段。
- UI 改动不做沉浸式大改；后台状态只做最小通知/状态入口。

## Current Evidence

- `entry/src/main/ets/pages/RemoteDesktop.ets` 当前 `aboutToDisappear()` 调用 `cleanup()`，会断连并销毁音频/渲染。
- `entry/src/main/ets/entryability/EntryAbility.ets` 当前 `onBackground()` 调用 `disconnectRemoteSessions()`。
- `entry/src/main/ets/services/ExtensionLoader.ets` `disconnect()` 会重置 session。
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp` `NapiDisconnect` 会调用 adapter disconnect，并销毁 active native audio。
- `entry/src/main/ets/services/FileTransferLiveTaskService.ets` 已使用 `dataTransfer` live task，适合文件传输，不适合远程连接常驻状态。
- 华为 API 23 文档显示：后台长时任务应与真实业务匹配；`dataTransfer` 需要真实传输进度；`audioPlayback` 需要真实音频播放；远程连接更接近 `multiDeviceConnection`。

## Ordered Task Plan

### T-230 Build Baseline Documentation

- [ ] Read `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` and confirm T-230 acceptance criteria.
- [ ] Create or update `docs/BUILD_BASELINE.md`.
- [ ] Record exact current baseline:
  - latest commit: run `git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop rev-parse --short HEAD`
  - worktree status: run `git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop status --short`
  - known dirty state: existing `freerdp` submodule may appear as dirty; do not reset it.
- [ ] Document official build command from `CODEWALK.md`:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

- [ ] Document current expected build result and where to paste future build logs.
- [ ] Verification:
  - [ ] `git diff --check`
  - [ ] Run the build command once if native/toolchain state has changed; otherwise note "docs-only baseline refresh, build not required".

### T-231 Native Dependency Check Scripts

- [ ] Inspect existing native dependency layout:
  - `entry/src/main/cpp/CMakeLists.txt`
  - `entry/src/main/cpp/rdp/`
  - `entry/src/main/cpp/rustdesk/`
  - `freerdp/`
- [ ] Add `scripts/check_native_deps.ps1`.
- [ ] Add `scripts/check_native_deps.sh` only if repo already uses shell scripts or Claude needs cross-platform parity; otherwise keep PowerShell only and document why.
- [ ] Script must check, without downloading:
  - FreeRDP source/submodule presence.
  - Required CMakeLists entries.
  - RustDesk bridge source presence.
  - DevEco SDK environment variables.
  - Node/Hvigor expected path.
- [ ] Script must print actionable failures and exit non-zero on missing required pieces.
- [ ] Do not mutate submodules or fetch network dependencies.
- [ ] Verification:
  - [ ] `powershell -ExecutionPolicy Bypass -File .\scripts\check_native_deps.ps1`
  - [ ] `git diff --check`

### T-235 RDP Status Documentation

- [ ] Create or update `docs/RDP_STATUS.md`.
- [ ] Summarize current RDP architecture:
  - `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
  - `entry/src/main/ets/services/ExtensionLoader.ets`
  - `entry/src/main/ets/pages/RemoteDesktop.ets`
- [ ] Document stable rules from `CODEWALK.md`:
  - remote session size != local surface size.
  - no ArkTS TCP preflight.
  - cleanup must call `markXComponentSurfaceDestroyed()` before renderer destroy.
  - drive/clipboard optional capabilities must not block readiness.
- [ ] Add a section "Background continuity implications":
  - protocol connection can survive UI background only after T-232/T-233/T-234.
  - current code cannot support it because page/ability background paths disconnect.
  - audio path can stay alive only with real audio and proper continuous task.
- [ ] Verification:
  - [ ] `git diff --check`

### T-232 RemoteSessionState

- [ ] Add `entry/src/main/ets/services/RemoteSessionState.ets`.
- [ ] Keep it pure ArkTS: no native calls, no UI imports, no `any`/`unknown`.
- [ ] Define strict enums:
  - `RemoteProtocol`: `rdp`, `rustdesk`, `ssh`, `vnc`.
  - `ConnectionPhase`: `idle`, `connecting`, `connected`, `suspending`, `backgroundPreserved`, `foregroundRestoring`, `disconnecting`, `disconnected`, `failed`.
  - `UiVisibility`: `foreground`, `background`, `destroyed`.
  - `ExitReason`: `homeGesture`, `systemBackground`, `explicitBack`, `explicitDisconnect`, `recentTaskCleared`, `abilityDestroy`, `error`.
  - `RenderPhase`: `none`, `surfaceReady`, `attached`, `detached`, `restoring`, `failed`.
  - `AudioPhase`: `none`, `starting`, `playing`, `backgroundPlaying`, `stopped`, `failed`.
- [ ] Define immutable-ish state records with explicit fields:
  - session id.
  - protocol.
  - host id/address display fields.
  - connection phase.
  - UI visibility.
  - render phase.
  - audio phase.
  - `preserveInBackground`.
  - `mustDisconnectOnDestroy`.
  - last error code/message.
  - timestamps.
- [ ] Add reducer helpers:
  - `createInitialRemoteSessionState()`.
  - `markConnecting()`.
  - `markConnected()`.
  - `markBackgroundPreserved(reason)`.
  - `markForegroundRestoring()`.
  - `markRenderDetached()`.
  - `markRenderAttached()`.
  - `markAudioBackgroundPlaying()`.
  - `markDisconnecting(reason)`.
  - `markDisconnected(reason)`.
  - `markFailed(error)`.
- [ ] Add ohos tests in `entry/src/ohosTest/ets/test/RemoteSessionState.test.ets`.
- [ ] Register the test in the existing ohosTest test aggregator.
- [ ] Verification:
  - [ ] Run ohos tests if available in local workflow.
  - [ ] Run hvigor build.
  - [ ] `git diff --check`

### T-233 NativeSessionHandles

- [ ] Add `entry/src/main/ets/services/NativeSessionHandles.ets`.
- [ ] Purpose: own native-related handles and provide explicit lifecycle operations.
- [ ] Required methods:
  - `attachConnectedSession(sessionId, protocol)`.
  - `markSurfaceAttached(surfaceId, width, height)`.
  - `detachRenderForBackground()`.
  - `reattachRenderForForeground(surfaceId, width, height)`.
  - `stopAudioOnly()`.
  - `disconnectAndRelease(reason)`.
  - `isProtocolConnected()`.
  - `isRenderAttached()`.
  - `isAudioActive()`.
- [ ] The class must not call native APIs directly at first. Inject an adapter interface so tests can assert call order.
- [ ] Define adapter interface methods that map to later ExtensionLoader/native operations:
  - `markXComponentSurfaceDestroyed()`.
  - `destroyRendererOnly()`.
  - `disconnectProtocol()`.
  - `destroyAudio()`.
  - `rebindSurface()`.
  - `requestFrameRefresh()`.
- [ ] Enforce safe call order:
  - background detach: `markXComponentSurfaceDestroyed()` then renderer detach/destroy only; do not call protocol disconnect; do not destroy audio if audio should continue.
  - full disconnect: `markXComponentSurfaceDestroyed()` then renderer cleanup then audio cleanup then protocol disconnect, unless existing native order requires protocol first; verify before changing.
- [ ] Add `entry/src/ohosTest/ets/test/NativeSessionHandles.test.ets` with call-order tests.
- [ ] Verification:
  - [ ] ohos tests for call order.
  - [ ] hvigor build.
  - [ ] `git diff --check`

### T-234 ExtensionLoader Result API

- [ ] Update `entry/src/main/ets/services/ExtensionLoader.ets`.
- [ ] Introduce strict result types:
  - `ExtensionResult<T>`.
  - `ExtensionErrorCode`.
  - `NativeSessionSnapshot`.
- [ ] Convert connection, disconnect, render, audio, and optional capability calls to return typed results where feasible.
- [ ] Keep public wrappers backward-compatible until RemoteDesktop split tasks are complete.
- [ ] Add APIs needed by background continuity:
  - `getSessionSnapshot(): ExtensionResult<NativeSessionSnapshot>`.
  - `detachRenderForBackground(): ExtensionResult<void>`.
  - `reattachRenderForForeground(surfaceId: string, width: number, height: number): ExtensionResult<void>`.
  - `requestFrameRefresh(): ExtensionResult<void>`.
  - `disconnectForExit(reason: string): ExtensionResult<void>`.
- [ ] Update `entry/src/main/ets/types/rdpnapi.d.ts` with matching signatures.
- [ ] Update `entry/src/main/cpp/extensions/extension_loader_napi.cpp` only for APIs that truly require native support.
- [ ] Do not alter existing `disconnect()` behavior until T-252 wires policy.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] targeted native compile through assembleHap.
  - [ ] `git diff --check`

### T-251 Remote Session Background Task Service

- [ ] Add `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`.
- [ ] Use official API 23 docs under `C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\` as authority.
- [ ] Update `entry/src/main/module.json5` `backgroundModes`:
  - keep existing `dataTransfer` for file transfer.
  - add `multiDeviceConnection` for remote session continuity if supported by API 23 schema.
  - add `audioPlayback` only for real audio playback.
- [ ] Service responsibilities:
  - `startRemoteSessionTask(context, sessionSummary)`.
  - `startAudioPlaybackTask(context, audioSummary)` only when audio has started or real remote audio is expected/active.
  - `stopRemoteSessionTask(context)`.
  - `stopAudioPlaybackTask(context)`.
  - `updateRemoteSessionNotification(...)` using normal notification/wantAgent if public APIs allow.
- [ ] Do not use `dataTransfer` live view for the remote connection itself.
- [ ] Tapping notification should return to `RemoteDesktop` for the active host/session.
- [ ] If system rejects background task start, keep protocol behavior conservative:
  - remain connected only while system allows.
  - surface a typed warning state.
  - do not silently fake a file transfer task.
- [ ] Tests:
  - inject a small background task adapter to unit-test mode selection.
  - verify no `dataTransfer` mode for plain remote session.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] `git diff --check`

### T-252 RemoteDesktop / EntryAbility Lifecycle Policy

- [ ] Update `entry/src/main/ets/entryability/EntryAbility.ets`.
- [ ] Replace unconditional `onBackground()` remote disconnect with policy:
  - if active remote session exists and `preserveInBackground` is true, start background session task and mark state background-preserved.
  - do not call `disconnectRemoteSessions('background')` for RDP/RustDesk preserved sessions.
  - keep security lock / DataCrypto background behavior intact.
- [ ] Keep final cleanup in:
  - `onDestroy()`.
  - `onWindowStageDestroy()`.
  - explicit recent-task removal path if available.
- [ ] Update `entry/src/main/ets/pages/RemoteDesktop.ets`.
- [ ] Replace unconditional `aboutToDisappear() -> cleanup()` with route-aware policy:
  - home gesture/system background: detach UI/render only; preserve protocol/audio.
  - explicit back/left-right navigation/app disconnect: call full cleanup.
  - page destroy due ability final destroy: full cleanup.
- [ ] Ensure app UI paths can signal explicit exit:
  - system back handler.
  - app disconnect button.
  - any left/right swipe exit gesture currently implemented.
- [ ] Rename existing `cleanup()` only if needed:
  - `disconnectAndCleanup(reason)` for full release.
  - `detachForBackground(reason)` for preserved background.
- [ ] Avoid changing behavior for SSH/VNC unless state model supports it safely.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] Manual log checklist with hilog:
    - home gesture should not log native disconnect.
    - explicit back should log native disconnect.
    - recent task clear should log native disconnect.

### T-253 Render Detach And Foreground Restore

- [ ] Inspect current render/decoder entry points:
  - `entry/src/main/cpp/render/`
  - `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
  - `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- [ ] Implement background detach:
  - mark surface destroyed.
  - stop accepting draw calls to destroyed surface.
  - release renderer/surface resources only.
  - keep protocol connection and audio callback alive.
- [ ] Implement foreground restore:
  - on new XComponent surface, initialize renderer with remote session size.
  - bind current decoder/render pipeline to new renderer.
  - request first frame refresh/keyframe when available.
- [ ] RDP-specific:
  - `freerdp_adapter.cpp` should tolerate no active renderer while session keeps receiving frames.
  - if frames are dropped while backgrounded, request desktop repaint on foreground if FreeRDP API support exists; otherwise document fallback to next incoming frame.
- [ ] RustDesk-specific:
  - bridge should tolerate no active renderer while FFI thread remains connected.
  - add refresh/keyframe request only if RustDesk FFI exposes safe API; otherwise document fallback.
- [ ] Audio:
  - do not destroy `AudioPlayerNapi` during background detach.
  - foreground restore must not create a second OHAudio renderer if one is already active.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] real device/manual RDP restore test.
  - [ ] real device/manual RustDesk restore test if RustDesk server is available.

### T-254 Foreground Status, Notification, And AVSession

- [ ] Keep in-app status small and utilitarian:
  - connected.
  - background preserved.
  - restoring video.
  - audio playing.
  - reconnect/disconnect errors.
- [ ] Use `RemoteSessionBackgroundTaskService` for system notification/wantAgent status.
- [ ] If using AVSession, use it only for actual remote audio playback metadata/control compatibility.
- [ ] Do not call the connection notification a "live view" unless API actually exposes a live view mode for that background type.
- [ ] Ensure file transfer live task remains separate:
  - `FileTransferLiveTaskService` still owns `dataTransfer`.
  - remote session status must not reuse file transfer notification id.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] manual notification tap returns to active session.
  - [ ] no duplicate notifications for one session.

### T-255 End-To-End Background Continuity Verification

- [ ] Add a manual test doc `docs/RDP_RUSTDESK_BACKGROUND_CONTINUITY_TESTS.md`.
- [ ] Include preconditions:
  - one reachable RDP host.
  - one reachable RustDesk host if available.
  - host with audio output for audio continuity test.
  - hdc/hilog attached.
- [ ] Test matrix:
  - RDP home gesture/background: connection remains; audio continues; no disconnect log.
  - RDP foreground restore: picture refreshes; input works.
  - RDP explicit back/left-right exit: connection state cleared and native disconnect logged.
  - RDP recent-task clear: final disconnect logged.
  - RustDesk same four tests.
  - no-audio session: no `audioPlayback` long task is started.
  - file transfer during remote session: dataTransfer live task still works independently.
- [ ] Add hilog patterns to look for:
  - background preserve state transition.
  - render detach.
  - foreground reattach.
  - native disconnect only for explicit/final paths.
  - audio active native reused.
- [ ] Verification:
  - [ ] run full hvigor build.
  - [ ] paste device test results into the doc.
  - [ ] update `HANDOFF.md`, `TASKS.md`, project memory, and `CODEWALK.md` if new architecture rules were confirmed.

### T-200 HostListPage Split

- [ ] Execute only after T-232 through T-255 are stable, unless Claude decides to keep lifecycle work in a feature branch and resume original refactor queue separately.
- [ ] Split `entry/src/main/ets/pages/HostListPage.ets` according to current `TASKS.md`.
- [ ] Preserve host security lock, cloud sync, protocol launch, and file transfer behavior.
- [ ] Do not mix RemoteDesktop lifecycle policy changes into this split.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] host list manual smoke test.
  - [ ] `git diff --check`

### T-201 RemoteDesktop Split

- [ ] Split `entry/src/main/ets/pages/RemoteDesktop.ets` only after lifecycle policy is green on device.
- [ ] Suggested extraction boundaries:
  - input/controller logic.
  - render surface lifecycle.
  - clipboard/drive helpers.
  - session status view model.
  - background continuity hooks.
- [ ] Preserve all rules from T-252/T-253; do not regress background-preserved session.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] RDP smoke test.
  - [ ] RustDesk smoke test if available.
  - [ ] background continuity matrix subset.

### T-202 CloudStore Split

- [ ] Split cloud sync/storage only after T-200 and T-201 are stable.
- [ ] Do not change remote session lifecycle.
- [ ] Verification:
  - [ ] hvigor build.
  - [ ] cloud sync smoke test.

## Backlog After First Claude Round

- [ ] T-236: BuildProfile/dev signing documentation, if still active.
- [ ] T-237: Manual AppGallery packaging checklist update.
- [ ] T-238: Device compatibility / API 23 validation.
- [ ] T-239: Release smoke test checklist.
- [ ] T-240: Risk log cleanup.
- [ ] T-244: Additional RDP/RustDesk UX hardening only after continuity is stable.
- [ ] T-248: Native cleanup hardening only with focused tests.
- [ ] T-192 / T-241 and other feature work remain lower priority than not regressing active remote sessions.

## Handoff Notes For Claude

- Start by rereading the Mission_transformation files and `CODEWALK.md`.
- Treat T-230, T-231, and T-235 as low-risk documentation/script baseline work.
- Do not implement T-252 before T-232, T-233, and T-234 exist; otherwise the lifecycle policy will turn into another page-local boolean tangle.
- The highest-risk work is T-253 because it touches surface/native/audio lifetime. Keep changes small and verify on device.
- A technically correct solution may show a normal notification rather than a live window for remote connection status. This is expected unless Huawei exposes a public live-view API for `multiDeviceConnection`.
- If the system refuses background task modes, record the exact error code and fail conservatively; never hide it behind fake dataTransfer progress.
- Before handoff completion, update:
  - `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
  - `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
  - `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
  - `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if new durable lifecycle/native rules were learned.

## Final Verification Gate

- [ ] `git diff --check`
- [ ] native dependency check script passes.
- [ ] Hvigor `assembleHap` passes.
- [ ] Device RDP background continuity test passes.
- [ ] Device RustDesk background continuity test passes or is explicitly marked unavailable with reason.
- [ ] Explicit exit and recent-task clear both disconnect.
- [ ] Audio does not duplicate renderers and does not continue under fake playback mode.
- [ ] Handoff files and memory are updated.
