# RDP/RustDesk Video Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RDP and RustDesk video streaming measurable, recoverable, and faster under long-running high-motion sessions without regressing the currently working connection/audio/input paths.

**Architecture:** Treat RDP and RustDesk as separate video pipelines sharing one renderer/decoder substrate. First add telemetry and real refresh/pressure interfaces, then make renderer detach safe, then decouple RDP protocol receiving from GL rendering, and finally drive RustDesk stream downgrade/recovery from local decoder/render pressure instead of guessed inbound frame cadence.

**Tech Stack:** ArkTS/ArkUI API 23, NAPI C++17, FreeRDP 3.x, RustDesk Rust FFI, OH_AVCodec, FFmpeg soft decode fallback, OpenGL ES 3.0/EGL, hvigor/DevEco.

## Global Constraints

- Do not revert or overwrite pre-existing dirty worktree changes; current dirty files include RustDesk/Rust FFI files and `freerdp` submodule state.
- Preserve RDP stable startup rules from `CODEWALK.md`: no ArkTS TCP preflight, initial `setXComponentSurfaceId()`/`initRenderer()` uses remote desktop size, real surface resize happens after renderer creation.
- Preserve FreeRDP channel ordering and rdpsnd/rdpdr stability; optional channels must not decide desktop readiness.
- RustDesk FFI source changes require rebuilding both static libraries before HAP build:
  - `cargo +stable-x86_64-pc-windows-gnu build --release --target aarch64-unknown-linux-ohos`
  - `cargo +stable-x86_64-pc-windows-gnu build --release --target x86_64-unknown-linux-ohos`
- After RustDesk FFI changes, verify the linked `librdpnapi.so` contains the new log marker before device install.
- Every code commit must follow a successful build. Known ohosTest target is blocked by existing HostListPage test-target parser/sourcemap issue; use native unit tests, Rust checks, and `assembleHap` as the practical verification path.
- Keep each task independently commit-sized. Do not combine telemetry, lifecycle, RDP queueing, and RustDesk backpressure in one commit.

---

## File Structure

Create:
- `entry/src/main/cpp/render/video_perf_counters.h` - pure C++ counters and pressure-level policy for ingress/decode/render metrics.
- `entry/src/main/cpp/render/video_perf_counters.cpp` - implementation of snapshot/reset and pressure calculation.
- `entry/src/main/cpp/test/video_perf_counters_test.cpp` - native unit tests for pressure levels and reset behavior.
- `entry/src/main/cpp/rdp/rdp_frame_pump.h` - RDP render worker interface that accepts latest BGRA frames from FreeRDP GDI.
- `entry/src/main/cpp/rdp/rdp_frame_pump.cpp` - worker thread implementation that renders only the newest pending frame.

Modify:
- `entry/src/main/cpp/CMakeLists.txt` - include new C++ files and native tests.
- `entry/src/main/cpp/extensions/protocol_adapter.h` - keep `requestFrameRefresh()` virtual and add a low-impact `reportVideoPressure(int level)` hook.
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp` - record RustDesk ingress/decode results and route pressure to active adapters.
- `entry/src/main/cpp/rdp/freerdp_adapter.h` / `entry/src/main/cpp/rdp/freerdp_adapter.cpp` - implement RDP refresh, frame pump, and RDP telemetry.
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.h` / `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp` - implement RustDesk refresh and pressure reporting bridge.
- `entry/src/main/cpp/render/hw_decoder.h` / `entry/src/main/cpp/render/hw_decoder.cpp` - expose detach/rebind-safe decoder pipeline controls and active pressure snapshot.
- `entry/src/main/cpp/render/software_decoder.h` / `entry/src/main/cpp/render/software_decoder.cpp` - support clearing the render callback on detach.
- `entry/src/main/cpp/render/gl_renderer.cpp` - add telemetry only; keep existing detach protections.
- `entry/src/main/ets/services/ExtensionLoader.ets` - expose `detachVideoPipelineForBackground()` if native NAPI is added.
- `entry/src/main/ets/services/NativeSessionHandles.ets` - call decoder detach before renderer destroy, without destroying decoder/protocol.
- `entry/src/main/ets/pages/RemoteDesktop.ets` - use the safe detach/rebind sequence and keep existing background registry behavior.
- `rustdesk_ffi/src/lib.rs` - add control message/reporting APIs for refresh and pressure.
- `rustdesk_ffi/src/connector.rs` - consume pressure control messages and send runtime option changes with hysteresis.
- `rustdesk_ffi/src/protocol/session.rs` - reuse existing `send_refresh_video()` and `send_runtime_options()` helpers.

---

## Task 0: Worktree and Baseline Gate

**Files:**
- Read only: current repository.

**Interfaces:**
- Consumes: current dirty worktree and latest device/build state.
- Produces: a clean execution decision: either continue on current branch with user-approved dirty changes, or create/ask for an isolated branch/worktree before code edits.

- [ ] **Step 1: Capture current status**

Run:

```powershell
git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop status --short
git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop log -5 --oneline
```

Expected:
- Dirty RustDesk/Rust FFI files are visible.
- `freerdp` submodule may remain dirty and must not be reverted.

- [ ] **Step 2: Confirm dirty RustDesk edits are in scope**

If dirty RustDesk edits are user work, keep them and build on top. If they are abandoned experiments, ask the user before reverting or moving them. Do not use `git reset --hard`.

- [ ] **Step 3: Record baseline log markers**

Use the existing capture pattern from `HANDOFF.md` and include these patterns:

```powershell
$pattern = 'RDP] GDI EndPaint|GL] RenderRawBGRA|Decoder]|SoftDecoder]|RustDesk-FFI] stream window|video cadence gap|video_received ack|BACKPRESSURE|requestFrameRefresh|detachForBackground|doBackgroundRestoreRender'
```

