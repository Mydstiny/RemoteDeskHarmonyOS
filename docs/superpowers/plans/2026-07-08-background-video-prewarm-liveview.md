# Background Video Prewarm LiveView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. User has explicitly requested no subagents for this thread, so execute inline if continuing here.

**Goal:** Enable low-power background video prewarm only when connection live view is enabled, and bring RDP foreground-return behavior up to the current RustDesk recovery level.

**Architecture:** Keep the existing foreground restore path as the hard fallback. Add a pure ArkTS policy that decides whether background prewarm is enabled from live-view settings and real media activity. RustDesk keeps decoder/frame ingestion warm without rendering to stale XComponent surfaces; RDP adds a latest-frame cache while the renderer is detached and presents that cached frame immediately after foreground reattach before requesting a server refresh.

**Tech Stack:** ArkTS strict mode, HarmonyOS API 23, BackgroundTasksKit, AVSessionKit, XComponent, OpenGL ES renderer lifecycle, FreeRDP GDI frame pump, RustDesk decoder path, C++17 native policy tests, Hypium ArkTS policy tests, DevEco `assembleHap`.

## Execution Status — 2026-07-08

- Implemented and committed Tasks 1-4:
  - `b39ae3de test(remote): add background video prewarm policy`
  - `caa31da3 test(rdp): add background frame cache`
  - `bb3828be feat(rdp): cache background frames for live view`
  - `1bdea9d7 feat(remote): enable live view background video prewarm`
- RDP implementation adds only a background latest-frame cache and foreground cached-frame presentation API. It captures from the existing FreeRDP GDI BGRA buffer while the renderer is detached, at the policy interval, and does not render into stale/background XComponent surfaces.
- RustDesk implementation intentionally does not add a new render path. When live view background prewarm is selected it keeps the current protocol/decoder preservation model, reattaches the renderer on foreground return, arms decoder recovery, and requests refresh through the existing RustDesk path.
- Device validation with live view enabled:
  - Mac RustDesk connected and restored through the correct recent-tasks/card path. Evidence: `logs/mac_rustdesk_connected.jpeg`, `logs/mac_rustdesk_restored.jpeg`, `logs/mac_rustdesk_restore_lifecycle.log`, `logs/mac_rustdesk_prewarm_restore.log`.
  - Mac RustDesk logs show `startSessionLiveView`, foreground renderer reattach, resize, decoder recovery, `requestFrameRefresh sent=true`, and ongoing RustDesk VP9 video/audio frames after restore.
  - RDP connected and restored through recent tasks. Evidence: `logs/rdp_connected_after_continue.jpeg`, `logs/rdp_restored_prewarm.jpeg`, `logs/rdp_prewarm_restore.log`.
  - RDP logs show `[RDP-PREWARM] cached frame 1920x1080`, `[RDP-PREWARM] present cached frame ret=0 size=1920x1080`, `presentRdpCachedFrame ok=true`, `rdp cached frame presented=true`, and the existing `requestFrameRefresh rendered current primary` fallback continuing after restore.
- Verification completed after implementation:
  - `build\rdp-native-tests\rdp_native_tests.exe`: 59 passed, 0 failed.
  - DevEco production `assembleHap`: `BUILD SUCCESSFUL`.
  - Signed HAP installed successfully to `192.168.31.177:38451`.
- Still pending:
  - live view disabled path: confirm `BackgroundVideoPrewarmMode.OFF`, RDP prewarm disabled, and existing foreground refresh still restores.
  - AVSession video fallback matrix on devices that reject video AVSession or live-view publication.

## Global Constraints

- Bind background video prewarm to `liveViewEnabled === true` and `liveViewMode !== LiveViewMode.OFF`.
- Do not render to XComponent/EGL surfaces while the app is backgrounded.
- Do not reconnect RDP/RustDesk as a background recovery mechanism.
- Keep current foreground restore: reattach renderer, bind decoder output, request frame refresh, and arm decoder recovery when needed.
- Keep background prewarm low power: start with a 1000 ms minimum capture/prewarm interval.
- Preserve RDP certificate/ErrorInfo/no-frame sheet, clipboard, rdpdr, input, and rdpsnd PCM boundary behavior.
- Preserve RustDesk topbar, input preferences, file transfer, clipboard, relay, and existing decoder recovery behavior.
- Add focused policy tests before production wiring.
- Commit each task after native tests/build verification.

