# RDP Windows App Smoothness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Match Windows App RDP foreground smoothness and input responsiveness on the same Windows host, device, network, resolution, and refresh rate, while retaining a safe GDI fallback and a non-blocking, deadlock-free explicit disconnect.

**Architecture:** Retain the FreeRDP software-GDI primary buffer as the compatibility path. Replace full-frame latest-frame copying with an owned damage accumulator: the protocol callback copies invalid rows only and one worker presents fully owned data. RDPGFX/H.264 remains disabled until ResetGraphics/DesktopResize is verified. Hardware decoder output is a separately gated research spike.

**Tech Stack:** C++17, FreeRDP 3.x, OHOS NDK, EGL/GLES3, native policy tests, DevEco assembleHap, HDC/hilog.

## Global Constraints

- Preserve RDP preset, color depth, control mode, audio, clipboard, drive, authentication, and certificate behavior.
- Preserve certificate order: trust decision -> sheet disappears -> route -> native connect.
- Never reconnect a live RDP protocol session solely for presentation recovery.
- Keep FreeRDP_SoftwareGdi=true for all GDI/RDPGFX phases.
- Do not advertise GFX/H.264/RFX until channel lifecycle, ResetGraphics, and DesktopResize pass the device matrix.
- Do not render into detached XComponent/EGL surfaces. Prewarm cache may capture at low rate but must not enqueue presentation.
- The ArkTS UI thread must never hold a native session lock while waiting for any RDP worker, and it must not wait indefinitely for protocol teardown.
- Do not overwrite existing dirty paths: build-profile.json5, entry/oh-package.json5, freerdp/, logs/, or unrelated plans.
- Every behavior change requires focused native tests, assembleHap, and matching device evidence.

## File Structure

- Create: entry/src/main/cpp/rdp/rdp_presentation_metrics.h - RDP ingress, copy, queue, and present counters.
- Create: entry/src/main/cpp/rdp/rdp_damage_policy.h - pure damage union/resync decisions.
- Create: entry/src/main/cpp/test/rdp_presentation_metrics_test.cpp
- Create: entry/src/main/cpp/test/rdp_damage_policy_test.cpp
- Create: entry/src/main/cpp/test/rdp_frame_pump_test.cpp
- Create: entry/src/main/cpp/rdp/rdp_shutdown_policy.h - pure shutdown ordering and bounded UI-return decisions.
- Create: entry/src/main/cpp/test/rdp_shutdown_policy_test.cpp
- Modify: entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp - typed owned submissions, scheduling, stats, and detach gate.
- Modify: entry/src/main/cpp/rdp/rdp_render_policy.h - delegate damage safety decisions.
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp - truthful metrics, GDI damage submissions, DesktopResize.
- Modify: entry/src/main/cpp/render/gl_renderer.h/.cpp - renderer-ready query and upload/draw/swap timings.
- Modify: entry/src/main/cpp/rdp/rdp_performance_policy.h and its test - capability gate.
- Modify: entry/src/main/cpp/CMakeLists.txt - register native tests.
- Modify: docs/DEVICE_VERIFICATION_CHECKLIST.md - baseline, comparison, and regression evidence.

## Acceptance Contract

Use a pinned Windows host, one HarmonyOS device, one network, 1920x1080, 32-bit color, and normal 60Hz display mode. Capture 30 seconds for idle, typing, explorer-scroll, browser-scroll, and motion in both clients.