Expected baseline evidence:
- RDP: paint/render/swap costs appear.
- RustDesk: inbound window counts, decoder queue logs, and codec/fps marker appear.

- [ ] **Step 4: Commit state only if this task creates documentation**

This task should not create code. If a baseline note is added, commit only that note after `git diff --check`.

---

## Task 1: Native Video Telemetry Counters

**Files:**
- Create: `entry/src/main/cpp/render/video_perf_counters.h`
- Create: `entry/src/main/cpp/render/video_perf_counters.cpp`
- Create: `entry/src/main/cpp/test/video_perf_counters_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Consumes: no production pipeline state.
- Produces:
  - `Render::VideoPerfCounters`
  - `Render::VideoPerfSnapshot`
  - `Render::VideoPressureLevel`
  - `Render::classifyVideoPressure(const VideoPerfSnapshot&)`

- [ ] **Step 1: Add the failing native test**

Add `entry/src/main/cpp/test/video_perf_counters_test.cpp`:

```cpp
#include "render/video_perf_counters.h"
#include <iostream>

static int failures = 0;

static void expectTrue(bool value, const char* message) {
    if (!value) {
        std::cerr << "FAIL: " << message << std::endl;
        failures++;
    }
}

int runVideoPerfCountersTests() {
    Render::VideoPerfCounters counters;
    counters.recordIngressFrame("rustdesk", 1600, 900, 12000, true);
    counters.recordDecodeResult(0, 2, 1, 0);
    counters.recordRenderCostUs(6000, 3000, 2000, 11000);

    Render::VideoPerfSnapshot good = counters.snapshotAndReset();
    expectTrue(good.ingressFrames == 1, "ingress frame counted");
    expectTrue(good.decodeOk == 1, "decode ok counted");
    expectTrue(Render::classifyVideoPressure(good) == Render::VideoPressureLevel::Normal,
        "good frame is normal pressure");

    Render::VideoPerfSnapshot empty = counters.snapshotAndReset();
    expectTrue(empty.ingressFrames == 0, "snapshot reset clears ingress");

    Render::VideoPerfSnapshot bad {};
    bad.ingressFrames = 60;
    bad.decodeQueueMax = 14;
    bad.decodeDrops = 20;
    bad.renderTotalMaxUs = 42000;
    expectTrue(Render::classifyVideoPressure(bad) == Render::VideoPressureLevel::Severe,
        "large queue/drop/render cost is severe");

    return failures == 0 ? 0 : 1;
}
```

- [ ] **Step 2: Register the native test**

Modify `entry/src/main/cpp/test/test_main.cpp` to declare and call the new test:

```cpp
int runVideoPerfCountersTests();

int main() {
    int failures = 0;
    failures += runPerfTests();
    failures += runVideoBackpressureTests();
    failures += runVideoPerfCountersTests();
    return failures == 0 ? 0 : 1;
}
```

If `test_main.cpp` currently has different function names, preserve existing calls and add only `runVideoPerfCountersTests()`.

- [ ] **Step 3: Verify test fails before implementation**

Run:

```powershell
cmake -S entry/src/main/cpp -B C:\tmp\rdp-native-tests -DRDP_BUILD_TESTS=ON
cmake --build C:\tmp\rdp-native-tests
```

Expected: compile fails because `render/video_perf_counters.h` does not exist.

- [ ] **Step 4: Implement telemetry types**

Create `entry/src/main/cpp/render/video_perf_counters.h`:

```cpp
#ifndef VIDEO_PERF_COUNTERS_H
#define VIDEO_PERF_COUNTERS_H

#include <cstdint>
#include <cstddef>
#include <mutex>
#include <string>

namespace Render {

enum class VideoPressureLevel {
    Normal = 0,
    Mild = 1,
    Moderate = 2,
    Severe = 3,
};

struct VideoPerfSnapshot {
    std::string source;
    uint64_t ingressFrames = 0;
    uint64_t decodeOk = 0;
    uint64_t decodeNotReady = 0;
    uint64_t decodeDrops = 0;
    uint64_t decodeMismatch = 0;
    uint64_t renderFrames = 0;
    uint64_t keyframes = 0;
    size_t decodeQueueMax = 0;
    int width = 0;
    int height = 0;
    uint64_t bytesTotal = 0;
    int64_t uploadMaxUs = 0;
    int64_t drawMaxUs = 0;
    int64_t swapMaxUs = 0;
    int64_t renderTotalMaxUs = 0;
};

class VideoPerfCounters {
public:
    void recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe);
    void recordDecodeResult(int ret, size_t queueDepth, uint64_t dropped, uint64_t waitDrops);
    void recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs);
    VideoPerfSnapshot snapshotAndReset();

private:
    std::mutex mutex_;
    VideoPerfSnapshot current_;
};

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot);
const char* videoPressureName(VideoPressureLevel level);

} // namespace Render

#endif // VIDEO_PERF_COUNTERS_H
```

Create `entry/src/main/cpp/render/video_perf_counters.cpp`:

```cpp
#include "video_perf_counters.h"
#include <algorithm>

namespace Render {

void VideoPerfCounters::recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.source = source ? source : "";
    current_.ingressFrames++;
    current_.width = width;
    current_.height = height;
    current_.bytesTotal += bytes;
    if (keyframe) {
        current_.keyframes++;
    }
}