---

## File Structure

- Create `entry/src/main/ets/services/BackgroundVideoPrewarmPolicy.ets`
  Pure ArkTS policy for deciding `OFF`, `LOW_FPS_PREWARM`, or `AUDIO_ONLY`.

- Create `entry/src/ohosTest/ets/test/BackgroundVideoPrewarmPolicy.test.ets`
  Hypium policy tests for live-view setting binding, media activity, and protocol/background gates.

- Modify `entry/src/ohosTest/ets/test/List.test.ets`
  Register the new policy tests.

- Create `entry/src/main/cpp/rdp/rdp_background_frame_cache.h`
  Native RDP latest-frame cache and pure capture policy.

- Create `entry/src/main/cpp/rdp/rdp_background_frame_cache.cpp`
  Thread-safe copy/snapshot implementation for BGRA frames.

- Create `entry/src/main/cpp/test/rdp_background_frame_cache_test.cpp`
  Native tests for interval gating, invalid frame rejection, copy/snapshot, and clear.

- Modify `entry/src/main/cpp/rdp/freerdp_adapter.h/.cpp`
  Store latest RDP frame during background prewarm and expose foreground immediate-present.

- Modify `entry/src/main/cpp/extensions/extension_loader_napi.cpp` and `entry/src/main/ets/types/rdpnapi.d.ts`
  Add NAPI hooks for enabling background prewarm and presenting a cached RDP frame.

- Modify `entry/src/main/ets/services/ExtensionLoader.ets`
  Add typed wrappers around the new NAPI hooks.

- Modify `entry/src/main/ets/pages/RemoteDesktop.ets`
  Wire policy decisions into background detach and foreground restore for both RDP and RustDesk.

- Modify `entry/src/main/cpp/CMakeLists.txt`
  Register the new native cache test and source file.

---

### Task 1: ArkTS Background Prewarm Policy

**Files:**
- Create: `entry/src/main/ets/services/BackgroundVideoPrewarmPolicy.ets`
- Create: `entry/src/ohosTest/ets/test/BackgroundVideoPrewarmPolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces:
  - `enum BackgroundVideoPrewarmMode`
  - `interface BackgroundVideoPrewarmInput`
  - `resolveBackgroundVideoPrewarmMode(input: BackgroundVideoPrewarmInput): BackgroundVideoPrewarmMode`
  - `backgroundVideoPrewarmIntervalMs(mode: BackgroundVideoPrewarmMode): number`

- [ ] **Step 1: Write the failing policy tests**

Create `entry/src/ohosTest/ets/test/BackgroundVideoPrewarmPolicy.test.ets`:

```ts
import { describe, it, expect } from '@ohos/hypium';
import { LiveViewMode } from '../../../main/ets/services/LiveViewTypes';
import {
  BackgroundVideoPrewarmInput,
  BackgroundVideoPrewarmMode,
  backgroundVideoPrewarmIntervalMs,
  resolveBackgroundVideoPrewarmMode
} from '../../../main/ets/services/BackgroundVideoPrewarmPolicy';

function baseInput(): BackgroundVideoPrewarmInput {
  return {
    liveViewEnabled: true,
    liveViewMode: LiveViewMode.AVSESSION,
    appBackgrounded: true,
    protocolConnected: true,
    protocol: 'rustdesk',
    hasAudio: false,
    hasVideo: true
  };
}