- Every trace records mode (full, dirty, dirty-union, resync, rejected-detached), bytes, capture, queue, upload, draw, swap, and result.
- No stale tile, partial final animation, black frame, GL error, or coordinate drift after throttle, replacement, resize, background restore, or reconnect.
- Explicit disconnect must return control to ArkTS within 250 ms on the device test matrix; native cleanup may continue only after rendering and input submission have been quiesced.
- A shutdown trace must identify request, event-loop stop, input-worker stop, FreeRDP disconnect begin/end, PostDisconnect begin/end, renderer destroy, and NAPI return with one session identifier and monotonic timestamps.
- Effective presentation rate is at least 90% of Windows App under the same scenario, capped by updates and display refresh.
- P95 input-to-visible-change is no worse than Windows App plus 10 ms when visual echo is measurable.
- GDI damage mode reduces submitted CPU bytes at least 70% in browser-scroll versus baseline without worsening P95 queue wait.
- RDPGFX/H.264 failures fall back on the next user connect to GDI; never retry inside the active session.

---

### Task P0: Eliminate RDP Disconnect Lock Inversion Before Performance Work

**Root-cause evidence:** `FreeRdpAdapter::disconnectActiveInstance()` holds `Impl::instanceMutex` while calling `freerdp_disconnect()`. FreeRDP invokes `instance->PostDisconnect` synchronously during that call. `cbPostDisconnect()` calls `stopInputQueueWorker()` and waits for the input worker. The input worker calls `sendQueuedInputEvent()`, which attempts to acquire the same `instanceMutex`. If a queued input is in flight, the UI-thread NAPI call waits for the worker while the worker waits for the UI-thread lock.

**Files:**
- Create: entry/src/main/cpp/rdp/rdp_shutdown_policy.h
- Create: entry/src/main/cpp/test/rdp_shutdown_policy_test.cpp
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp:592-626, 649-676, 1359-1372, 1571-1577, 1725-1753, 2064-2093
- Modify: entry/src/main/cpp/extensions/extension_loader_napi.cpp:670-714
- Modify: entry/src/main/cpp/CMakeLists.txt
- Modify: docs/DEVICE_VERIFICATION_CHECKLIST.md

**Interfaces:**

```cpp
namespace RdpShutdownPolicy {
enum class Step { StopEventLoop, StopInputWorker, DisconnectTransport, CleanupInstance };
bool CanJoinWorkerWhileHoldingInstanceMutex(bool instanceMutexHeld);
bool ShouldReturnNapiBeforeCleanup(int64_t elapsedUs, bool rendererQuiesced);
}
```

- [ ] **Step 1: Add failing shutdown-order tests**

```cpp
RDP_TEST_CASE(rdp_shutdown_policy_never_joins_input_worker_while_instance_mutex_is_held) {
  RDP_ASSERT(!RdpShutdownPolicy::CanJoinWorkerWhileHoldingInstanceMutex(true));
  RDP_ASSERT(RdpShutdownPolicy::CanJoinWorkerWhileHoldingInstanceMutex(false));
}

RDP_TEST_CASE(rdp_shutdown_policy_returns_napi_after_renderer_is_quiesced) {
  RDP_ASSERT(RdpShutdownPolicy::ShouldReturnNapiBeforeCleanup(250000, true));
  RDP_ASSERT(!RdpShutdownPolicy::ShouldReturnNapiBeforeCleanup(250000, false));
}
```

- [ ] **Step 2: Add boundary logs without changing shutdown order**

Add monotonic-time logs at NAPI disconnect entry/return, input worker stop request/join completion, event-loop stop request/join completion, `freerdp_disconnect` begin/end, `cbPostDisconnect` begin/end, and renderer destruction. Every field must include session ID and elapsed microseconds; do not log host, user, password, clipboard, or input contents.

- [ ] **Step 3: Verify the deadlock with the smallest reproduction**

Connect RDP, generate continuous mouse motion plus keyboard events for 30 seconds, then disconnect while input is still arriving. Capture the shutdown trace. The pre-fix failure signature is: `freerdp_disconnect begin` and `PostDisconnect begin` appear, but `input worker joined` and NAPI return do not. Abort the test only through the system after preserving logs.

- [ ] **Step 4: Repair the lock inversion with one shutdown ordering change**