void VideoPerfCounters::recordDecodeResult(int ret, size_t queueDepth, uint64_t dropped, uint64_t waitDrops) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.decodeQueueMax = std::max(current_.decodeQueueMax, queueDepth);
    current_.decodeDrops = std::max(current_.decodeDrops, dropped + waitDrops);
    if (ret == 0) {
        current_.decodeOk++;
    } else if (ret == -1) {
        current_.decodeNotReady++;
    } else if (ret == -3) {
        current_.decodeMismatch++;
    }
}

void VideoPerfCounters::recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.renderFrames++;
    current_.uploadMaxUs = std::max(current_.uploadMaxUs, uploadUs);
    current_.drawMaxUs = std::max(current_.drawMaxUs, drawUs);
    current_.swapMaxUs = std::max(current_.swapMaxUs, swapUs);
    current_.renderTotalMaxUs = std::max(current_.renderTotalMaxUs, totalUs);
}

VideoPerfSnapshot VideoPerfCounters::snapshotAndReset() {
    std::lock_guard<std::mutex> lock(mutex_);
    VideoPerfSnapshot out = current_;
    current_ = VideoPerfSnapshot {};
    return out;
}

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot) {
    if (snapshot.decodeQueueMax >= 12 || snapshot.decodeDrops >= 10 || snapshot.renderTotalMaxUs >= 40000) {
        return VideoPressureLevel::Severe;
    }
    if (snapshot.decodeQueueMax >= 8 || snapshot.decodeDrops >= 4 || snapshot.renderTotalMaxUs >= 28000) {
        return VideoPressureLevel::Moderate;
    }
    if (snapshot.decodeQueueMax >= 4 || snapshot.renderTotalMaxUs >= 18000 || snapshot.swapMaxUs >= 16000) {
        return VideoPressureLevel::Mild;
    }
    return VideoPressureLevel::Normal;
}

const char* videoPressureName(VideoPressureLevel level) {
    switch (level) {
        case VideoPressureLevel::Mild: return "mild";
        case VideoPressureLevel::Moderate: return "moderate";
        case VideoPressureLevel::Severe: return "severe";
        case VideoPressureLevel::Normal:
        default: return "normal";
    }
}

} // namespace Render
```

- [ ] **Step 5: Wire the new files into native tests**

Modify `entry/src/main/cpp/CMakeLists.txt`:

```cmake
set(RENDER_SOURCES
    render/gl_renderer.cpp
    render/hw_decoder.cpp
    render/software_decoder.cpp
    render/video_backpressure_controller.cpp
    render/video_perf_counters.cpp
)

if(RDP_BUILD_TESTS)
    add_executable(rdp_native_tests
        test/test_main.cpp
        test/perf_test.cpp
        test/video_backpressure_test.cpp
        test/video_perf_counters_test.cpp
        render/video_backpressure_controller.cpp
        render/video_perf_counters.cpp
    )
endif()
```

- [ ] **Step 6: Run native tests**

Run:

```powershell
cmake -S entry/src/main/cpp -B C:\tmp\rdp-native-tests -DRDP_BUILD_TESTS=ON
cmake --build C:\tmp\rdp-native-tests
C:\tmp\rdp-native-tests\rdp_native_tests.exe
```

Expected: native tests pass.

- [ ] **Step 7: Commit**

```powershell
git diff --check
git add entry/src/main/cpp/render/video_perf_counters.h entry/src/main/cpp/render/video_perf_counters.cpp entry/src/main/cpp/test/video_perf_counters_test.cpp entry/src/main/cpp/CMakeLists.txt entry/src/main/cpp/test/test_main.cpp
git commit -m "test(render): add video performance counters"
```

---

## Task 2: Telemetry Integration Without Behavior Changes

**Files:**
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/render/hw_decoder.cpp`
- Modify: `entry/src/main/cpp/render/gl_renderer.cpp`

**Interfaces:**
- Consumes: `Render::VideoPerfCounters`.
- Produces: one-second logs for RDP/RustDesk ingress, decode, queue, render, and pressure level.

- [ ] **Step 1: Add global counters**

In `extension_loader_napi.cpp`, include:

```cpp
#include "render/video_perf_counters.h"
```

Add near existing globals:

```cpp
static Render::VideoPerfCounters g_rustdeskVideoPerf;
```

In `freerdp_adapter.cpp`, include:

```cpp
#include "render/video_perf_counters.h"
```

Add inside the real FreeRDP implementation namespace:

```cpp
static Render::VideoPerfCounters g_rdpVideoPerf;
```

- [ ] **Step 2: Record RustDesk ingress/decode**

In the `adapter->setVideoCallback` lambda in `extension_loader_napi.cpp`, before `DecodeActiveNative(frame)`:

```cpp
g_rustdeskVideoPerf.recordIngressFrame("rustdesk", frame.width, frame.height, frame.size, frame.isKeyFrame);
```

After the decode result:

```cpp
g_rustdeskVideoPerf.recordDecodeResult(ret, 0, 0, 0);
```

Every 300 frames or ret != 0, append pressure:

```cpp
Render::VideoPerfSnapshot snap = g_rustdeskVideoPerf.snapshotAndReset();
Render::VideoPressureLevel pressure = Render::classifyVideoPressure(snap);
OH_LOG_INFO(LOG_APP,
    "[Perf][RustDesk] ingress=%{public}llu decodeOk=%{public}llu notReady=%{public}llu mismatch=%{public}llu render=%{public}llu pressure=%{public}s size=%{public}dx%{public}d bytes=%{public}llu",
    static_cast<unsigned long long>(snap.ingressFrames),
    static_cast<unsigned long long>(snap.decodeOk),
    static_cast<unsigned long long>(snap.decodeNotReady),
    static_cast<unsigned long long>(snap.decodeMismatch),
    static_cast<unsigned long long>(snap.renderFrames),
    Render::videoPressureName(pressure),
    snap.width,
    snap.height,
    static_cast<unsigned long long>(snap.bytesTotal));
```