export default function backgroundVideoPrewarmPolicyTest(): void {
  describe('BackgroundVideoPrewarmPolicy', (): void => {
    it('enables_low_fps_prewarm_only_for_background_live_view_video', 0, (): void => {
      expect(resolveBackgroundVideoPrewarmMode(baseInput()))
        .assertEqual(BackgroundVideoPrewarmMode.LOW_FPS_PREWARM);
    });

    it('disables_when_live_view_is_off_or_app_is_foreground', 0, (): void => {
      const disabled: BackgroundVideoPrewarmInput = baseInput();
      disabled.liveViewEnabled = false;
      expect(resolveBackgroundVideoPrewarmMode(disabled)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const offMode: BackgroundVideoPrewarmInput = baseInput();
      offMode.liveViewMode = LiveViewMode.OFF;
      expect(resolveBackgroundVideoPrewarmMode(offMode)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const foreground: BackgroundVideoPrewarmInput = baseInput();
      foreground.appBackgrounded = false;
      expect(resolveBackgroundVideoPrewarmMode(foreground)).assertEqual(BackgroundVideoPrewarmMode.OFF);
    });

    it('uses_audio_only_when_audio_has_no_video', 0, (): void => {
      const audioOnly: BackgroundVideoPrewarmInput = baseInput();
      audioOnly.hasVideo = false;
      audioOnly.hasAudio = true;
      expect(resolveBackgroundVideoPrewarmMode(audioOnly)).assertEqual(BackgroundVideoPrewarmMode.AUDIO_ONLY);
    });

    it('requires_connected_supported_remote_protocol', 0, (): void => {
      const disconnected: BackgroundVideoPrewarmInput = baseInput();
      disconnected.protocolConnected = false;
      expect(resolveBackgroundVideoPrewarmMode(disconnected)).assertEqual(BackgroundVideoPrewarmMode.OFF);

      const ssh: BackgroundVideoPrewarmInput = baseInput();
      ssh.protocol = 'ssh';
      expect(resolveBackgroundVideoPrewarmMode(ssh)).assertEqual(BackgroundVideoPrewarmMode.OFF);
    });

    it('uses_safe_low_power_interval', 0, (): void => {
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.LOW_FPS_PREWARM)).assertEqual(1000);
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.AUDIO_ONLY)).assertEqual(0);
      expect(backgroundVideoPrewarmIntervalMs(BackgroundVideoPrewarmMode.OFF)).assertEqual(0);
    });
  });
}
```

Update `entry/src/ohosTest/ets/test/List.test.ets`:

```ts
import backgroundVideoPrewarmPolicyTest from './BackgroundVideoPrewarmPolicy.test';
```

and call it inside `testsuite()`:

```ts
  backgroundVideoPrewarmPolicyTest();
```

- [ ] **Step 2: Run the test target to verify the expected existing blocker**

Run:

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestBuildArkTS --analyze=normal
```

Expected: the target may still hit the known `HostListPage.ets` parser/sourcemap blocker, but if it reaches this new test it should fail because `BackgroundVideoPrewarmPolicy.ets` does not exist.

- [ ] **Step 3: Implement the policy**

Create `entry/src/main/ets/services/BackgroundVideoPrewarmPolicy.ets`:

```ts
import { LiveViewMode } from './LiveViewTypes';

export enum BackgroundVideoPrewarmMode {
  OFF = 0,
  LOW_FPS_PREWARM = 1,
  AUDIO_ONLY = 2
}

export interface BackgroundVideoPrewarmInput {
  liveViewEnabled: boolean;
  liveViewMode: number;
  appBackgrounded: boolean;
  protocolConnected: boolean;
  protocol: string;
  hasAudio: boolean;
  hasVideo: boolean;
}

export function resolveBackgroundVideoPrewarmMode(input: BackgroundVideoPrewarmInput):
  BackgroundVideoPrewarmMode {
  if (!input.liveViewEnabled || input.liveViewMode === LiveViewMode.OFF) {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (!input.appBackgrounded || !input.protocolConnected) {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (input.protocol !== 'rdp' && input.protocol !== 'rustdesk') {
    return BackgroundVideoPrewarmMode.OFF;
  }
  if (input.hasVideo) {
    return BackgroundVideoPrewarmMode.LOW_FPS_PREWARM;
  }
  if (input.hasAudio) {
    return BackgroundVideoPrewarmMode.AUDIO_ONLY;
  }
  return BackgroundVideoPrewarmMode.OFF;
}

export function backgroundVideoPrewarmIntervalMs(mode: BackgroundVideoPrewarmMode): number {
  if (mode === BackgroundVideoPrewarmMode.LOW_FPS_PREWARM) {
    return 1000;
  }
  return 0;
}
```

- [ ] **Step 4: Verify production build**