Stop and join the input worker before calling `disconnectActiveInstance()`. Change `disconnectActiveInstance()` to acquire `instanceMutex` only long enough to obtain a stable `freerdp*` pointer and mark the adapter disconnecting; release the mutex before `freerdp_abort_connect_context()` and `freerdp_disconnect()`. `cbPostDisconnect()` remains idempotent, so its second input-worker stop is a no-op. `cleanupInstance()` can run only after event loop, input worker, drive thread, and connect thread are stopped.

- [ ] **Step 5: Add a bounded asynchronous NAPI teardown only if the fixed synchronous path exceeds 250 ms**

If the Step 4 trace still has NAPI return later than 250 ms, replace synchronous `NapiDisconnect()` teardown with an adapter-owned shutdown task. The NAPI function must first quiesce presentation/input and return a `Disconnecting` state; it may erase the session only from the shutdown completion callback after `cleanupInstance()` completes. ArkTS must defer final renderer/audio handle disposal until that completion state. Do not introduce this task if the measured synchronous path meets the bound.

- [ ] **Step 6: Verify and commit before Task 0**

Run focused shutdown-policy tests, the native test suite where dependencies exist, `git diff --check`, production `assembleHap`, and the device stress matrix: 2 minutes idle, 2 minutes continuous input, shared-drive enabled/disabled, audio on/off, background restore then explicit disconnect, and ten repeated connects/disconnects. Expected: every trace ends in NAPI return and `FreeRDP session disconnected/cleaned`, with no UI stall or application crash.

```powershell
git commit -m "fix(rdp): prevent disconnect worker lock inversion"
```

### Task 0: Baseline and Evidence Gate

**Files:**
- Modify: docs/DEVICE_VERIFICATION_CHECKLIST.md
- Modify: this plan

**Produces:** logs/rdp-smoothness/baseline/<scenario>.log and comparison table with commit, host, device, resolution, refresh, timing, frame rate, and latency.

- [ ] **Step 1: Capture immutable source state**

Run:

~~~powershell
git status --short
git rev-parse HEAD
git submodule status
~~~

Expected: record SHA and dirty paths without reset, stash, or unrelated staging.

- [ ] **Step 2: Build the production baseline**

~~~powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
~~~

Expected: BUILD SUCCESSFUL. If it fails, record the failure and stop comparisons.

- [ ] **Step 3: Capture five foreground scenarios in both clients**
Use only foreground recordings. Background restore logs are not smoothness evidence. Record artifacts and measurements in the checklist.

- [ ] **Step 4: Commit documentation evidence**

~~~powershell
git add docs/DEVICE_VERIFICATION_CHECKLIST.md docs/superpowers/plans/2026-07-12-rdp-windows-app-smoothness.md
git commit -m "docs(rdp): record smoothness baseline"
~~~

### Task 1: Truthful Presentation Metrics

**Files:**
- Create: entry/src/main/cpp/rdp/rdp_presentation_metrics.h
- Create: entry/src/main/cpp/test/rdp_presentation_metrics_test.cpp
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp
- Modify: entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp
- Modify: entry/src/main/cpp/CMakeLists.txt

**Produces:**

~~~cpp
struct RdpPresentationSnapshot {
  uint64_t invalidEvents, invalidPixels, submittedFrames, submittedBytes;
  uint64_t replacedFrames, rejectedDetached;
  int64_t captureMaxUs, queueWaitMaxUs, renderMaxUs;
  int64_t uploadMaxUs, drawMaxUs, swapMaxUs;
};
RdpPresentationSnapshot snapshotAndReset();
~~~

- [ ] **Step 1: Write failing metric test**

~~~cpp
RDP_TEST_CASE(rdp_presentation_metrics_separates_damage_from_submission) {
  RdpPresentationMetrics m;
  m.recordInvalidRect(1920, 1080, 768, 128);
  m.recordSubmission(393216, 1200, false);
  const auto s = m.snapshotAndReset();
  RDP_ASSERT_EQ(s.invalidEvents, 1ULL);
  RDP_ASSERT_EQ(s.invalidPixels, 98304ULL);
  RDP_ASSERT_EQ(s.submittedBytes, 393216ULL);
  RDP_ASSERT_EQ(s.captureMaxUs, 1200LL);
}
~~~

