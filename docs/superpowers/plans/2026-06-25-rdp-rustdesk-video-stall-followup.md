# RDP/RustDesk Video Stall Follow-Up Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to continue this plan task-by-task. Preserve software decoding support. Do not remove VP8/VP9/AV1 fallback paths.

## Goal

继续修复并验证 RDP / RustDesk 长时间连接后画面逐渐变卡、最终停止，但输入/触控仍可用的问题。

## What Was Fixed In This Pass

- Added pure native backpressure policy:
  - `entry/src/main/cpp/render/video_backpressure_controller.h`
  - `entry/src/main/cpp/render/video_backpressure_controller.cpp`
- Added native tests:
  - `entry/src/main/cpp/test/video_backpressure_test.cpp`
- Added optional native test target:
  - `RDP_BUILD_TESTS`
  - `rdp_native_tests`
- Changed hardware decoder queue overload behavior:
  - Soft queue overflow now drops old queued frames and admits the latest incoming frame.
  - Soft overflow no longer enters indefinite wait-keyframe mode.
  - Hard truncation still enters wait-keyframe mode to avoid pushing truncated encoded data.
- Kept software decoding:
  - `SoftwareDecoder`
  - FFmpeg VP8/VP9/AV1 fallback path
  - RustDesk VP8/VP9/AV1 codec options
- Added RDP adaptive render pacing:
  - RDP GDI render path now raises min render interval from 16.7ms to 33ms/50ms when GL render cost is high.
  - This reduces FreeRDP event-loop backpressure from synchronous full-frame BGRA upload and `eglSwapBuffers`.
- Added user-facing RustDesk codec guidance:
  - H264/H265 are recommended for long sessions.
  - VP8/VP9/AV1 remain available.

## Verification Already Run

- Native strategy tests:

```powershell
cmake -S entry/src/main/cpp -B .native-test-build -DRDP_BUILD_TESTS=ON
cmake --build .native-test-build --target rdp_native_tests
.native-test-build\rdp_native_tests.exe
```

Result:

```text
9 passed, 0 failed, 9 total
```

- Diff check:

```powershell
git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop diff --check
```

Result: exit 0. Warnings were only Git config permission / CRLF warnings.

- Hvigor build:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Result: `BUILD SUCCESSFUL in 12 s 468 ms`.

## Important Risk Points

- The fix reduces freeze risk but does not yet prove long-session stability on real devices.
- RustDesk FFI has no wired keyframe/refresh request API yet. The new policy records the need for keyframe recovery but cannot force the remote peer to send one.
- Soft overflow now admits latest non-key frames after dropping older queued frames. This favors forward progress over perfect inter-frame continuity; possible risk is transient decode artifacts after overload.
- RDP still uses GDI full-frame BGRA upload. Adaptive pacing reduces pressure but does not replace the underlying costly path.
- Local pure CMake emitted `FFmpeg soft decoder disabled` because `libs/ffmpeg-ohos/${OHOS_ARCH}` was unavailable in that local configure. Hvigor build succeeded, but Claude should verify actual packaged ABI includes intended soft decoder libs before release.
- User-facing codec hint recommends H264/H265, but VP8/VP9/AV1 must remain supported.

## Next Tasks For Claude

### T-Video-001 Confirm Packaged Soft Decoder Availability

- [ ] Check `entry/src/main/cpp/CMakeLists.txt` FFmpeg soft decoder detection under the DevEco/Hvigor OHOS ABI build.
- [ ] Confirm whether `USE_FFMPEG_SOFTWARE_DECODER` is defined during actual package build.
- [ ] Confirm `libavcodec.a`, `libavutil.a`, and `libswscale.a` exist for each target ABI.
- [ ] If missing, do not disable VP8/VP9/AV1. Instead document or restore the FFmpeg prebuilt path.

### T-Video-002 Add Runtime Video Pipeline Counters

- [ ] Add a lightweight NAPI getter for decoder/render counters:
  - input pushed.
  - soft drops.
  - hard wait-keyframe drops.
  - keyframe requests pending.
  - output frames.
  - update surface failures.
  - RDP rendered/skipped/slow render count.
- [ ] Keep this diagnostic read-only.
- [ ] Expose it in logs or a hidden diagnostic panel only; avoid new visible UI clutter.

### T-Video-003 Wire Keyframe/Refresh Request If RustDesk FFI Supports It

- [ ] Inspect `rustdesk_ffi` exported API for refresh/keyframe request.
- [ ] If available, add `ProtocolAdapter::requestVideoRefresh()` or RustDesk-specific internal method.
- [ ] Trigger it when `VideoBackpressureController::shouldRequestKeyframe()` becomes true.
- [ ] If unavailable, document that recovery depends on remote keyframes and keep the soft-overflow forward-progress policy.

### T-Video-004 Improve RDP Rendering Path Beyond Adaptive Pacing

- [ ] Measure `RenderRawBGRA` upload/draw/swap times during long sessions.
- [ ] If slow render persists, consider a latest-frame worker:
  - FreeRDP event thread copies or references latest GDI frame metadata.
  - Render thread owns GL upload/swap.
  - Old frames are overwritten, not queued.
- [ ] Do not implement a large render-thread rewrite without device logs proving adaptive pacing is insufficient.

### T-Video-005 Device Stress Matrix

- [ ] Run RDP 1080p for 30 minutes.
- [ ] Run RDP 2K for 30 minutes.
- [ ] Run RustDesk H264 for 30 minutes.
- [ ] Run RustDesk H265 for 30 minutes.
- [ ] Run RustDesk auto/VP9 for 30 minutes if soft decoder is packaged.
- [ ] Record hilog patterns:
  - `[Decoder] queue overflow`
  - `[Decoder] wait-keyframe`
  - `[Decoder] output frame`
  - `[GL] RenderRawBGRA`
  - `[RDP] GDI EndPaint`
  - `[RustDesk-FFI] stream video`

### T-Video-006 Update Project Knowledge

- [ ] If device tests confirm stability, update:
  - `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
  - `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
  - `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- [ ] Add durable rule to `CODEWALK.md` only if confirmed:
  - Soft video queue overload must not enter indefinite wait-keyframe mode.
  - Hard truncated input still waits for keyframe.
  - RDP GDI render callback must avoid long synchronous GL stalls.

## Suggested Handoff Summary

Video stall mitigation landed. The main decoder change separates soft overload from hard corruption recovery: soft queue overflow drops old queued frames and admits the latest frame, while truncated encoded input still waits for a keyframe. RDP GDI render path now adaptively lowers render frequency when synchronous GL render cost rises. RustDesk soft decoding remains intact and codec UI now recommends H264/H265 for long sessions without removing VP8/VP9/AV1. Build and native strategy tests pass; real-device long-session validation is still required.