Run:

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/services/BackgroundVideoPrewarmPolicy.ets entry/src/ohosTest/ets/test/BackgroundVideoPrewarmPolicy.test.ets entry/src/ohosTest/ets/test/List.test.ets
git commit -m "test(remote): add background video prewarm policy"
```

---

### Task 2: RDP Latest-Frame Cache

**Files:**
- Create: `entry/src/main/cpp/rdp/rdp_background_frame_cache.h`
- Create: `entry/src/main/cpp/rdp/rdp_background_frame_cache.cpp`
- Create: `entry/src/main/cpp/test/rdp_background_frame_cache_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `struct RdpBackgroundFrameSnapshot`
  - `bool ShouldCaptureRdpBackgroundFrame(bool enabled, uint64_t nowMs, uint64_t lastCaptureMs, uint32_t intervalMs, int width, int height, int stride, size_t size)`
  - `class RdpBackgroundFrameCache`

- [ ] **Step 1: Write failing native tests**

Create `entry/src/main/cpp/test/rdp_background_frame_cache_test.cpp`:

```cpp
#include "test_runner.h"
#include "rdp/rdp_background_frame_cache.h"

RDP_TEST_CASE(rdp_background_cache_policy_requires_enabled_valid_interval_and_frame) {
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(false, 2000, 0, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 500, 0, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 1500, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 0, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 1920, 1080, 0, 8294400));
    RDP_ASSERT(ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 1920, 1080, 7680, 8294400));
}

RDP_TEST_CASE(rdp_background_cache_copies_and_snapshots_latest_frame) {
    RdpBackgroundFrameCache cache;
    const uint8_t frame[16] = {
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16
    };
    RDP_ASSERT(cache.capture(frame, sizeof(frame), 2, 2, 8, 1234));
    RdpBackgroundFrameSnapshot snapshot = cache.snapshot();
    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(snapshot.width == 2);
    RDP_ASSERT(snapshot.height == 2);
    RDP_ASSERT(snapshot.stride == 8);
    RDP_ASSERT(snapshot.capturedAtMs == 1234);
    RDP_ASSERT(snapshot.data.size() == sizeof(frame));
    RDP_ASSERT(snapshot.data[0] == 1);
    RDP_ASSERT(snapshot.data[15] == 16);
}

RDP_TEST_CASE(rdp_background_cache_clear_invalidates_snapshot) {
    RdpBackgroundFrameCache cache;
    const uint8_t frame[4] = {1, 2, 3, 4};
    RDP_ASSERT(cache.capture(frame, sizeof(frame), 1, 1, 4, 100));
    cache.clear();
    RDP_ASSERT(!cache.snapshot().valid);
}
```

Add to `entry/src/main/cpp/CMakeLists.txt` native test source list:

```cmake
test/rdp_background_frame_cache_test.cpp
rdp/rdp_background_frame_cache.cpp
```

- [ ] **Step 2: Verify failing test build**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
```

Expected: fail because the new cache header/source do not exist.

- [ ] **Step 3: Implement cache**

Create `entry/src/main/cpp/rdp/rdp_background_frame_cache.h`:

```cpp
#ifndef RDP_BACKGROUND_FRAME_CACHE_H
#define RDP_BACKGROUND_FRAME_CACHE_H

#include <cstdint>
#include <cstddef>
#include <mutex>
#include <vector>

struct RdpBackgroundFrameSnapshot {
    bool valid {false};
    std::vector<uint8_t> data;
    int width {0};
    int height {0};
    int stride {0};
    uint64_t capturedAtMs {0};
};

bool ShouldCaptureRdpBackgroundFrame(bool enabled, uint64_t nowMs, uint64_t lastCaptureMs,
                                     uint32_t intervalMs, int width, int height, int stride,
                                     size_t size);

class RdpBackgroundFrameCache {
public:
    bool capture(const uint8_t* data, size_t size, int width, int height, int stride,
                 uint64_t capturedAtMs);
    RdpBackgroundFrameSnapshot snapshot() const;
    void clear();
    uint64_t lastCaptureMs() const;

private:
    mutable std::mutex mutex_;
    RdpBackgroundFrameSnapshot latest_;
};

#endif
```

Create `entry/src/main/cpp/rdp/rdp_background_frame_cache.cpp`:

```cpp
#include "rdp_background_frame_cache.h"
#include <algorithm>