- [ ] **Step 2: Run focused test and confirm failure**
Run the CODEWALK native-test command. If the known host OpenSSL archive blocks the suite, compile this self-contained unit only and record that full-suite evidence is blocked.

- [ ] **Step 3: Implement metric ownership**
Use a mutex-protected RdpPresentationMetrics. In cbEndPaint record invalid area before throttle; record submitted bytes only after an owned copy succeeds. Do not alter shared Render::VideoPerfCounters because RustDesk uses its current semantics.

- [ ] **Step 4: Instrument worker boundaries**
Record queue wait from owned-submission timestamp to worker dequeue and render duration around the worker callback. Emit one RDP-PRESENT snapshot per second. Do not infer RDP pressure from the current bytesTotal counter.

- [ ] **Step 5: Verify and commit**
Run focused tests, rdp_native_tests if dependencies exist, git diff --check, and assembleHap.

~~~powershell
git commit -m "feat(rdp): measure presentation pipeline truthfully"
~~~

### Task 2: Detached-Surface Presentation Gate

**Files:**
- Modify: entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp
- Modify: entry/src/main/cpp/render/gl_renderer.h/.cpp
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp
- Modify: entry/src/main/cpp/test/rdp_frame_pump_test.cpp

**Produces:**

~~~cpp
bool RendererNapi::HasReadyActiveRenderer();
void RdpFramePump::setPresentationEnabled(bool enabled);
bool RdpFramePump::submitLatest(const RdpFrameSubmission&);
~~~

- [ ] **Step 1: Write failing test**

~~~cpp
RDP_TEST_CASE(rdp_frame_pump_rejects_detached_submission) {
  RdpFramePump pump;
  pump.start();
  pump.setPresentationEnabled(false);
  const uint8_t pixel[4] = {0, 0, 0, 255};
  RDP_ASSERT(!pump.submitLatest(RdpFrameSubmission::Full(pixel, 4, 1, 1, 4)));
  RDP_ASSERT_EQ(pump.snapshotAndResetStats().rejectedDetached, 1ULL);
  pump.stop();
}
~~~

- [ ] **Step 2: Implement readiness query**

~~~cpp
bool RendererNapi::HasReadyActiveRenderer() {
  const int64_t handle = g_activeRendererHandle.load();
  const auto* ctx = reinterpret_cast<const RendererContext*>(handle);
  return handle > 0 && ctx && ctx->renderer && ctx->renderer->IsInitialized() &&
         !g_surfaceDetached;
}
~~~

- [ ] **Step 3: Gate ownership, not protocol traffic**
Set presentation false before existing destroyRendererOnly background detach. Re-enable only after new XComponent surface ID binding and renderer initialization. Keep RdpBackgroundFrameCache low-rate and independent.

- [ ] **Step 4: Remove delayed raw-buffer ownership**
Remove trailingFrameData, trailingFrameThread, and scheduleTrailingFrame. A worker cannot safely dereference mutable GDI memory after callback return.

- [ ] **Step 5: Verify Home -> recent-tasks restore and commit**
Expected: presentationEnabled=false, no repeated skipped raw rendering, then a full resync after re-enable.

~~~powershell
git commit -m "fix(rdp): stop frame presentation on detached surfaces"
~~~

### Task 3: Owned Damage Accumulator

**Files:**
- Create: entry/src/main/cpp/rdp/rdp_damage_policy.h
- Create: entry/src/main/cpp/test/rdp_damage_policy_test.cpp
- Modify: entry/src/main/cpp/rdp/rdp_render_policy.h
- Modify: entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp
- Modify: entry/src/main/cpp/test/rdp_render_policy_test.cpp

**Produces:**

