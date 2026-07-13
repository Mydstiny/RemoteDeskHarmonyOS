# Remote Background Video LiveView Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RDP and RustDesk survive background suspension more reliably by presenting remote video sessions with a legitimate audio/video playback identity while preserving the existing protocol session and forcing a robust foreground video refresh.

**Architecture:** Keep the proven session-continuity model: background detach destroys only UI rendering, while RDP/RustDesk protocol, decoder input, audio, and session state remain alive. Add a media-state layer that distinguishes actual remote video and actual remote audio, then use one continuous background task with `multiDeviceConnection` plus `audioPlayback` only when real remote media is active. Live view selection becomes a reconciliation step: audio sessions prefer AVSession `audio`, video-only sessions may try AVSession `video`, and all failures fall back to notification without breaking the remote session.

**Tech Stack:** ArkTS strict mode, HarmonyOS API 23, BackgroundTasksKit, AVSessionKit, NotificationKit, XComponent, OpenGL ES renderer lifecycle, existing FreeRDP/RustDesk NAPI bridge, C++17 native tests, Hypium ArkTS policy tests, DevEco `assembleHap`.

## Execution Status — 2026-07-08

- Additional device recovery fix implemented after the initial AVSession/live-view work:
  - Root cause evidence: RustDesk stream and audio kept arriving after background restore, but local decoder/output stopped presenting frames (`render=0`, repeated decoder queue overflow, no output texture). This is a local decoder/NativeImage/output recovery boundary, not a protocol disconnect.
  - Fix scope: foreground restore now rebinds the renderer/decoder pipeline, arms decoder recovery, drops non-keyframes while recovery is armed, and recreates the local decoder from the next keyframe. Background detach now destroys only renderer/EGL resources and does not falsely mark XComponent surface destroyed.
  - RustDesk device validation: using the correct recent-task return path, `logs/restore_after_decoder_recovery_screen.jpeg` and `logs/codex_current_screen_20260708_133652.jpeg` show the remote desktop/video visible after restore; `logs/restore_after_decoder_recovery_20260708_133257.log` shows continuous `[Decoder] output texture=1 size=2560x1600` after return.
  - Invalid validation path: do not use `aa start -a EntryAbility -b com.example.remotedesktop` to return foreground. It can route the page and trigger explicit disconnect. Use recent tasks/card click instead.
  - Verification after this fix: `build\rdp-native-tests\rdp_native_tests.exe` passed 56/56; scoped `git diff --check` had only CRLF warnings; production `assembleHap` printed `BUILD SUCCESSFUL in 999 ms`.
- Implemented and committed through local recovery scope:
  - Task 3 re-review and shared RDP/RustDesk video activity wiring.
  - Task 9 RDP `rdpsnd` PCM boundary validation.
  - Task 4 media-driven background task modes.
  - Task 5 audio/video AVSession strategy with notification fallback.
  - Task 6 `RemoteDesktop` background media reconciliation.
  - Task 7 foreground restore escalation without protocol reconnect.
- Local verification on 2026-07-08:
  - `build\rdp-native-tests\rdp_native_tests.exe`: 46 passed, 0 failed.
  - DevEco production `assembleHap`: BUILD SUCCESSFUL in 824 ms.
  - Scoped `git diff --check` for the background media implementation files: no output.
- Pending before this plan can be marked fully complete:
  - Task 8 device validation for RDP video-only background/foreground restore.
  - Task 8 device validation for RDP audio+video background, AVSession pause/play, and foreground restore.
  - Task 8 device validation for RustDesk audio+video background, AVSession pause/play, and foreground restore.
  - Device confirmation that AVSession `video` either works or cleanly falls back to notification.
- RustDesk video-only/background restore has device evidence for the decoder recovery path, but the remaining audio+video and RDP matrix still needs separate device passes.
- Do not update `CODEWALK.md` with the permanent remote background media identity rule until the device matrix is confirmed.

## Global Constraints

- Do not reconnect RDP/RustDesk just to recover from background; preserve protocol sessions first and repair renderer lifecycle.
- Do not keep rendering into a stale XComponent surface while backgrounded.
- Do not destroy RustDesk decoder or RDP protocol state during background detach.
- Do not change RDP certificate bindSheet ordering, RDP ErrorInfo/no-frame sheet flow, RDP audio, clipboard, rdpdr/shared drive, or input semantics.
- Do not change RustDesk topbar actions, input preferences, browse mode, file transfer, clipboard, or relay semantics.
- Use actual native media activity, not user preference flags alone, to decide audio/video background identity.
- Use one API-12 continuous task with a mode list and `updateBackgroundRunning()`; do not start a second continuous task for the same UIAbility.
- `audioPlayback` is legitimate for audio/video playback, but must be paired with actual remote media activity.
- AVSession `audio` is valid only when actual remote audio PCM has been received.
- AVSession `video` is allowed only when actual remote video frames are flowing and no real remote audio is active.
- If AVSession or system live view fails, fall back to normal notification and keep the remote session alive.
- Every implementation task must add or update focused tests before changing production code.
- Every code change must build before commit. Stage and commit only files touched by that task.

---

## File Structure

- `entry/src/main/ets/services/RemoteSessionMediaStatePolicy.ets`
  Owns pure ArkTS decisions for `hasAudio`, `hasVideo`, AVSession kind, background modes, and refresh escalation.

- `entry/src/test/RemoteSessionMediaStatePolicy.test.ets`
  Local policy tests for media identity and restore escalation decisions.

- `entry/src/main/cpp/video/video_activity_state.h`
  Small native state holder for whether remote video frames have been received since the current session started.