bool ShouldCaptureRdpBackgroundFrame(bool enabled, uint64_t nowMs, uint64_t lastCaptureMs,
                                     uint32_t intervalMs, int width, int height, int stride,
                                     size_t size) {
    if (!enabled || intervalMs == 0 || width <= 0 || height <= 0 || stride <= 0 || size == 0) {
        return false;
    }
    if (nowMs < intervalMs) {
        return false;
    }
    if (lastCaptureMs > 0 && nowMs - lastCaptureMs < intervalMs) {
        return false;
    }
    return true;
}

bool RdpBackgroundFrameCache::capture(const uint8_t* data, size_t size, int width, int height,
                                      int stride, uint64_t capturedAtMs) {
    if (data == nullptr || width <= 0 || height <= 0 || stride <= 0 || size == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    latest_.valid = true;
    latest_.data.assign(data, data + size);
    latest_.width = width;
    latest_.height = height;
    latest_.stride = stride;
    latest_.capturedAtMs = capturedAtMs;
    return true;
}

RdpBackgroundFrameSnapshot RdpBackgroundFrameCache::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_;
}

void RdpBackgroundFrameCache::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    latest_ = RdpBackgroundFrameSnapshot {};
}

uint64_t RdpBackgroundFrameCache::lastCaptureMs() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_.capturedAtMs;
}
```

- [ ] **Step 4: Verify native tests**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
```

Expected: all native tests pass.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/cpp/rdp/rdp_background_frame_cache.h entry/src/main/cpp/rdp/rdp_background_frame_cache.cpp entry/src/main/cpp/test/rdp_background_frame_cache_test.cpp entry/src/main/cpp/CMakeLists.txt
git commit -m "test(rdp): add background frame cache"
```

---

### Task 3: Native RDP Prewarm Hooks

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`

**Interfaces:**
- Produces:
  - `bool setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number)`
  - `boolean presentRdpCachedFrame(sessionId: number)`

- [ ] **Step 1: Extend `FreeRdpAdapter` state**

In the RDP implementation object in `freerdp_adapter.cpp`, add:

```cpp
std::atomic<bool> backgroundVideoPrewarmEnabled {false};
std::atomic<uint32_t> backgroundVideoPrewarmIntervalMs {1000};
RdpBackgroundFrameCache backgroundFrameCache;
```

Include:

```cpp
#include "rdp_background_frame_cache.h"
```

- [ ] **Step 2: Capture latest frame in `cbEndPaint` without rendering in background**

Inside `FreeRdpAdapter::cbEndPaint`, after the GDI buffer pointer/size/width/height/stride are validated and before returning, add:

```cpp
const uint64_t nowMs = NowMs();
if (ShouldCaptureRdpBackgroundFrame(
    self->impl_->backgroundVideoPrewarmEnabled.load(),
    nowMs,
    self->impl_->backgroundFrameCache.lastCaptureMs(),
    self->impl_->backgroundVideoPrewarmIntervalMs.load(),
    w,
    h,
    stride,
    size)) {
    const bool captured = self->impl_->backgroundFrameCache.capture(
        data, size, w, h, stride, nowMs);
    if (captured) {
        OH_LOG_DEBUG(LOG_APP, "[RDP-PREWARM] cached frame %{public}dx%{public}d bytes=%{public}zu",
                     w, h, size);
    }
}
```

Use the file's existing monotonic time helper if it already has one; otherwise add a small local `NowMs()` helper beside other RDP timing helpers.

- [ ] **Step 3: Add adapter methods**

In `freerdp_adapter.h`, add public/static dispatch methods matching the existing session lookup style:

```cpp
bool setBackgroundVideoPrewarm(bool enabled, uint32_t intervalMs);
bool presentCachedBackgroundFrame();
```

Implementation:

```cpp
bool FreeRdpAdapter::setBackgroundVideoPrewarm(bool enabled, uint32_t intervalMs) {
    impl_->backgroundVideoPrewarmEnabled.store(enabled);
    impl_->backgroundVideoPrewarmIntervalMs.store(intervalMs == 0 ? 1000 : intervalMs);
    if (!enabled) {
        impl_->backgroundFrameCache.clear();
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] enabled=%{public}d interval=%{public}u",
                enabled ? 1 : 0, impl_->backgroundVideoPrewarmIntervalMs.load());
    return true;
}

bool FreeRdpAdapter::presentCachedBackgroundFrame() {
    RdpBackgroundFrameSnapshot snapshot = impl_->backgroundFrameCache.snapshot();
    if (!snapshot.valid || snapshot.data.empty()) {
        OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] no cached frame to present");
        return false;
    }
    const int ret = RendererNapi::RenderRawBgraActive(
        snapshot.data.data(), snapshot.data.size(), snapshot.width, snapshot.height, snapshot.stride);
    OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] present cached frame ret=%{public}d size=%{public}dx%{public}d",
                ret, snapshot.width, snapshot.height);
    return ret == 0;
}
```

- [ ] **Step 4: Expose NAPI wrappers**

In `extension_loader_napi.cpp`, add exports:

```cpp
setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean
presentRdpCachedFrame(sessionId: number): boolean
```

Route only RDP sessions to `FreeRdpAdapter`; return `false` for invalid session IDs or non-RDP protocols.

Update `entry/src/main/ets/types/rdpnapi.d.ts`:

```ts
export function setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean;
export function presentRdpCachedFrame(sessionId: number): boolean;
```

- [ ] **Step 5: Verify**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: native tests pass and HAP build succeeds.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/cpp/rdp/freerdp_adapter.h entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/ets/types/rdpnapi.d.ts
git commit -m "feat(rdp): cache background frames for live view"
```

---

### Task 4: ArkTS Wiring For RDP And RustDesk

**Files:**
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes:
  - `resolveBackgroundVideoPrewarmMode()`
  - `backgroundVideoPrewarmIntervalMs()`
  - `rdpnapi.setRdpBackgroundVideoPrewarm()`
  - `rdpnapi.presentRdpCachedFrame()`

- [ ] **Step 1: Add loader wrappers**

In `ExtensionLoader.ets`, add:

```ts
setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean {
  try {
    const ok = rdpnapi.setRdpBackgroundVideoPrewarm(sessionId, enabled, intervalMs) as boolean;
    hilog.info(DOMAIN, TAG, '[ExtensionLoader] setRdpBackgroundVideoPrewarm ok=' +
      ok.toString() + ' enabled=' + enabled.toString() + ' interval=' + intervalMs.toString());
    return ok;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '[ExtensionLoader] setRdpBackgroundVideoPrewarm failed: ' +
      JSON.stringify(err));
    return false;
  }
}

presentRdpCachedFrame(sessionId: number): boolean {
  try {
    const ok = rdpnapi.presentRdpCachedFrame(sessionId) as boolean;
    hilog.info(DOMAIN, TAG, '[ExtensionLoader] presentRdpCachedFrame ok=' + ok.toString());
    return ok;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '[ExtensionLoader] presentRdpCachedFrame failed: ' + JSON.stringify(err));
    return false;
  }
}
```

- [ ] **Step 2: Enable prewarm on background detach**

In `RemoteDesktop.ets`, import:

```ts
import {
  BackgroundVideoPrewarmMode,
  backgroundVideoPrewarmIntervalMs,
  resolveBackgroundVideoPrewarmMode
} from '../services/BackgroundVideoPrewarmPolicy';
```

Before `detachRenderForBackground()` destroys renderer, compute:

```ts
const liveViewEnabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
const liveViewMode: number = AppStorage.get<number>('liveViewMode') ?? 1;
const prewarmMode: BackgroundVideoPrewarmMode = resolveBackgroundVideoPrewarmMode({
  liveViewEnabled: liveViewEnabled,
  liveViewMode: liveViewMode,
  appBackgrounded: true,
  protocolConnected: this.sessionId > 0 && this.connectStarted,
  protocol: this.pendingHost.protocol,
  hasAudio: this.loader.isAudioActive(),
  hasVideo: this.loader.isVideoActive()
});
const prewarmIntervalMs: number = backgroundVideoPrewarmIntervalMs(prewarmMode);
```

If protocol is RDP:

```ts
if (this.pendingHost.protocol === 'rdp') {
  this.loader.setRdpBackgroundVideoPrewarm(
    this.sessionId,
    prewarmMode === BackgroundVideoPrewarmMode.LOW_FPS_PREWARM,
    prewarmIntervalMs
  );
}
```

For RustDesk, do not add a new renderer path. Log the prewarm decision and continue preserving decoder/protocol state:

```ts
hilog.info(RD_DOMAIN, RD_TAG, 'background prewarm mode=' + prewarmMode.toString() +
  ' protocol=' + this.pendingHost.protocol);