~~~cpp
namespace RdpDamagePolicy {
struct Rect { int x, y, width, height; bool valid; };
Rect Union(Rect a, Rect b, int frameWidth, int frameHeight);
bool ShouldUseDamage(const Rect&, int64_t fullBytes);
bool RequiresFullResync(bool sizeChanged, bool textureUnknown, bool pendingFull);
}
bool RdpFramePump::submitDamage(const uint8_t* primary, int width, int height,
                                int stride, RdpDamagePolicy::Rect dirty, bool forceFull);
~~~

- [ ] **Step 1: Write failing policy tests**

~~~cpp
RDP_TEST_CASE(rdp_damage_policy_unions_replaced_dirty_updates) {
  const auto a = RdpDamagePolicy::Rect::Valid(100, 100, 40, 40);
  const auto b = RdpDamagePolicy::Rect::Valid(160, 120, 40, 20);
  const auto u = RdpDamagePolicy::Union(a, b, 1920, 1080);
  RDP_ASSERT(u.valid);
  RDP_ASSERT_EQ(u.x, 100);
  RDP_ASSERT_EQ(u.width, 100);
}
RDP_TEST_CASE(rdp_damage_policy_requires_full_after_resize) {
  RDP_ASSERT(RdpDamagePolicy::RequiresFullResync(true, false, false));
}
~~~

- [ ] **Step 2: Implement exact safety rules**

~~~cpp
inline bool ShouldUseDamage(const Rect& r, int64_t fullBytes) {
  return r.valid && r.areaBytes() * 100LL < fullBytes * 70LL;
}
inline bool RequiresFullResync(bool sizeChanged, bool textureUnknown, bool pendingFull) {
  return sizeChanged || textureUnknown || pendingFull;
}
~~~

- [ ] **Step 3: Implement owned accumulation**
After first full frame allocate an owned full-size staging surface. In every GDI EndPaint copy only dirty rows into it and union pending rectangles. The worker copies compact union data from owned staging memory into its render buffer. Initial frame, resize, reattach, invalid bounds, allocation failure, or union >=70% requires full copy/resync.

- [ ] **Step 4: Enable safe dirty presentation**
Replace kEnableDirtyRectUploads=false with policy result. Preserve first three direct frames and every resync as full. Retain GL_UNPACK_ROW_LENGTH reset for original-stride direct and tight-stride worker rects.

- [ ] **Step 5: Run visual matrix and commit**
Test browser scroll, moving/resizing window, remote minimize/restore, Home/restore, remote resize, and rapid input.

~~~powershell
git commit -m "perf(rdp): coalesce owned dirty frame updates"
~~~

### Task 4: Measured Worker Scheduling

**Files:**
- Modify: entry/src/main/cpp/rdp/rdp_frame_pump.h/.cpp
- Modify: entry/src/main/cpp/render/gl_renderer.h/.cpp
- Modify: entry/src/main/cpp/test/rdp_frame_pump_test.cpp

**Produces:**

~~~cpp
struct RawBgraPresentMetrics {
  int status = -1;
  int64_t uploadUs = 0, drawUs = 0, swapUs = 0;
};
using RenderCallback = RawBgraPresentMetrics (*)(const RdpFrameView&, void*);
~~~

- [ ] **Step 1: Write deterministic worker test**
Use an injected fake RenderCallback. Submit A then B while A is blocked; release one callback and assert B renders, replacements=1, and queueWaitMaxUs is recorded.

- [ ] **Step 2: Return real GL timings**
Have RenderRawBGRAInternal populate metrics after glTexSubImage2D, drawing, and eglSwapBuffers. Return status=-1 before EGL work. Do not change swap interval here.

- [ ] **Step 3: Schedule only in worker**
The protocol callback must never wait for EGL. Adapt min interval from worker upload+swap within 16667..50000 us. Decay only after 120 consecutive low-cost presents. Rejected/failed frames never count as slow.