- `entry/src/main/cpp/video/video_activity_state.cpp`
  Implementation for the video state holder.

- `entry/src/main/cpp/test/video_activity_state_test.cpp`
  Native tests for video activity state reset and frame tracking.

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
  Exposes `isVideoPlaybackActive()` and wires RDP/RustDesk frame callbacks to native video state.

- `entry/src/main/cpp/rdp/rdp_audio_policy.h`
  Pure policy for accepting only rdpsnd PCM that the native audio renderer can actually play.

- `entry/src/main/cpp/rdp/rdp_audio_policy.cpp`
  Implements RDP audio format validation and complete-frame byte trimming.

- `entry/src/main/cpp/test/rdp_audio_policy_test.cpp`
  Native tests for RDP rdpsnd PCM boundary handling.

- `entry/src/main/ets/types/rdpnapi.d.ts`
  Adds `isVideoPlaybackActive(): boolean`.

- `entry/src/main/ets/services/ExtensionLoader.ets`
  Adds `isVideoActive()` wrapper.

- `entry/src/main/ets/services/LiveViewTypes.ets`
  Extends live view info with `hasVideo` and `mediaKind`.

- `entry/src/main/ets/services/AvSessionLiveViewStrategy.ets`
  Creates AVSession with `audio` or `video` depending on resolved media kind.

- `entry/src/main/ets/services/RemoteSessionLiveViewService.ets`
  Adds reconciliation so mode changes restart strategies only when required.

- `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`
  Uses policy-generated mode lists and includes `audioPlayback` for actual audio or video media.

- `entry/src/main/ets/pages/RemoteDesktop.ets`
  Orchestrates background media polling, live view reconciliation, surface reattach, frame refresh, and restore escalation.

- `entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets`
  Extends existing foreground refresh tests.

- `entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets`
  Adds bounded restore escalation decisions.

- `entry/src/test/List.test.ets`
  Registers the new local policy test.

- `entry/src/ohosTest/ets/test/List.test.ets`
  Already imports restore tests; update only if a new ohosTest file is created.

---

### Task 1: Pure Media Identity Policy

**Files:**
- Create: `entry/src/main/ets/services/RemoteSessionMediaStatePolicy.ets`
- Create: `entry/src/test/RemoteSessionMediaStatePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces:
  - `export enum RemoteSessionMediaKind { NONE = 0, VIDEO = 1, AUDIO = 2 }`
  - `export interface RemoteSessionMediaSnapshot { hasAudio: boolean; hasVideo: boolean; }`
  - `export function resolveRemoteSessionMediaKind(snapshot: RemoteSessionMediaSnapshot): RemoteSessionMediaKind`
  - `export function backgroundModesForRemoteMedia(snapshot: RemoteSessionMediaSnapshot): string[]`
  - `export function shouldUseAvSessionForMedia(preferredMode: number, snapshot: RemoteSessionMediaSnapshot): boolean`

- [ ] **Step 1: Write the failing policy test**

Create `entry/src/test/RemoteSessionMediaStatePolicy.test.ets`:

```ts
import { describe, it, expect } from '@ohos/hypium';
import {
  backgroundModesForRemoteMedia,
  RemoteSessionMediaKind,
  resolveRemoteSessionMediaKind,
  shouldUseAvSessionForMedia
} from '../main/ets/services/RemoteSessionMediaStatePolicy';
import { LiveViewMode } from '../main/ets/services/LiveViewTypes';

export default function remoteSessionMediaStatePolicyTest(): void {
  describe('RemoteSessionMediaStatePolicy', (): void => {
    it('audio_takes_precedence_over_video_for_media_kind', 0, (): void => {
      expect(resolveRemoteSessionMediaKind({ hasAudio: true, hasVideo: true }))
        .assertEqual(RemoteSessionMediaKind.AUDIO);
      expect(resolveRemoteSessionMediaKind({ hasAudio: false, hasVideo: true }))
        .assertEqual(RemoteSessionMediaKind.VIDEO);
      expect(resolveRemoteSessionMediaKind({ hasAudio: false, hasVideo: false }))
        .assertEqual(RemoteSessionMediaKind.NONE);
    });

    it('adds_audio_playback_for_actual_audio_or_video_media', 0, (): void => {
      expect(backgroundModesForRemoteMedia({ hasAudio: false, hasVideo: false }).join(','))
        .assertEqual('multiDeviceConnection');
      expect(backgroundModesForRemoteMedia({ hasAudio: false, hasVideo: true }).join(','))
        .assertEqual('multiDeviceConnection,audioPlayback');
      expect(backgroundModesForRemoteMedia({ hasAudio: true, hasVideo: false }).join(','))
        .assertEqual('multiDeviceConnection,audioPlayback');
    });

    it('uses_avsession_only_when_preferred_and_media_exists', 0, (): void => {
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: false, hasVideo: true }))
        .assertTrue();
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: true, hasVideo: false }))
        .assertTrue();
      expect(shouldUseAvSessionForMedia(LiveViewMode.AVSESSION, { hasAudio: false, hasVideo: false }))
        .assertFalse();
      expect(shouldUseAvSessionForMedia(LiveViewMode.NOTIFICATION, { hasAudio: true, hasVideo: true }))
        .assertFalse();
    });
  });
}
```

Register it in `entry/src/test/List.test.ets`:

```ts
import remoteSessionMediaStatePolicyTest from './RemoteSessionMediaStatePolicy.test';

