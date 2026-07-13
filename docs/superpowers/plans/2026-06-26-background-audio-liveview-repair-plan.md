# Background Audio LiveView Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix remote-session background audio, AVSession live view, and foreground refresh without regressing current RDP/RustDesk protocol, video, audio, or input paths.

**Architecture:** Keep remote-session preservation as a sidecar around the working protocol pipelines. Native audio reports real PCM activity and mute state; ArkTS uses that state to choose one continuous background task mode set and the correct live-view strategy. AVSession is used only for actual audio sessions and falls back to notification live view if creation fails.

**Tech Stack:** ArkTS/ArkUI API 23, BackgroundTasksKit, AVSessionKit, NAPI C++17, OHAudio, FreeRDP/RustDesk existing adapters, DevEco hvigor, native CMake tests.

## Global Constraints

- Do not revert existing RDP/RustDesk video-performance commits or pre-existing dirty RustDesk/Rust FFI files.
- Do not destroy decoder or protocol connections during background detach.
- Do not add blocking work to RDP/RustDesk connect paths.
- AudioPlayback must be driven by actual native PCM activity, not by user preference or an ArkTS handle alone.
- Prefer one continuous background task with combined modes or updateBackgroundRunning; do not start separate API-12 continuous tasks for the same UIAbility.
- AVSession mode is valid only when actual remote audio is active; no-audio sessions use notification live view.
- AVSession failure must downgrade to notification live view and must not break the remote session.
- Verification must include native tests, HAP build, and a true-device checklist for RDP/RustDesk with and without audio.

---

## Task 1: Native Audio Activity And Mute State

**Files:**
- Create: `entry/src/main/cpp/audio/audio_activity_state.h`
- Create: `entry/src/main/cpp/audio/audio_activity_state.cpp`
- Create: `entry/src/main/cpp/test/audio_activity_state_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`
- Modify: `entry/src/main/cpp/audio/audio_player.cpp`
- Modify: `entry/src/main/cpp/audio/audio_player.h`

**Interfaces:**
- Produces `AudioActivityState` with `recordPcmFrame()`, `setMuted(bool)`, `isMuted()`, `hasReceivedPcm()`, `shouldDropIncomingPcm()`, and `reset()`.
- Produces NAPI exports `isAudioPlaybackActive()` and `setActiveAudioMute(bool)`.

- [ ] Add failing native tests for real PCM activity and muted frame dropping.
- [ ] Implement pure native audio state and wire it into tests.
- [ ] Integrate state into `AudioPlayerNapi::DispatchActiveNative()` so muted audio drops incoming PCM and does not recreate a renderer.
- [ ] Make `setAudioMute(handle, mute)` and `setActiveAudioMute(mute)` share the same native mute state.
- [ ] Run native tests.

## Task 2: ArkTS Audio State Bridge

**Files:**
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`

**Interfaces:**
- `ExtensionLoader.isAudioActive()` must query native real PCM activity.
- `ExtensionLoader.setAudioMute(handle, mute)` must call active native mute even when the ArkTS handle is not available.

- [ ] Add wrapper for `isAudioPlaybackActive()`.
- [ ] Change `isAudioActive()` from handle-only to native real-PCM state.
- [ ] Change mute wrapper to use handle-specific mute when available and active mute fallback when not.

## Task 3: Single Continuous Task Mode Management

**Files:**
- Modify: `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`

**Interfaces:**
- `startSessionTask(context, info)` starts one task with `['multiDeviceConnection']` or `['multiDeviceConnection', 'audioPlayback']`.
- `startAudioPlaybackTask(context, info)` updates the existing task modes instead of starting a second task.
- `updateAudioPlaybackMode(context, info)` can add or remove audio mode while backgrounded.

- [ ] Add deterministic helper functions for mode calculation.
- [ ] Use combined mode start for initial audio sessions.
- [ ] Use `backgroundTaskManager.updateBackgroundRunning()` for audio mode changes.
- [ ] Keep failure non-fatal to the remote session.

## Task 4: LiveView Strategy Selection And Fallback

**Files:**
- Modify: `entry/src/main/ets/services/LiveViewTypes.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionLiveViewService.ets`
- Modify: `entry/src/main/ets/services/AvSessionLiveViewStrategy.ets`

**Interfaces:**
- `resolveLiveViewMode(preferredMode, hasAudio)` returns OFF, AVSESSION, or NOTIFICATION.
- AVSession start throws on failure so the service can fall back to notification.
- Notification mode is used for no-audio sessions even if preferred mode is AVSESSION.

- [ ] Add pure resolver and tests where possible.
- [ ] Use resolver in `RemoteSessionLiveViewService.start()`.
- [ ] Implement AVSession failure fallback to notification live view.
- [ ] Ensure stop clears active strategy and callback references.

## Task 5: RemoteDesktop Background Audio Refresh

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Background detach starts a short interval that polls native audio state while preserved.
- Audio state transition false→true updates background modes and live view from notification to AVSession.
- Foreground restore and disconnect stop the poller.

- [ ] Add `backgroundAudioPollTimer`.
- [ ] Update background info when native audio activity changes.
- [ ] Stop live view and background task on foreground restore/disconnect.
- [ ] Keep protocol/decoder/audio untouched during background detach.

## Task 6: Verification And Exchange-State Update

**Files:**
- Modify external HANDOFF/TASKS/memory after verification.

**Verification Commands:**
- `cmake --build build\rdp-native-tests --target rdp_native_tests`
- `build\rdp-native-tests\rdp_native_tests.exe`
- DevEco `assembleHap`
- Device hilog checklist for RDP/RustDesk audio/no-audio, Home/foreground restore, AVSession pause/play, and no unexpected disconnect.