```

- [ ] **Step 3: Present cached RDP frame on foreground restore**

In `doBackgroundRestoreRender()`, after renderer is reattached/resized and before `requestFrameRefresh()`, add:

```ts
if (this.pendingHost.protocol === 'rdp' && this.sessionId > 0) {
  const presented: boolean = this.loader.presentRdpCachedFrame(this.sessionId);
  hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: rdp cached frame presented=' +
    presented.toString());
  this.loader.setRdpBackgroundVideoPrewarm(this.sessionId, false, 0);
}
```

Keep the existing `requestFrameRefresh()` and decoder recovery logic after this block.

- [ ] **Step 4: Disable prewarm on cleanup and foreground stop**

In cleanup/full disconnect paths and foreground restore completion, call:

```ts
if (this.pendingHost.protocol === 'rdp' && this.sessionId > 0) {
  this.loader.setRdpBackgroundVideoPrewarm(this.sessionId, false, 0);
}
```

- [ ] **Step 5: Verify build**

Run:

```powershell
build\rdp-native-tests\rdp_native_tests.exe
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: native tests pass and production build succeeds.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "feat(remote): enable live view background video prewarm"
```

---

### Task 5: Device Validation And Exchange State

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify only if device evidence is strong: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`

**Interfaces:**
- Produces final verification evidence for RDP/RustDesk background prewarm.

- [ ] **Step 1: Install the HAP**

Run:

```powershell
hdc -t 192.168.31.177:38451 install -r entry\build\default\outputs\default\entry-default-signed.hap
```

Expected: install success.

- [ ] **Step 2: Validate RustDesk video-only with live view enabled**

Use recent tasks/card click for foreground return:

```powershell
hdc -t 192.168.31.177:38451 shell aa start -a com.ohos.mms.MainAbility -b com.ohos.mms
hdc -t 192.168.31.177:38451 shell uitest uiInput keyEvent 2720
hdc -t 192.168.31.177:38451 shell uitest uiInput click 660 1400
```

Expected:
- no RustDesk protocol reconnect
- video visible after return
- logs show background prewarm policy and existing decoder output/recovery behavior

- [ ] **Step 3: Validate RDP video-only with live view enabled**

Expected:
- logs show `[RDP-PREWARM] enabled=1`
- logs show cached RDP frames while backgrounded at approximately 1 fps
- foreground restore logs show `rdp cached frame presented=true` or a clear `false` followed by successful `requestFrameRefresh`
- no RDP reconnect
- no ErrorInfo/no-frame sheet unless the server actually reports an error

- [ ] **Step 4: Validate live view disabled**

Turn off live view in settings, repeat one RustDesk or RDP background cycle.

Expected:
- prewarm mode is `OFF`
- RDP native prewarm is disabled
- foreground restore still succeeds through existing refresh/recovery path

- [ ] **Step 5: Update exchange files**

Record:
- latest commit hash
- native test count
- production build result
- device logs/screenshots
- which matrix items passed or remain pending

- [ ] **Step 6: Commit exchange update**

```powershell
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
git commit -m "docs: record background video prewarm validation"
```

---

## Self-Review

- Spec coverage: The plan implements live-view setting binding, low-power prewarm, no background XComponent rendering, RDP catch-up via latest-frame cache, RustDesk preservation of current recovery behavior, and validation for live-view enabled/disabled.
- Placeholder scan: No unfinished marker text or open-ended "add tests" steps remain. Each task names exact files and commands.
- Type consistency: `BackgroundVideoPrewarmMode`, `BackgroundVideoPrewarmInput`, `setRdpBackgroundVideoPrewarm`, and `presentRdpCachedFrame` are introduced before later tasks consume them.
- Scope: This plan does not alter RDP certificate/ErrorInfo/rdpdr/input, RustDesk topbar/file/relay, or audio PCM policy.