export default function testsuite() {
  // keep existing test calls
  remoteSessionMediaStatePolicyTest();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the local unit target normally used for `entry/src/test`. If the current DevEco test target is blocked by the known HostListPage parser/sourcemap issue, record that blocker and continue only after the production build in later tasks.

Expected failure before implementation: missing `RemoteSessionMediaStatePolicy` module.

- [ ] **Step 3: Implement the policy**

Create `entry/src/main/ets/services/RemoteSessionMediaStatePolicy.ets`:

```ts
import { LiveViewMode } from './LiveViewTypes';

export enum RemoteSessionMediaKind {
  NONE = 0,
  VIDEO = 1,
  AUDIO = 2
}

export interface RemoteSessionMediaSnapshot {
  hasAudio: boolean;
  hasVideo: boolean;
}

export function resolveRemoteSessionMediaKind(snapshot: RemoteSessionMediaSnapshot): RemoteSessionMediaKind {
  if (snapshot.hasAudio) {
    return RemoteSessionMediaKind.AUDIO;
  }
  if (snapshot.hasVideo) {
    return RemoteSessionMediaKind.VIDEO;
  }
  return RemoteSessionMediaKind.NONE;
}

export function backgroundModesForRemoteMedia(snapshot: RemoteSessionMediaSnapshot): string[] {
  const modes: string[] = ['multiDeviceConnection'];
  if (resolveRemoteSessionMediaKind(snapshot) !== RemoteSessionMediaKind.NONE) {
    modes.push('audioPlayback');
  }
  return modes;
}

export function shouldUseAvSessionForMedia(preferredMode: number,
  snapshot: RemoteSessionMediaSnapshot): boolean {
  if (preferredMode !== LiveViewMode.AVSESSION) {
    return false;
  }
  return resolveRemoteSessionMediaKind(snapshot) !== RemoteSessionMediaKind.NONE;
}
```

- [ ] **Step 4: Run tests and commit**

Run:

```powershell
git diff --check -- entry/src/main/ets/services/RemoteSessionMediaStatePolicy.ets entry/src/test/RemoteSessionMediaStatePolicy.test.ets entry/src/test/List.test.ets
```

Expected: no whitespace errors except existing repository CRLF warnings if present.

Then build before commit:

```powershell
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/ets/services/RemoteSessionMediaStatePolicy.ets entry/src/test/RemoteSessionMediaStatePolicy.test.ets entry/src/test/List.test.ets
git commit -m "test(remote): add media identity policy"
```

---

### Task 2: Native Video Activity State

**Files:**
- Create: `entry/src/main/cpp/video/video_activity_state.h`
- Create: `entry/src/main/cpp/video/video_activity_state.cpp`
- Create: `entry/src/main/cpp/test/video_activity_state_test.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `class VideoActivityState`
  - `void recordFrame(size_t bytes, int width, int height)`
  - `bool hasReceivedFrame() const`
  - `uint64_t frameCount() const`
  - `void reset()`

- [ ] **Step 1: Write the failing native test**

Create `entry/src/main/cpp/test/video_activity_state_test.cpp`:

```cpp
#include "test_runner.h"
#include "video/video_activity_state.h"

RDP_TEST_CASE(video_activity_starts_inactive_until_frame_arrives) {
    VideoActivityState state;
    RDP_ASSERT(!state.hasReceivedFrame());
    state.recordFrame(1920 * 1080 * 4, 1920, 1080);
    RDP_ASSERT(state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 1);
}

RDP_TEST_CASE(video_activity_ignores_invalid_frames) {
    VideoActivityState state;
    state.recordFrame(0, 1920, 1080);
    state.recordFrame(32, 0, 1080);
    state.recordFrame(32, 1920, 0);
    RDP_ASSERT(!state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 0);
}

RDP_TEST_CASE(video_activity_reset_clears_frame_state) {
    VideoActivityState state;
    state.recordFrame(4096, 64, 64);
    state.reset();
    RDP_ASSERT(!state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 0);
}
```

Update `entry/src/main/cpp/CMakeLists.txt` native test source list to include:

```cmake
test/video_activity_state_test.cpp
video/video_activity_state.cpp
```

- [ ] **Step 2: Run native tests to verify failure**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
```

Expected failure: missing `video/video_activity_state.h` or `VideoActivityState`.

- [ ] **Step 3: Implement native state**

Create `entry/src/main/cpp/video/video_activity_state.h`:

```cpp
#ifndef VIDEO_ACTIVITY_STATE_H
#define VIDEO_ACTIVITY_STATE_H

#include <atomic>
#include <cstddef>
#include <cstdint>

class VideoActivityState {
public:
    void recordFrame(size_t bytes, int width, int height);
    bool hasReceivedFrame() const;
    uint64_t frameCount() const;
    void reset();

private:
    std::atomic<bool> receivedFrame_ {false};
    std::atomic<uint64_t> frameCount_ {0};
};

#endif // VIDEO_ACTIVITY_STATE_H
```

Create `entry/src/main/cpp/video/video_activity_state.cpp`:

```cpp
#include "video_activity_state.h"

void VideoActivityState::recordFrame(size_t bytes, int width, int height) {
    if (bytes == 0 || width <= 0 || height <= 0) {
        return;
    }
    receivedFrame_.store(true);
    frameCount_.fetch_add(1);
}

bool VideoActivityState::hasReceivedFrame() const {
    return receivedFrame_.load();
}

uint64_t VideoActivityState::frameCount() const {
    return frameCount_.load();
}

void VideoActivityState::reset() {
    receivedFrame_.store(false);
    frameCount_.store(0);
}
```

- [ ] **Step 4: Run native tests and commit**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
```

Expected: all native tests pass, including the three video activity tests.

Build:

```powershell
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/cpp/video/video_activity_state.h entry/src/main/cpp/video/video_activity_state.cpp entry/src/main/cpp/test/video_activity_state_test.cpp entry/src/main/cpp/CMakeLists.txt
git commit -m "test(native): track remote video activity"
```

---

### Task 3: Expose Native Video Activity To ArkTS

**Files:**
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`

**Interfaces:**
- Consumes: `VideoActivityState::recordFrame()` and `VideoActivityState::hasReceivedFrame()`.
- Produces:
  - NAPI export `isVideoPlaybackActive(): boolean`
  - ArkTS wrapper `ExtensionLoader.isVideoActive(): boolean`

- [ ] **Step 1: Add declarations first**

In `entry/src/main/ets/types/rdpnapi.d.ts`, add near audio activity:

```ts
export function isVideoPlaybackActive(): boolean;
```

In `entry/src/main/ets/services/ExtensionLoader.ets`, add:

```ts
isVideoActive(): boolean {
  try {
    return rdpnapi.isVideoPlaybackActive() as boolean;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '[ExtensionLoader] isVideoActive fallback: ' + JSON.stringify(err));
    return false;
  }
}
```

- [ ] **Step 2: Wire native export**

In `entry/src/main/cpp/extensions/extension_loader_napi.cpp`, include:

```cpp
#include "video/video_activity_state.h"
```

Add a file-scope state near other active-session globals:

```cpp
static VideoActivityState g_videoActivityState;
```

Add helper:

```cpp
static napi_value NapiIsVideoPlaybackActive(napi_env env, napi_callback_info /*info*/) {
    napi_value active;
    napi_get_boolean(env, g_videoActivityState.hasReceivedFrame(), &active);
    return active;
}
```

Register the export next to `requestFrameRefresh`:

```cpp
napi_create_function(env, "isVideoPlaybackActive", NAPI_AUTO_LENGTH,
    NapiIsVideoPlaybackActive, nullptr, &fn);
napi_set_named_property(env, exports, "isVideoPlaybackActive", fn);
```

- [ ] **Step 3: Record frames without changing render behavior**

In the RDP raw frame path where frame bytes, width, and height are already known before render submission, add:

```cpp
g_videoActivityState.recordFrame(static_cast<size_t>(stride) * static_cast<size_t>(height),
    width, height);
```

In the RustDesk decoded-video callback path where frame dimensions and size are known, add:

```cpp
g_videoActivityState.recordFrame(frameSize, frameWidth, frameHeight);
```

If the exact local variable names differ, use the existing values already passed into the decoder or renderer. Do not add extra frame copies.

- [ ] **Step 4: Reset state on full disconnect**

In `disconnectAll` and single-session disconnect cleanup paths in `extension_loader_napi.cpp`, add:

```cpp
g_videoActivityState.reset();
```

Do not reset this state during background render detach; background restore relies on knowing the preserved session had video.

- [ ] **Step 5: Verify and commit**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: native tests pass and HAP build succeeds.

Commit:

```powershell
git add entry/src/main/cpp/extensions/extension_loader_napi.cpp entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets
git commit -m "feat(remote): expose video activity state"
```

---

### Task 4: Background Task Modes From Real Media

**Files:**
- Modify: `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`

**Interfaces:**
- Consumes: `backgroundModesForRemoteMedia(snapshot: RemoteSessionMediaSnapshot): string[]`.
- Produces:
  - `RemoteSessionBgInfo.hasVideo: boolean`
  - one continuous task mode list: `['multiDeviceConnection']` or `['multiDeviceConnection', 'audioPlayback']`

- [ ] **Step 1: Update `RemoteSessionBgInfo`**

Change:

```ts
export interface RemoteSessionBgInfo {
  hostId: string;
  sessionId: number;
  resumeRemoteSession: boolean;
  protocolLabel: string;
  hostAddress: string;
  hasAudio: boolean;
}
```

to:

```ts
export interface RemoteSessionBgInfo {
  hostId: string;
  sessionId: number;
  resumeRemoteSession: boolean;
  protocolLabel: string;
  hostAddress: string;
  hasAudio: boolean;
  hasVideo: boolean;
}
```

- [ ] **Step 2: Use media policy for mode calculation**

Import:

```ts
import { backgroundModesForRemoteMedia } from './RemoteSessionMediaStatePolicy';
```

Replace `modesForAudio(hasAudio: boolean)` with:

```ts
private modesForMedia(hasAudio: boolean, hasVideo: boolean): string[] {
  return backgroundModesForRemoteMedia({ hasAudio, hasVideo });
}
```

Change all call sites from:

```ts
const modes: string[] = this.modesForAudio(info.hasAudio);
const nextModes: string[] = this.modesForAudio(info.hasAudio);
```

to:

```ts
const modes: string[] = this.modesForMedia(info.hasAudio, info.hasVideo);
const nextModes: string[] = this.modesForMedia(info.hasAudio, info.hasVideo);
```

- [ ] **Step 3: Keep notifications truthful**

Change the notification text to distinguish audio/video:

```ts
const mediaSuffix: string = info.hasAudio ? ' (含音频)' : (info.hasVideo ? ' (视频保活)' : '');
const text: string = '已连接 ' + info.hostAddress + mediaSuffix;
```

- [ ] **Step 4: Verify and commit**

Run:

```powershell
git diff --check -- entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets
git commit -m "feat(remote): drive background modes from media state"
```

---

### Task 5: AVSession Audio Or Video Strategy

**Files:**
- Modify: `entry/src/main/ets/services/LiveViewTypes.ets`
- Modify: `entry/src/main/ets/services/AvSessionLiveViewStrategy.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionLiveViewService.ets`

**Interfaces:**
- Consumes:
  - `RemoteSessionMediaKind`
  - `resolveRemoteSessionMediaKind(snapshot)`
- Produces:
  - `LiveViewConnectionInfo.hasVideo: boolean`
  - `LiveViewConnectionInfo.mediaKind: RemoteSessionMediaKind`
  - `RemoteSessionLiveViewService.reconcile(context, info): Promise<void>`

- [ ] **Step 1: Extend live view info**

In `LiveViewTypes.ets`, import media kind:

```ts
import { RemoteSessionMediaKind } from './RemoteSessionMediaStatePolicy';
```

Extend `LiveViewConnectionInfo`:

```ts
hasAudio: boolean;
hasVideo: boolean;
mediaKind: RemoteSessionMediaKind;
```

Update `resolveLiveViewMode()` so AVSession is allowed for audio or video:

```ts
export function resolveLiveViewMode(preferredMode: number, hasAudio: boolean,
  hasVideo: boolean = false): LiveViewMode {
  if (preferredMode === LiveViewMode.OFF) {
    return LiveViewMode.OFF;
  }
  if (preferredMode === LiveViewMode.NOTIFICATION) {
    return LiveViewMode.NOTIFICATION;
  }
  if (preferredMode === LiveViewMode.AVSESSION) {
    return hasAudio || hasVideo ? LiveViewMode.AVSESSION : LiveViewMode.NOTIFICATION;
  }
  return hasAudio || hasVideo ? LiveViewMode.AVSESSION : LiveViewMode.NOTIFICATION;
}
```

- [ ] **Step 2: Create AVSession with correct type**

In `AvSessionLiveViewStrategy.start()`, replace:

```ts
this.session = await avSession.createAVSession(
  context, SESSION_TAG, 'audio');
```

with:

```ts
const sessionType: avSession.AVSessionType =
  info.mediaKind === RemoteSessionMediaKind.VIDEO ? 'video' : 'audio';
this.session = await avSession.createAVSession(context, SESSION_TAG, sessionType);
```

Use truthful metadata:

```ts
const stateText: string = info.mediaKind === RemoteSessionMediaKind.VIDEO ?
  '远端视频连接保活中' : '远端音频播放中';
```

Only register play/pause mute controls for audio:

```ts
if (info.mediaKind === RemoteSessionMediaKind.AUDIO) {
  this.session.on('play', this.handlePlayCommand);
  this.session.on('pause', this.handlePauseCommand);
}
```

In `stop()`, keep `off('play')`/`off('pause')` inside try/catch as currently done.

- [ ] **Step 3: Add reconcile to avoid unnecessary restarts**

In `RemoteSessionLiveViewService.ets`, add fields:

```ts
private currentMediaKind: RemoteSessionMediaKind = RemoteSessionMediaKind.NONE;
private currentHasAudio: boolean = false;
private currentHasVideo: boolean = false;
```

Add:

```ts
async reconcile(context: common.UIAbilityContext, info: LiveViewConnectionInfo): Promise<void> {
  const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
  if (!enabled) {
    await this.stop(context);
    return;
  }
  const preferredMode: number = AppStorage.get<number>('liveViewMode') ?? LiveViewMode.AVSESSION;
  const nextMode: LiveViewMode = resolveLiveViewMode(preferredMode, info.hasAudio, info.hasVideo);
  const kindChanged: boolean = info.mediaKind !== this.currentMediaKind;
  const modeChanged: boolean = nextMode !== this.currentMode;
  if (this.activeStrategy === null || modeChanged || kindChanged) {
    await this.start(context, info);
    return;
  }
  await this.update(info);
}
```

At the end of successful `start()`, set:

```ts
this.currentMediaKind = info.mediaKind;
this.currentHasAudio = info.hasAudio;
this.currentHasVideo = info.hasVideo;
```

In `stop()` finally block, reset those fields.

- [ ] **Step 4: Verify and commit**

Run:

```powershell
git diff --check -- entry/src/main/ets/services/LiveViewTypes.ets entry/src/main/ets/services/AvSessionLiveViewStrategy.ets entry/src/main/ets/services/RemoteSessionLiveViewService.ets
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/ets/services/LiveViewTypes.ets entry/src/main/ets/services/AvSessionLiveViewStrategy.ets entry/src/main/ets/services/RemoteSessionLiveViewService.ets
git commit -m "feat(remote): support video avsession live view"
```

---

### Task 6: RemoteDesktop Background Media Reconciliation

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes:
  - `ExtensionLoader.isAudioActive(): boolean`
  - `ExtensionLoader.isVideoActive(): boolean`
  - `resolveRemoteSessionMediaKind(snapshot)`
  - `RemoteSessionLiveViewService.reconcile(context, info)`
  - `RemoteSessionBgInfo.hasVideo`

- [ ] **Step 1: Add background video state fields**

Near existing background fields:

```ts
private backgroundHasVideo: boolean = false;
```

- [ ] **Step 2: Build one helper for current media**

Add:

```ts
private currentRemoteMediaSnapshot(): RemoteSessionMediaSnapshot {
  return {
    hasAudio: this.loader.isAudioActive(),
    hasVideo: this.loader.isVideoActive()
  };
}
```

Import:

```ts
import {
  RemoteSessionMediaSnapshot,
  resolveRemoteSessionMediaKind
} from '../services/RemoteSessionMediaStatePolicy';
```

- [ ] **Step 3: Include video in background info**

In `detachForBackground()`, replace:

```ts
const hasAudio: boolean = this.loader.isAudioActive();
const info: RemoteSessionBgInfo = {
  hostId: this.pendingHost.id,
  sessionId: this.sessionId,
  resumeRemoteSession: true,
  protocolLabel: this.pendingHost.protocol === 'rdp' ? 'RDP' : 'RustDesk',
  hostAddress: this.pendingHost.host,
  hasAudio: hasAudio
};
```

with:

```ts
const media: RemoteSessionMediaSnapshot = this.currentRemoteMediaSnapshot();
const info: RemoteSessionBgInfo = {
  hostId: this.pendingHost.id,
  sessionId: this.sessionId,
  resumeRemoteSession: true,
  protocolLabel: this.pendingHost.protocol === 'rdp' ? 'RDP' : 'RustDesk',
  hostAddress: this.pendingHost.host,
  hasAudio: media.hasAudio,
  hasVideo: media.hasVideo
};
```

- [ ] **Step 4: Start live view with media kind**

In `startSessionLiveView()`, create `liveViewInfo` as:

```ts
const liveViewInfo: LiveViewConnectionInfo = {
  hostId: info.hostId,
  sessionId: info.sessionId,
  protocolLabel: info.protocolLabel,
  hostAddress: info.hostAddress,
  hasAudio: info.hasAudio,
  hasVideo: info.hasVideo,
  mediaKind: resolveRemoteSessionMediaKind({
    hasAudio: info.hasAudio,
    hasVideo: info.hasVideo
  }),
  connectedAtMs: Date.now()
};
```

Replace:

```ts
await service.start(ctx, liveViewInfo);
```

with:

```ts
await service.reconcile(ctx, liveViewInfo);
```

Keep `setMuteCommandCallback()` only when `info.hasAudio` is true.

- [ ] **Step 5: Poll audio and video state**

In `startBackgroundAudioPolling()`, set:

```ts
this.backgroundHasVideo = info.hasVideo;
```

In `stopBackgroundAudioPolling()`, reset:

```ts
this.backgroundHasVideo = false;
```

In `refreshBackgroundAudioState()`, replace `hasAudio`-only logic with:

```ts
const media: RemoteSessionMediaSnapshot = this.currentRemoteMediaSnapshot();
if (media.hasAudio === this.backgroundHasAudio && media.hasVideo === this.backgroundHasVideo) {
  return;
}
this.backgroundHasAudio = media.hasAudio;
this.backgroundHasVideo = media.hasVideo;
const nextInfo: RemoteSessionBgInfo = {
  hostId: this.backgroundSessionInfo.hostId,
  sessionId: this.backgroundSessionInfo.sessionId,
  resumeRemoteSession: this.backgroundSessionInfo.resumeRemoteSession,
  protocolLabel: this.backgroundSessionInfo.protocolLabel,
  hostAddress: this.backgroundSessionInfo.hostAddress,
  hasAudio: media.hasAudio,
  hasVideo: media.hasVideo
};
```

Update log text:

```ts
hilog.info(RD_DOMAIN, RD_TAG, 'refreshBackgroundAudioState: hasAudio=' +
  (media.hasAudio ? 'true' : 'false') + ' hasVideo=' +
  (media.hasVideo ? 'true' : 'false'));
```

- [ ] **Step 6: Verify and commit**

Run:

```powershell
git diff --check -- entry/src/main/ets/pages/RemoteDesktop.ets
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "feat(remote): reconcile background media live view"
```

---

### Task 7: Foreground Restore Escalation Without Reconnect

**Files:**
- Modify: `entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets`
- Modify: `entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Produces:
  - `export enum RestoreRefreshAction { REQUEST_FRAME = 0, REBIND_SURFACE = 1, REPORT_STALLED = 2 }`
  - `export function restoreRefreshActionForDelay(delayMs: number): RestoreRefreshAction`

- [ ] **Step 1: Extend restore policy tests**

Append to `entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets`:

```ts
import { RestoreRefreshAction, restoreRefreshActionForDelay } from '../../../main/ets/services/RemoteRestoreFrameRefreshPolicy';

it('restore_escalates_to_surface_rebind_before_stall', 0, (): void => {
  expect(restoreRefreshActionForDelay(0)).assertEqual(RestoreRefreshAction.REQUEST_FRAME);
  expect(restoreRefreshActionForDelay(3000)).assertEqual(RestoreRefreshAction.REBIND_SURFACE);
  expect(restoreRefreshActionForDelay(10000)).assertEqual(RestoreRefreshAction.REPORT_STALLED);
});
```

- [ ] **Step 2: Implement policy enum**

In `RemoteRestoreFrameRefreshPolicy.ets`, add:

```ts
export enum RestoreRefreshAction {
  REQUEST_FRAME = 0,
  REBIND_SURFACE = 1,
  REPORT_STALLED = 2
}

export function restoreRefreshActionForDelay(delayMs: number): RestoreRefreshAction {
  if (delayMs >= 10000) {
    return RestoreRefreshAction.REPORT_STALLED;
  }
  if (delayMs >= 3000) {
    return RestoreRefreshAction.REBIND_SURFACE;
  }
  return RestoreRefreshAction.REQUEST_FRAME;
}
```

- [ ] **Step 3: Use escalation in `runRestoreFrameRefresh()`**

Import:

```ts
import {
  getRestoreFrameRefreshDelaysMs,
  RestoreRefreshAction,
  restoreRefreshActionForDelay,
  shouldRestoreRenderImmediately
} from '../services/RemoteRestoreFrameRefreshPolicy';
```

At the top of `runRestoreFrameRefresh()` after the skip guard:

```ts
const action: RestoreRefreshAction = restoreRefreshActionForDelay(delayMs);
if (action === RestoreRefreshAction.REBIND_SURFACE) {
  const desktop: DesktopSize = this.desktopSize(this.pendingHost);
  const surfaceId: string = this.latestSurfaceId.length > 0 ? this.latestSurfaceId : this.xcId;
  const result = this.loader.reattachRenderForForeground(surfaceId, desktop.width, desktop.height);
  if (result.ok && result.value !== undefined && result.value > 0) {
    this.rendererHandle = result.value;
    this.nativeHandles.markSurfaceAttached(this.rendererHandle);
    if (this.decoderHandle > 0) {
      this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: surface rebound delay=' +
      delayMs.toString());
  } else {
    hilog.warn(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: surface rebind failed delay=' +
      delayMs.toString() + ' code=' + result.code + ' msg=' + result.message);
  }
}
if (action === RestoreRefreshAction.REPORT_STALLED) {
  hilog.warn(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: restore still stalled after ' +
    delayMs.toString() + 'ms');
}
```

Then keep the existing `this.loader.requestFrameRefresh()` call for all actions so the rebind path also requests a fresh frame.

- [ ] **Step 4: Verify and commit**

Run:

```powershell
git diff --check -- entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets entry/src/main/ets/pages/RemoteDesktop.ets
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected: `BUILD SUCCESSFUL`.

Commit:

```powershell
git add entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "fix(remote): escalate foreground frame recovery"
```

---

### Task 8: Verification, Device Evidence, And Exchange State

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify only if new permanent rules are confirmed: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`

**Interfaces:**
- Produces verified device evidence for:
  - RDP video-only background and foreground restore
  - RDP audio+video background and AVSession pause/play
  - RustDesk video-only background and foreground restore
  - RustDesk audio+video background and AVSession pause/play
  - fallback notification when AVSession or system live view is rejected

- [ ] **Step 1: Run full local verification**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected:
- native tests pass
- production HAP build prints `BUILD SUCCESSFUL`
- no new failures in RDP certificate, RDP render, audio activity, or video activity tests

- [ ] **Step 2: RDP video-only device test**

On a stable Windows RDP host with no audible remote audio:

1. Connect RDP and wait for first frame.
2. Press Home or use task switch gesture.
3. Confirm logs include `detachForBackground`, `hasVideo=true`, `hasAudio=false`, and background modes include `audioPlayback`.
4. Confirm live view attempts AVSession `video` or falls back to notification.
5. Return to the app.
6. Confirm logs include `reattachRenderForForeground`, `requestFrameRefresh`, and no new protocol reconnect.
7. Confirm the remote screen refreshes without manual disconnect/reconnect.

- [ ] **Step 3: RDP audio+video device test**

On the same RDP host, play remote audio:

1. Confirm native logs show PCM activity.
2. Background the app.
3. Confirm `hasAudio=true`, media kind resolves to audio, and AVSession uses `audio`.
4. Use system media controls pause.
5. Confirm native logs show muted PCM drops and the session remains connected.
6. Use system media controls play.
7. Confirm audio resumes and foreground restore still refreshes video.

- [ ] **Step 4: RustDesk video-only device test**

1. Connect RustDesk with audio disabled or no remote audio.
2. Background the app.
3. Confirm `hasVideo=true`, `hasAudio=false`, and no RustDesk protocol reconnect.
4. Return foreground.
5. Confirm `refresh_video` or `requestFrameRefresh` is sent and the frame resumes.

- [ ] **Step 5: RustDesk audio+video device test**

1. Connect RustDesk with audio enabled and trigger remote audio.
2. Background the app.
3. Confirm native PCM activity drives `hasAudio=true`.
4. Confirm AVSession pause/play mutes/unmutes without recreating a new audio renderer loop.
5. Return foreground and confirm video refreshes.

- [ ] **Step 6: Update exchange state**

Update `HANDOFF.md` with:

```md
## Latest Handoff (Codex 2026-07-07 - Remote background video live view recovery)

- Commit: `<latest commit hash>`.
- Summary: Added media-state driven background identity for RDP/RustDesk, allowing video-only sessions to use audioPlayback + video AVSession when supported, while preserving protocol sessions and strengthening foreground restore refresh.
- Validation: native tests `<pass count>`; production `assembleHap` BUILD SUCCESSFUL; device evidence for RDP/RustDesk video-only and audio+video paths.
- Next device validation: continue long-run Home/foreground cycles and collect hilog for AVSession fallback behavior on unsupported devices.
```

Update `TASKS.md` by adding or completing the active task for remote background video live view recovery.

Update `remote-desktop-project-state.md` with the final commit, build result, and device validation status.

Only update `CODEWALK.md` after device validation confirms the rule. Add:

```md
## Codex Knowledge Update 2026-07-07 - Remote background media identity

- RDP/RustDesk background continuity must preserve protocol sessions and detach only renderer surfaces. Foreground recovery must rebind XComponent surface before requesting frames.
- Background `audioPlayback` may be used for actual remote audio or actual remote video activity, but must be driven by native media activity state rather than user preference flags.
- AVSession `audio` is reserved for real PCM activity. Video-only remote sessions may try AVSession `video`; failures must fall back to notification without disconnecting the session.
```

- [ ] **Step 7: Final commit**

Build first:

```powershell
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Commit only exchange files:

```powershell
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md
git commit -m "docs: record remote background media recovery"
```

---

### Task 9: Stabilize RDP rdpsnd PCM Boundary

> **Execution order:** run this task after Task 3 and before Task 4. It is numbered as Task 9 to avoid renumbering the already committed implementation plan.

**Files:**
- Create: `entry/src/main/cpp/rdp/rdp_audio_policy.h`
- Create: `entry/src/main/cpp/rdp/rdp_audio_policy.cpp`
- Create: `entry/src/main/cpp/test/rdp_audio_policy_test.cpp`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `struct RdpAudioPcmDecision`
  - `bool accepted`
  - `size_t bytesToSubmit`
  - `const char* reason`
  - `RdpAudioPcmDecision evaluateRdpAudioPcm(uint32_t sampleRate, uint16_t channels, uint16_t bitsPerSample, size_t byteCount)`

- [ ] **Step 1: Write failing native policy tests**

Create `entry/src/main/cpp/test/rdp_audio_policy_test.cpp`:

```cpp
#include "test_runner.h"
#include "rdp/rdp_audio_policy.h"

RDP_TEST_CASE(rdp_audio_policy_accepts_only_s16_pcm) {
    RdpAudioPcmDecision ok = evaluateRdpAudioPcm(48000, 2, 16, 4096);
    RDP_ASSERT(ok.accepted);
    RDP_ASSERT(ok.bytesToSubmit == 4096);

    RdpAudioPcmDecision rejected = evaluateRdpAudioPcm(48000, 2, 8, 4096);
    RDP_ASSERT(!rejected.accepted);
    RDP_ASSERT(rejected.bytesToSubmit == 0);
}

RDP_TEST_CASE(rdp_audio_policy_rejects_invalid_rate_or_channels) {
    RDP_ASSERT(!evaluateRdpAudioPcm(0, 2, 16, 4096).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(48000, 0, 16, 4096).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(48000, 9, 16, 4096).accepted);
}

RDP_TEST_CASE(rdp_audio_policy_trims_to_complete_s16_frames) {
    RdpAudioPcmDecision decision = evaluateRdpAudioPcm(44100, 2, 16, 4097);
    RDP_ASSERT(decision.accepted);
    RDP_ASSERT(decision.bytesToSubmit == 4096);
}

RDP_TEST_CASE(rdp_audio_policy_rejects_zero_or_too_small_pcm) {
    RDP_ASSERT(!evaluateRdpAudioPcm(44100, 2, 16, 0).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(44100, 2, 16, 3).accepted);
}
```

Update `entry/src/main/cpp/CMakeLists.txt` native test source list to include:

```cmake
test/rdp_audio_policy_test.cpp
rdp/rdp_audio_policy.cpp
```

- [ ] **Step 2: Run native test build to verify failure**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
```

Expected failure before implementation: missing `rdp/rdp_audio_policy.h` or `evaluateRdpAudioPcm`.

- [ ] **Step 3: Implement the policy**

Create `entry/src/main/cpp/rdp/rdp_audio_policy.h` and `.cpp`.

Rules:
- accept only `bitsPerSample == 16`
- reject `sampleRate == 0`
- reject `channels == 0` or `channels > 8`
- compute `frameBytes = channels * 2`
- trim `byteCount` down to a complete S16 frame
- reject if the trimmed byte count is `0`
- return a stable `reason` string for rejected decisions

- [ ] **Step 4: Apply policy at the rdpsnd bridge only**

In `entry/src/main/cpp/rdp/freerdp_adapter.cpp`, replace the current "forwarding raw PCM anyway" behavior with:
- call `evaluateRdpAudioPcm()`
- if rejected, log one low-volume warning and return without calling `AudioPlayerNapi::DispatchActiveNative`
- if accepted, submit only `bytesToSubmit`

Do not change RDP channel enablement, render callbacks, certificate flow, ErrorInfo/no-frame flow, clipboard, rdpdr/shared drive, input handling, or RustDesk.

- [ ] **Step 5: Verify and commit**

Run:

```powershell
cmake --build build\rdp-native-tests --target rdp_native_tests
build\rdp-native-tests\rdp_native_tests.exe
git diff --check -- entry/src/main/cpp/rdp entry/src/main/cpp/test entry/src/main/cpp/CMakeLists.txt
.\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap
```

Expected:
- native tests pass, including the new RDP audio policy tests
- production HAP build prints `BUILD SUCCESSFUL`
- no changes to render pipeline behavior

Commit:

```powershell
git add entry/src/main/cpp/rdp/rdp_audio_policy.h entry/src/main/cpp/rdp/rdp_audio_policy.cpp entry/src/main/cpp/test/rdp_audio_policy_test.cpp entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/CMakeLists.txt
git commit -m "fix(rdp): validate rdpsnd pcm boundary"
```

---

## Self-Review

- Spec coverage: The plan covers video-only background identity, audio+video AVSession behavior, one continuous background task, notification fallback, foreground surface rebind, refresh retries, and device validation for both RDP and RustDesk.
- Placeholder scan: The plan has no unfinished marker text or empty test instructions. Each task has explicit files, interfaces, commands, expected results, and code snippets.
- Type consistency: `RemoteSessionMediaSnapshot`, `RemoteSessionMediaKind`, `hasVideo`, `mediaKind`, `isVideoPlaybackActive()`, and `isVideoActive()` are introduced before later tasks consume them.
- Scope check: This is one bounded subsystem: remote background media identity and foreground recovery. It intentionally excludes host security lock, settings UI redesign, RDPGFX re-enable, and RustDesk topbar feature work.