- [ ] **Step 3: Record RDP paint/render costs**

In `FreeRdpAdapter::cbEndPaint`, before render:

```cpp
g_rdpVideoPerf.recordIngressFrame("rdp", w, h, size, true);
```

After `renderCostUs` is known:

```cpp
g_rdpVideoPerf.recordRenderCostUs(0, 0, 0, renderCostUs);
```

In the existing one-second diagnostic block, add:

```cpp
Render::VideoPerfSnapshot snap = g_rdpVideoPerf.snapshotAndReset();
Render::VideoPressureLevel pressure = Render::classifyVideoPressure(snap);
OH_LOG_INFO(LOG_APP,
    "[Perf][RDP] paints=%{public}llu rendered=%{public}llu pressure=%{public}s maxRender=%{public}lldus size=%{public}dx%{public}d bytes=%{public}llu",
    static_cast<unsigned long long>(snap.ingressFrames),
    static_cast<unsigned long long>(snap.renderFrames),
    Render::videoPressureName(pressure),
    static_cast<long long>(snap.renderTotalMaxUs),
    snap.width,
    snap.height,
    static_cast<unsigned long long>(snap.bytesTotal));
```

- [ ] **Step 4: Record GL costs for RustDesk soft decode path**

In `gl_renderer.cpp`, include `video_perf_counters.h` only if a shared global is exposed through a small accessor. If that creates circular ownership, keep GL logs unchanged in this task and rely on existing `RenderRawBGRA` upload/draw/swap logs.

- [ ] **Step 5: Build**

Run:

```powershell
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/render/hw_decoder.cpp entry/src/main/cpp/render/gl_renderer.cpp
git commit -m "feat(render): add video pipeline telemetry"
```

---

## Task 3: Real Frame Refresh for RDP and RustDesk

**Files:**
- Modify: `entry/src/main/cpp/extensions/protocol_adapter.h`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Modify: `rustdesk_ffi/src/lib.rs`

**Interfaces:**
- Consumes: `ExtensionLoader.requestFrameRefresh()`.
- Produces:
  - `FreeRdpAdapter::requestFrameRefresh()`
  - `RustDeskBridge::requestFrameRefresh()`
  - `rustdesk_request_frame_refresh(handle: *mut c_void) -> bool`
  - `ControlMsg::RefreshVideo`

- [ ] **Step 1: Extend Rust control messages**

In `rustdesk_ffi/src/lib.rs`, add:

```rust
pub(crate) enum ControlMsg {
    Shutdown,
    RefreshVideo,
    KeyEvent { scancode: u32, pressed: bool },
    MouseEvent { x: i32, y: i32, button: u32, pressed: bool },
    MouseMove { x: i32, y: i32 },
    MouseWheel { x: i32, y: i32, delta: i32 },
    Text { text: String },
    SendFile { remote_path: String, data: Vec<u8> },
    Clipboard { content: Vec<u8> },
}
```

Add FFI export near other send functions:

```rust
#[no_mangle]
pub extern "C" fn rustdesk_request_frame_refresh(handle: *mut c_void) -> bool {
    if handle.is_null() {
        set_last_error("rustdesk_request_frame_refresh null handle");
        return false;
    }
    let client = unsafe { &*(handle as *mut RustDeskClient) };
    match client.tx.send(ControlMsg::RefreshVideo) {
        Ok(()) => {
            set_last_error("rustdesk_request_frame_refresh enqueued");
            true
        }
        Err(err) => {
            set_last_error(format!("rustdesk_request_frame_refresh enqueue failed: {}", err));
            false
        }
    }
}
```

- [ ] **Step 2: Consume refresh in the Rust streaming loop**

In `rustdesk_ffi/src/connector.rs`, inside the control message loop:

```rust
ControlMsg::RefreshVideo => {
    if let Err(err) = Session::send_refresh_video(crypto) {
        eprintln!("[RustDesk-FFI] streaming: refresh_video control failed: {}", err);
    } else {
        eprintln!("[RustDesk-FFI] streaming: refresh_video control sent");
    }
}
```

- [ ] **Step 3: Add C++ RustDesk extern and override**

In `rustdesk_bridge.cpp` extern block:

```cpp
bool rustdesk_request_frame_refresh(void* handle);
```

In `rustdesk_bridge.h`, add public override:

```cpp
void requestFrameRefresh() override;
```

In `rustdesk_bridge.cpp`:

```cpp
void RustDeskBridge::requestFrameRefresh() {
#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiHandle = impl_->ffiHandle;
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        const bool ok = rustdesk_request_frame_refresh(ffiHandle);
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] requestFrameRefresh sent=%{public}s", ok ? "yes" : "no");
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk] requestFrameRefresh skipped: no FFI session");
}
```

- [ ] **Step 4: Add RDP refresh override**

In `freerdp_adapter.h`, add:

```cpp
void requestFrameRefresh() override;
```

In `freerdp_adapter.cpp`, implement a conservative first version:

```cpp
void FreeRdpAdapter::requestFrameRefresh() {
#ifdef USE_REAL_FREERDP
    if (!instance_ || !instance_->context) {
        OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: no context");
        return;
    }
    std::lock_guard<std::mutex> renderLock(impl_->renderMutex);
    if (instance_->context->gdi && instance_->context->gdi->primary_buffer) {
        const int w = static_cast<int>(freerdp_settings_get_uint32(instance_->settings, FreeRDP_DesktopWidth));
        const int h = static_cast<int>(freerdp_settings_get_uint32(instance_->settings, FreeRDP_DesktopHeight));
        const int stride = w * 4;
        const size_t size = static_cast<size_t>(stride) * static_cast<size_t>(h);
        const int ret = RendererNapi::RenderRawBgraActive(instance_->context->gdi->primary_buffer, size, w, h, stride);
        OH_LOG_INFO(LOG_APP, "[RDP] requestFrameRefresh rendered current primary ret=%{public}d size=%{public}dx%{public}d", ret, w, h);
    } else {
        OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: no GDI primary buffer");
    }
#else
    OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: skeleton mode");
#endif
}
```

