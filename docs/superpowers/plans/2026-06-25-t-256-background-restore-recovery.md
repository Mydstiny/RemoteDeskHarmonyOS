# T-256 Background Restore Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the background-preserved RDP/RustDesk session path that became incomplete after the `64e70822` / `aacd385` rollback.

**Architecture:** Keep existing RDP/RustDesk startup and renderer rules intact, and add a small persistent active-session registry that survives page recreation. `RemoteDesktop.ets` will use the registry plus `NativeSessionHandles` / `RemoteSessionState` for connect, background detach, foreground restore, and full disconnect decisions.

**Tech Stack:** ArkTS strict mode, HarmonyOS API 23, Hypium ohosTest, XComponent, existing `ExtensionLoader`, `RemoteSessionBackgroundTaskService`, and native NAPI wrappers.

## Global Constraints

- Follow `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`.
- No broad refactor before T-256 passes.
- Do not change RustDesk codec/FPS/quality policy; T-258 rollback remains the RustDesk runtime baseline.
- Do not add ArkTS TCP preflight to RDP startup.
- Keep RDP session size and local XComponent surface size separate.
- Preserve renderer teardown order: mark XComponent surface destroyed before destroying renderer.
- Do not fake remote-session keepalive as `dataTransfer`; file transfers alone use `dataTransfer`.
- Start `audioPlayback` only when real remote audio is active.
- Every large phase ends with self-check, build verification when code changed, and TASKS/HANDOFF/memory update.

---

### Task 1: Active Session Registry

**Files:**
- Create: `entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets`
- Test: `entry/src/ohosTest/ets/test/ActiveRemoteSessionRegistry.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces: `ActiveRemoteSessionRecord`, `ActiveRemoteSessionRegistry.getInstance()`, `setActive(record)`, `getActive()`, `hasRestorePending(hostId, sessionId)`, `markRenderDetached()`, `markRenderAttached(surfaceId)`, `markRestoreNeeded(value)`, `clear(reason)`, `resetForTest()`.
- Consumes: `RemoteProtocol` from `RemoteSessionState.ets`.

- [x] **Step 1: Write failing registry tests**

Add tests that create a registry record, simulate background detach, create a second registry reference, and assert the restore state is still visible.

- [x] **Step 2: Verify RED**

Run the narrowest available project verification. Expected before implementation: `ActiveRemoteSessionRegistry` import fails or tests fail because the class does not exist.

- [x] **Step 3: Implement registry**

Use `AppStorage` as the persistence backing so page instances can rediscover preserved sessions. Keep methods synchronous and deterministic.

- [x] **Step 4: Verify GREEN**

Default `assembleHap` compiles the registry and page integration. `default@OhosTestBuildArkTS` remains blocked by the existing `HostListPage.ets:1821:11 Declaration or statement expected` test-target issue, not by the new registry tests.

Run build/test verification. The new registry tests should compile and pass where ohosTest execution is available; `assembleHap` must compile.

### Task 2: Background Task Resume Metadata

**Files:**
- Modify: `entry/src/main/ets/services/RemoteSessionBackgroundTaskService.ets`
- Test: `entry/src/ohosTest/ets/test/RemoteSessionBackgroundTaskService.test.ets` if the API can be tested without Harmony background manager; otherwise verify by build and code review checklist.

**Interfaces:**
- Modify `RemoteSessionBgInfo` to include `hostId: string`, `sessionId: number`, and `resumeRemoteSession: boolean`.
- `startSessionTask(context, info)` must put those values into WantAgent parameters.
- `startSessionTask()` must call `startAudioPlaybackTask()` only through explicit caller logic or provide a safe helper that requires `info.hasAudio === true`.

- [x] **Step 1: Add compile-level test or typed helper test**
- [x] **Step 2: Verify RED**
- [x] **Step 3: Implement WantAgent parameter propagation**
- [x] **Step 4: Verify GREEN**

### Task 3: RemoteDesktop Registry And State Main-Path Wiring

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify as needed: `entry/src/main/ets/services/NativeSessionHandles.ets`
- Test: Extend `NativeSessionHandles.test.ets` for latest-surface reattach and idempotent disconnect behavior.

**Interfaces:**
- `RemoteDesktop` records current `surfaceId` in `onSurfaceCreated(surfaceId)`.
- On connect success, it calls registry `setActive()` and marks protocol/render attached.
- On background detach, it marks registry protocol connected + render detached + restore needed, keeps protocol alive, and stops only UI/render forwarding.
- On foreground/page recreation, `aboutToAppear()` checks registry before ordinary connect. If `resumeRemoteSession` or matching active record exists, it restores render instead of opening a new protocol session.
- Full disconnect clears registry and calls existing cleanup path.

- [x] **Step 1: Add failing tests around lifecycle helpers where extractable**
- [x] **Step 2: Verify RED**
- [x] **Step 3: Wire registry on connect/detach/restore/disconnect**
- [x] **Step 4: Verify GREEN**

### Task 4: Surface Restore And Resize

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets` only if needed for typed result consistency.

**Interfaces:**
- `doBackgroundRestoreRender()` uses the latest recorded surfaceId, not hard-coded `rdpSurface`.
- After renderer reattach, if `renderWidthPx/renderHeightPx` are known and differ from remote desktop size, call `resizeRenderer(rendererHandle, renderWidthPx, renderHeightPx)`.
- Request frame refresh remains best-effort and logs no-op / adapter support clearly.

- [x] **Step 1: Add or extend tests for `NativeSessionHandles.reattachRenderForForeground()` surface args**
- [x] **Step 2: Verify RED if new behavior is missing**
- [x] **Step 3: Implement latest-surface restore and post-reattach resize**
- [x] **Step 4: Verify GREEN**

Existing `NativeSessionHandles.test.ets` already asserts surfaceId/size propagation for reattach; page integration now uses the latest observed XComponent surfaceId and resizes renderer after restore when local surface pixels differ from remote desktop size.

### Task 5: Stage Self-Check And Handoff Update

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify `CODEWALK.md` only if a durable architecture rule changes.

**Verification commands:**
- `git diff --check`
- DevEco `assembleHap` command from `CODEWALK.md`
- If device is available, run the background continuity log command from `docs/RDP_RUSTDESK_BACKGROUND_CONTINUITY_TESTS.md`.

- [x] **Step 1: Run code-path checklist**
- [x] **Step 2: Run verification commands**
- [ ] **Step 3: Update TASKS/HANDOFF/memory**
- [ ] **Step 4: Commit after successful build**

## Self-Review

- Spec coverage: Covers registry, state/handle main-path wiring, background notification resume params, audioPlayback condition, surface restore, resize, and stage self-check.
- Placeholder scan: No TBD/TODO placeholders are required for implementation.
- Type consistency: Registry uses `RemoteProtocol`; background info uses explicit `hostId/sessionId/resumeRemoteSession`; RemoteDesktop consumes the same fields.