- [ ] **Step 4: Verify and commit**

~~~powershell
git commit -m "perf(rdp): schedule presentation from worker metrics"
~~~

### Task 5: GLES Pixel-Unpack-Buffer Experiment

**Files:**
- Create: entry/src/main/cpp/render/raw_bgra_upload_policy.h
- Create: entry/src/main/cpp/test/raw_bgra_upload_policy_test.cpp
- Modify: entry/src/main/cpp/render/gl_renderer.cpp
- Modify: entry/src/main/cpp/CMakeLists.txt

**Produces:**

~~~cpp
enum class RawBgraUploadMode { Direct, PixelUnpackBuffer };
RawBgraUploadMode Select(bool pboSupported, bool p95TransferDominates);
~~~

- [ ] **Step 1: Apply go/no-go gate**
Proceed only if Task 4 shows uploadUs+swapUs >=60% of P95 worker time and all damage visual tests pass. Otherwise mark not-needed in the checklist and make no renderer change.

- [ ] **Step 2: Write failing capability test**

~~~cpp
RDP_TEST_CASE(raw_upload_policy_requires_capability_and_bottleneck) {
  RDP_ASSERT_EQ(Select(true, true), RawBgraUploadMode::PixelUnpackBuffer);
  RDP_ASSERT_EQ(Select(false, true), RawBgraUploadMode::Direct);
}
~~~

- [ ] **Step 3: Prototype three PBOs behind experiment mode**
Map next GL_PIXEL_UNPACK_BUFFER, copy owned compact bytes, unmap, use offset zero in glTexSubImage2D, rotate. On any GL error disable PBO for the session and present the same frame through Direct.

- [ ] **Step 4: Keep only a measurable win**
Keep PBO only if it improves foreground P95 worker time >=15% with no GL errors or visual regression.

~~~powershell
git commit -m "perf(render): evaluate asynchronous raw upload"
~~~

### Task 6: RDPGFX ResetGraphics/DesktopResize Gate

**Files:**
- Modify: entry/src/main/cpp/rdp/freerdp_adapter.cpp
- Modify: entry/src/main/cpp/rdp/rdp_performance_policy.h
- Modify: entry/src/main/cpp/test/rdp_performance_policy_test.cpp
- Modify: entry/src/main/cpp/test/rdp_render_policy_test.cpp

**Produces:**

~~~cpp
BOOL FreeRdpAdapter::cbDesktopResize(rdpContext*);
bool rdpGfxResetPathSafe();
~~~

- [ ] **Step 1: Write failing capability test**

~~~cpp
RDP_TEST_CASE(rdp_performance_policy_advertises_gfx_after_safe_resize_consumer) {
  const auto s = RdpPerformancePolicy::RecommendedLanSettings(true, true, true, true);
  RDP_ASSERT(s.supportGraphicsPipeline);
  RDP_ASSERT(s.remoteFxCodec);
  RDP_ASSERT(s.gfxH264);
}
~~~

- [ ] **Step 2: Implement DesktopResize before enabling GFX**
Register update->DesktopResize beside BeginPaint/EndPaint. Validate GDI dimensions, invalidate pump staging, force next full frame, call RendererNapi::SetActiveSourceSize, and return FALSE with parseable RDP error on invalid state.

- [ ] **Step 3: Preserve channel lifecycle**
Keep gdi_graphics_pipeline_init/uninit for RDPGFX_DVC_CHANNEL_NAME. Track channel connection plus successful DesktopResize. Do not mark safe merely because channel compiled or connected.

- [ ] **Step 4: Run GFX matrix**
For GDI, GFX, and GFX-H264 when offered: connect, remote resize, resolution change, Home/restore, reconnect, and 10-minute scroll/video. Any WINPR_ASSERT, missing frame, stale texture, or ErrorInfo keeps release default at GDI.

- [ ] **Step 5: Commit**

~~~powershell
git commit -m "feat(rdp): gate graphics pipeline on resize safety"
~~~