- [ ] **Step 5: Build Rust FFI and HAP**

Run:

```powershell
cd C:\Users\14288\DevEcoStudioProjects\RemoteDesktop\rustdesk_ffi
cargo +stable-x86_64-pc-windows-gnu build --release --target aarch64-unknown-linux-ohos
cargo +stable-x86_64-pc-windows-gnu build --release --target x86_64-unknown-linux-ohos
cd C:\Users\14288\DevEcoStudioProjects\RemoteDesktop
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected:
- Rust builds pass.
- HAP build is `BUILD SUCCESSFUL`.

- [ ] **Step 6: Verify linked marker**

Run:

```powershell
Select-String -Path entry\.cxx\default\default\*\*\libs\librdpnapi.so -Pattern "requestFrameRefresh" -SimpleMatch
```

Expected: output contains the new RustDesk or RDP refresh log string in linked native libraries.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/rdp/freerdp_adapter.h entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/rustdesk/rustdesk_bridge.h entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "feat(remote): implement frame refresh requests"
```

---

## Task 4: Decoder Pipeline Detach Without Protocol Disconnect

**Files:**
- Modify: `entry/src/main/cpp/render/hw_decoder.h`
- Modify: `entry/src/main/cpp/render/hw_decoder.cpp`
- Modify: `entry/src/main/cpp/render/software_decoder.h`
- Modify: `entry/src/main/cpp/render/software_decoder.cpp`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/ets/services/NativeSessionHandles.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes: existing `detachForBackground()` and `bindVideoPipeline()`.
- Produces:
  - `rdpnapi.detachVideoPipeline(handle: number): void`
  - `ExtensionLoader.detachVideoPipelineForBackground(): void`
  - Native decoder remains alive but stops rendering to old renderer.

- [ ] **Step 1: Add native decoder detach API**

In `hw_decoder.h`, add:

```cpp
void StopRenderThreadForDetach();
```

In `HardwareDecoder` public section, implement through existing private `stopRenderThread()`:

```cpp
void HardwareDecoder::StopRenderThreadForDetach() {
    stopRenderThread();
    SetFrameCallback(nullptr);
    SetMakeCurrentCallback(nullptr);
    SetReleaseCurrentCallback(nullptr);
}
```

If the setters do not accept `nullptr` cleanly, update their callback typedef storage to allow empty `std::function`.

- [ ] **Step 2: Add software decoder callback clear**

In `software_decoder.h`, ensure:

```cpp
void SetFrameCallback(SoftwareDecoderFrameCallback callback);
```

In `software_decoder.cpp`, existing setter should accept an empty callback:

```cpp
void SoftwareDecoder::SetFrameCallback(SoftwareDecoderFrameCallback callback) {
    frameCallback_ = std::move(callback);
}
```

- [ ] **Step 3: Add NAPI detach function**

In `hw_decoder.cpp`, add:

```cpp
napi_value NapiDetachVideoPipeline(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handleVal = 0;
    napi_get_value_int64(env, args[0], &handleVal);
    auto* ctx = reinterpret_cast<DecoderContext*>(handleVal);
    if (ctx) {
        if (ctx->decoder) {
            ctx->decoder->StopRenderThreadForDetach();
        }
        if (ctx->softwareDecoder) {
            ctx->softwareDecoder->SetFrameCallback(nullptr);
        }
        ctx->rendererHandle = 0;
        if (g_activeDecoderHandle.load() == handleVal) {
            g_activeDecoderHandle.store(0);
        }
        OH_LOG_INFO(LOG_APP, "[Decoder] detachVideoPipeline ok decoder=%{public}lld", static_cast<long long>(handleVal));
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}
```

Register export:

```cpp
napi_create_function(env, "detachVideoPipeline", NAPI_AUTO_LENGTH, NapiDetachVideoPipeline, nullptr, &fn);
napi_set_named_property(env, exports, "detachVideoPipeline", fn);
```

- [ ] **Step 4: Add ArkTS wrapper**

In `ExtensionLoader.ets`:

```ts
detachVideoPipelineForBackground(): void {
  try {
    if (this.decoderHandle > 0) {
      rdpnapi.detachVideoPipeline(this.decoderHandle);
    }
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '[ExtensionLoader] detachVideoPipelineForBackground: ' + JSON.stringify(err));
  }
}
```

- [ ] **Step 5: Use safe detach order**

In `RemoteDesktop.detachForBackground()` before renderer destroy:

```ts
if (this.decoderHandle > 0) {
  this.loader.detachVideoPipelineForBackground();
}
if (this.rendererHandle > 0) {
  this.nativeHandles.detachRenderForBackground();
  this.rendererHandle = -1;
}
```

Keep the existing rule: do not call `destroyDecoder()` in background detach.

- [ ] **Step 6: Rebind on foreground**

In `doBackgroundRestoreRender()`, keep:

```ts
if (this.decoderHandle > 0 && this.rendererHandle > 0) {
  this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
}
this.loader.requestFrameRefresh();
```

Expected logs:
- `[Decoder] detachVideoPipeline ok`
- `[GL] Destroy: surface already detached...` only when surface was truly detached
- `[Decoder] bindVideoPipeline ... ok`
- `[ExtLoader] requestFrameRefresh: sent to active adapter`

- [ ] **Step 7: Build and commit**

Run:

```powershell
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git add entry/src/main/cpp/render/hw_decoder.h entry/src/main/cpp/render/hw_decoder.cpp entry/src/main/cpp/render/software_decoder.h entry/src/main/cpp/render/software_decoder.cpp entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/ets/services/NativeSessionHandles.ets entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "fix(render): detach decoder from renderer during background"
```

---

## Task 5: RDP Render Pump Decoupling

**Files:**
- Create: `entry/src/main/cpp/rdp/rdp_frame_pump.h`
- Create: `entry/src/main/cpp/rdp/rdp_frame_pump.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`

**Interfaces:**
- Consumes: FreeRDP GDI primary buffer from `cbEndPaint()`.
- Produces: worker thread that renders the newest copied BGRA frame, so the FreeRDP event thread no longer blocks on GL upload/swap.

- [ ] **Step 1: Create frame pump interface**

Create `rdp_frame_pump.h`:

```cpp
#ifndef RDP_FRAME_PUMP_H
#define RDP_FRAME_PUMP_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

class RdpFramePump {
public:
    RdpFramePump();
    ~RdpFramePump();

    void start();
    void stop();
    void submitLatest(const uint8_t* data, size_t size, int width, int height, int stride);
    uint64_t submitted() const;
    uint64_t rendered() const;
    uint64_t replaced() const;

private:
    void loop();

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread worker_;
    bool running_ = false;
    bool hasFrame_ = false;
    std::vector<uint8_t> frame_;
    int width_ = 0;
    int height_ = 0;
    int stride_ = 0;
    std::atomic<uint64_t> submitted_ {0};
    std::atomic<uint64_t> rendered_ {0};
    std::atomic<uint64_t> replaced_ {0};
};

#endif // RDP_FRAME_PUMP_H
```

- [ ] **Step 2: Implement newest-frame worker**

Create `rdp_frame_pump.cpp`:

```cpp
#include "rdp_frame_pump.h"
#include "render/gl_renderer.h"
#include <hilog/log.h>
#include <cstring>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "RDP_FRAME_PUMP"

RdpFramePump::RdpFramePump() = default;

RdpFramePump::~RdpFramePump() {
    stop();
}

void RdpFramePump::start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_) {
        return;
    }
    running_ = true;
    worker_ = std::thread(&RdpFramePump::loop, this);
}

void RdpFramePump::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
        hasFrame_ = false;
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

void RdpFramePump::submitLatest(const uint8_t* data, size_t size, int width, int height, int stride) {
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (hasFrame_) {
            replaced_++;
        }
        frame_.resize(size);
        std::memcpy(frame_.data(), data, size);
        width_ = width;
        height_ = height;
        stride_ = stride;
        hasFrame_ = true;
        submitted_++;
    }
    cv_.notify_one();
}

void RdpFramePump::loop() {
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker started");
    while (true) {
        std::vector<uint8_t> frame;
        int width = 0;
        int height = 0;
        int stride = 0;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this]() { return !running_ || hasFrame_; });
            if (!running_) {
                break;
            }
            frame.swap(frame_);
            width = width_;
            height = height_;
            stride = stride_;
            hasFrame_ = false;
        }
        const int ret = RendererNapi::RenderRawBgraActive(frame.data(), frame.size(), width, height, stride);
        const uint64_t count = rendered_.fetch_add(1) + 1;
        if (count <= 5 || count % 120 == 0 || ret != 0) {
            OH_LOG_INFO(LOG_APP,
                "[RDP-PUMP] rendered=%{public}llu submitted=%{public}llu replaced=%{public}llu ret=%{public}d size=%{public}dx%{public}d",
                static_cast<unsigned long long>(count),
                static_cast<unsigned long long>(submitted_.load()),
                static_cast<unsigned long long>(replaced_.load()),
                ret, width, height);
        }
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker stopped");
}

uint64_t RdpFramePump::submitted() const { return submitted_.load(); }
uint64_t RdpFramePump::rendered() const { return rendered_.load(); }
uint64_t RdpFramePump::replaced() const { return replaced_.load(); }
```

- [ ] **Step 3: Add to CMake**

```cmake
set(PROTOCOL_SOURCES
    rdp/freerdp_adapter.cpp
    rdp/rdp_frame_pump.cpp
    rustdesk/rustdesk_bridge.cpp
)
```

- [ ] **Step 4: Wire into FreeRDP Impl**

In `freerdp_adapter.cpp`, include:

```cpp
#include "rdp_frame_pump.h"
```

Add to `FreeRdpAdapter::Impl`:

```cpp
RdpFramePump framePump;
```

Start it after GDI is ready, in `cbPostConnect()`:

```cpp
self->impl_->framePump.start();
```

Stop it in cleanup before context/free:

```cpp
impl_->framePump.stop();
```

- [ ] **Step 5: Replace synchronous render in EndPaint**

Change this block:

```cpp
std::lock_guard<std::mutex> renderLock(self->impl_->renderMutex);
ret = RendererNapi::RenderRawBgraActive(data, size, w, h, stride);
```

to:

```cpp
self->impl_->framePump.submitLatest(data, size, w, h, stride);
ret = 0;
```

Keep existing interval throttling; it now controls frame submission, not GL rendering in the protocol thread.

- [ ] **Step 6: Build and device-test RDP**

Run:

```powershell
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected logs on RDP session:
- `[RDP-PUMP] render worker started`
- `[RDP] GDI EndPaint ... renderCost` falls sharply because GL work moved off the FreeRDP callback.
- `[RDP-PUMP] rendered=... replaced=...` appears during motion.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/cpp/rdp/rdp_frame_pump.h entry/src/main/cpp/rdp/rdp_frame_pump.cpp entry/src/main/cpp/CMakeLists.txt entry/src/main/cpp/rdp/freerdp_adapter.cpp
git commit -m "feat(rdp): render latest frames off the protocol thread"
```

---

## Task 6: RustDesk Local-Pressure Backpressure

**Files:**
- Modify: `entry/src/main/cpp/extensions/protocol_adapter.h`
- Modify: `entry/src/main/cpp/render/hw_decoder.h`
- Modify: `entry/src/main/cpp/render/hw_decoder.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `rustdesk_ffi/src/lib.rs`
- Modify: `rustdesk_ffi/src/connector.rs`

**Interfaces:**
- Consumes: native decode/render pressure level from C++.
- Produces:
  - `ProtocolAdapter::reportVideoPressure(int level)`
  - `RustDeskBridge::reportVideoPressure(int level)`
  - `rustdesk_report_video_pressure(handle, level)`
  - `ControlMsg::VideoPressure { level: u32 }`

- [ ] **Step 1: Add protocol hook**

In `protocol_adapter.h`:

```cpp
virtual void reportVideoPressure(int level) { (void)level; }
```

- [ ] **Step 2: Expose active native pressure**

In `hw_decoder.h` under `DecoderNapi`:

```cpp
int ActiveVideoPressureLevel();
```

In `hw_decoder.cpp`, implement:

```cpp
int DecoderNapi::ActiveVideoPressureLevel() {
    int64_t handle = g_activeDecoderHandle.load();
    auto* ctx = reinterpret_cast<DecoderContext*>(handle);
    if (!ctx) {
        return 0;
    }
    size_t queueDepth = 0;
    uint64_t dropped = 0;
    if (ctx->useSoftware) {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        queueDepth = ctx->softQueue.size();
        dropped = ctx->softDropped.load();
    } else if (ctx->decoder) {
        queueDepth = ctx->decoder->QueuedFrameCount();
        dropped = ctx->decoder->DroppedFrameCount();
    }
    if (queueDepth >= 12 || dropped >= 10) { return 3; }
    if (queueDepth >= 8 || dropped >= 4) { return 2; }
    if (queueDepth >= 4) { return 1; }
    return 0;
}
```

Add the small `HardwareDecoder` accessors used above:

```cpp
size_t QueuedFrameCount() const;
uint64_t DroppedFrameCount() const;
```

- [ ] **Step 3: Report pressure after RustDesk decode callback**

In `extension_loader_napi.cpp`, after `DecodeActiveNative(frame)`:

```cpp
const int pressure = DecoderNapi::ActiveVideoPressureLevel();
if (g_activeConnection && frameCount % 30 == 0) {
    g_activeConnection->reportVideoPressure(pressure);
}
```

- [ ] **Step 4: Add Rust FFI pressure API**

In `rustdesk_ffi/src/lib.rs`:

```rust
pub(crate) enum ControlMsg {
    Shutdown,
    RefreshVideo,
    VideoPressure { level: u32 },
    KeyEvent { scancode: u32, pressed: bool },
    MouseEvent { x: i32, y: i32, button: u32, pressed: bool },
    MouseMove { x: i32, y: i32 },
    MouseWheel { x: i32, y: i32, delta: i32 },
    Text { text: String },
    SendFile { remote_path: String, data: Vec<u8> },
    Clipboard { content: Vec<u8> },
}

#[no_mangle]
pub extern "C" fn rustdesk_report_video_pressure(handle: *mut c_void, level: c_int) -> bool {
    if handle.is_null() {
        set_last_error("rustdesk_report_video_pressure null handle");
        return false;
    }
    let clamped = level.clamp(0, 3) as u32;
    let client = unsafe { &*(handle as *mut RustDeskClient) };
    client.tx.send(ControlMsg::VideoPressure { level: clamped }).is_ok()
}
```

- [ ] **Step 5: Consume pressure in Rust streaming loop**

In `connector.rs`, add state:

```rust
let mut requested_pressure_level: u32 = 0;
let mut applied_pressure_level: u32 = 0;
```

Handle control message:

```rust
ControlMsg::VideoPressure { level } => {
    requested_pressure_level = level.min(3);
}
```

In the one-second window section, before the inbound cadence based logic:

```rust
if requested_pressure_level != applied_pressure_level {
    applied_pressure_level = requested_pressure_level;
    let fps = BP_FPS[applied_pressure_level as usize];
    eprintln!(
        "[RustDesk-FFI] LOCAL PRESSURE level={} fps={} quality={} total_video={}",
        applied_pressure_level, fps, image_quality, video_count
    );
    let _ = Session::send_runtime_options(
        crypto,
        preferred_codec,
        image_quality,
        privacy_mode,
        audio_enabled,
        Some(fps),
    );
    let _ = Session::send_refresh_video(crypto);
}
```

Keep the old inbound cadence logic for diagnostics, but do not let it degrade if local pressure is normal:

```rust
let is_overload = requested_pressure_level > 0 &&
    window_video < OVERLOAD_VIDEO_THRESHOLD &&
    video_count > 20;
```

- [ ] **Step 6: Add C++ RustDesk override**

In `rustdesk_bridge.cpp` extern block:

```cpp
bool rustdesk_report_video_pressure(void* handle, int level);
```

In `rustdesk_bridge.h`:

```cpp
void reportVideoPressure(int level) override;
```

In `rustdesk_bridge.cpp`:

```cpp
void RustDeskBridge::reportVideoPressure(int level) {
#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiHandle = impl_->ffiHandle;
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        rustdesk_report_video_pressure(ffiHandle, level);
    }