### Task 7: Direct Hardware Output Feasibility Spike

**Files:**
- Create: docs/superpowers/specs/2026-07-12-rdp-gfx-hardware-output-spike.md
- Create: entry/src/main/cpp/rdp/rdpgfx_output_policy.h
- Create: entry/src/main/cpp/test/rdpgfx_output_policy_test.cpp
- Modify: entry/src/main/cpp/CMakeLists.txt

**Produces:**

~~~cpp
bool RdpgfxOutputPolicy::UseHardwareOutput(bool codecSupported,
                                           bool surfaceAttached,
                                           bool validatedDevice);
~~~

- [ ] **Step 1: Document API 23 evidence**
Record OH_AVCodec/OH_NativeImage signatures, AVC420 ownership, resize, flush/recreate, attached/detached behavior, and why GDI primary buffer cannot be zero-copy.

- [ ] **Step 2: Write disabled-by-default policy test**

~~~cpp
RDP_TEST_CASE(rdpgfx_output_policy_requires_all_gates) {
  RDP_ASSERT(!UseHardwareOutput(true, true, false));
  RDP_ASSERT(!UseHardwareOutput(true, false, true));
  RDP_ASSERT(UseHardwareOutput(true, true, true));
}
~~~

- [ ] **Step 3: Build isolated lifecycle proof**
Compile create->configure AVC420->start->flush->stop->destroy without wiring FreeRDP presentation. Reject AVC444 in this spike. No public quality toggle.

- [ ] **Step 4: Gate separate production plan**
Create a hardware renderer plan only if it yields GPU texture output, clean detach/reattach, and >=30% lower P95 presentation time than verified GDI/RDPGFX. Otherwise commit negative evidence and keep GDI-damage.

~~~powershell
git commit -m "docs(rdp): evaluate hardware graphics output"
~~~

### Task 8: Final Regression, Comparison, and Handoff

**Files:**
- Modify: docs/DEVICE_VERIFICATION_CHECKLIST.md
- Modify: C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md
- Modify: C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md
- Modify: C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
- Modify: C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md only after full device evidence.

**Produces:** one release decision: GDI-damage, GDI-damage+PBO, RDPGFX, or RDPGFX-H264 with artifact paths and fallback.

- [ ] **Step 1: Run full RDP regression**
Validate login modes, certificate paths, ErrorInfo/no-frame, input, rdpsnd, clipboard, shared-drive gate, restore, and remote resolution changes.

- [ ] **Step 2: Repeat five-client comparison**
Record effective presentation rate, P50/P95 queue wait, P50/P95 worker time, P95 input latency, submitted bytes, replacement count, GL errors, and visual verdict.

- [ ] **Step 3: Ship by evidence**
Ship highest mode satisfying acceptance and regression. If it fails, retain diagnostics and plan against largest measured bottleneck, not a generic rewrite.

- [ ] **Step 4: Final build, commit, and exchange-state update**
Run focused/native tests, assembleHap, git diff --check, install signed HAP, attach artifacts, update exchange state, then commit only plan-owned changes.

~~~powershell
git commit -m "perf(rdp): verify smoothness release candidate"
~~~

## Review Gates

- Review Task 1 before using metrics for control decisions.
- Review Task 2 before Task 3 so detached work cannot distort results.
- Device-review Task 3 before changing scheduling in Task 4.
- Task 5 is optional and numeric-gated.
- Task 6 must not block shipping verified GDI-damage.
- Task 7 requires a separate approved production plan before touching the renderer.

## Plan Self-Review

- Coverage: baseline, metrics, detached work, owned damage, scheduling, GLES transfer, GFX safety, hardware feasibility, regression, and release evidence all map to tasks.
- Scope: verified GDI-damage is independently shippable.
- Consistency: SoftwareGdi and GDI fallback remain active until later gated work proves otherwise.
- No user-visible quality setting is added; promotion is evidence-driven.