#else
    (void)level;
#endif
}
```

- [ ] **Step 7: Build and commit**

Run Rust builds, then HAP:

```powershell
cd C:\Users\14288\DevEcoStudioProjects\RemoteDesktop\rustdesk_ffi
cargo +stable-x86_64-pc-windows-gnu build --release --target aarch64-unknown-linux-ohos
cargo +stable-x86_64-pc-windows-gnu build --release --target x86_64-unknown-linux-ohos
cd C:\Users\14288\DevEcoStudioProjects\RemoteDesktop
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git add entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/render/hw_decoder.h entry/src/main/cpp/render/hw_decoder.cpp entry/src/main/cpp/rustdesk/rustdesk_bridge.h entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "feat(rustdesk): drive stream backpressure from local pressure"
```

---

## Task 7: Device Verification Matrix

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Optional modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if a new permanent rule is proven.

**Interfaces:**
- Consumes: committed performance changes.
- Produces: validation evidence and next optimization tasks.

- [ ] **Step 1: RDP verification**

Capture RDP log:

```powershell
$hdc = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$target = '192.168.31.177:38451'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$raw = "C:\tmp\rdp-perf-$ts-raw.log"
$key = "C:\tmp\rdp-perf-$ts-key.log"
$pattern = 'RDP] GDI EndPaint|RDP-PUMP|Perf]\[RDP|GL] RenderRawBGRA|requestFrameRefresh|disconnectAndCleanup|Fatal|SIG'
& $hdc -t $target hilog | Tee-Object -FilePath $raw | Select-String -Pattern $pattern | ForEach-Object { $_.Line } | Tee-Object -FilePath $key
```

Expected:
- RDP connects.
- First frame renders.
- Rapid desktop motion does not block connect/event loop.
- `RDP-PUMP replaced` may increase during overload, but session remains responsive.

- [ ] **Step 2: RustDesk verification**

Capture RustDesk log:

```powershell
$hdc = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$target = '192.168.31.177:38451'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$raw = "C:\tmp\rustdesk-perf-$ts-raw.log"
$key = "C:\tmp\rustdesk-perf-$ts-key.log"
$pattern = 'RustDesk-FFI] config|stream video|stream window|video cadence gap|LOCAL PRESSURE|BACKPRESSURE|Decoder]|SoftDecoder]|Perf]\[RustDesk|requestFrameRefresh|refresh_video|Fatal|SIG'
& $hdc -t $target hilog | Tee-Object -FilePath $raw | Select-String -Pattern $pattern | ForEach-Object { $_.Line } | Tee-Object -FilePath $key
```

Expected:
- RustDesk video starts normally.
- Long-running session emits pressure logs instead of silently degrading.
- If decode pressure rises, runtime fps changes appear with `LOCAL PRESSURE`.
- On foreground restore, `requestFrameRefresh` reaches Rust FFI and sends `refresh_video`.

- [ ] **Step 3: Background/foreground verification**

Run both protocols:
1. Connect.
2. Press Home.
3. Wait 30 seconds.
4. Foreground app.
5. Confirm no new protocol connect occurred.

Expected:
- `detachVideoPipeline ok` before renderer destroy.
- Foreground shows `bindVideoPipeline ... ok`.
- `requestFrameRefresh` reaches protocol adapter.
- No `destroyDecoder` in background detach.
- No `disconnectAndCleanup` unless explicit exit or recovery failure.

- [ ] **Step 4: Update exchange-state docs**

Update `HANDOFF.md`, `TASKS.md`, and memory with:
- commits produced,
- build result,
- device log file paths,
- RDP/RustDesk observed fps/pressure behavior,
- remaining risks.

Update `CODEWALK.md` only if the following rule is validated:

```markdown
## Codex Knowledge Update 2026-06-26 - Video pipeline performance rule

- RDP FreeRDP GDI callbacks must not synchronously perform GL upload/swap on the protocol event thread. Submit latest frames to the RDP frame pump and let the render worker drop replaced frames under pressure.
- Background render detach must detach decoder output from the renderer before destroying the renderer; do not destroy decoder solely for background detach because it can cascade into protocol disconnect.
- RustDesk stream downgrade must be driven by local decoder/render pressure, not inbound video cadence alone.
- `requestFrameRefresh()` must be implemented by protocol adapters; the base `ProtocolAdapter` default is not sufficient for recovery paths.
```

- [ ] **Step 5: Final build and commit docs**

Run:

```powershell
git diff --check
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
git commit -m "docs: record rdp rustdesk video performance validation"
```

If `CODEWALK.md` was updated, add it to the same docs commit.

---

## Review Gates

Gate after Task 2:
- If telemetry shows RDP render cost is already low but inbound GDI paint cadence is bad, focus on FreeRDP settings/codec/rdpgfx instead of frame pump first.
- If RustDesk ingress cadence collapses before decode queue grows, focus on RustDesk server QoS/ack/refresh before local decoder tuning.

Gate after Task 4:
- If background restore still crashes, stop and inspect decoder/render thread logs before Task 5.
- If foreground restore requires new protocol connect, fix lifecycle before performance work.

Gate after Task 5:
- If RDP frame pump improves protocol responsiveness but introduces visible tearing/stale frames, keep latest-frame policy and tune submission interval before dirty-rect work.

Gate after Task 6:
- If `LOCAL PRESSURE` downgrades too often while render costs are low, adjust pressure thresholds in `VideoPerfCounters`, not RustDesk profile defaults.

## Execution Choice

Plan complete. Recommended execution:

1. Subagent-Driven: one fresh subagent per task, review and build between tasks.
2. Inline Execution: execute tasks in this session with checkpoints after each commit.
