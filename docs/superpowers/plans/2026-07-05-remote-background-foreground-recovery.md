# Remote Background Foreground Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make connected RDP and RustDesk sessions survive app backgrounding and recover a live picture after returning to the remote desktop page.

**Architecture:** Keep the existing background task, AVSession/live-view, active-session registry, and request-frame-refresh pump. Fix the restore sequencing bug by invalidating the ArkTS surface-ready flag after background detach and rebinding the native XComponent SurfaceId before foreground renderer initialization.

**Tech Stack:** HarmonyOS ArkTS, native NAPI renderer bridge, existing Hypium-style ArkTS policy tests, DevEco hvigor.

## Global Constraints

- Do not change RDP/RustDesk connection, auth, certificate, audio, clipboard, file transfer, rdpdr, or personalization setting semantics.
- Do not replace the existing background task / AVSession architecture with a fake media-only workaround.
- Background preservation may detach renderer/video presentation, but must preserve protocol and audio while the continuous task is active.
- Foreground restore must rebuild renderer/surface and request frame refresh without starting a second protocol connection.
- Existing safe teardown ordering remains mandatory: mark XComponent surface destroyed before destroying renderer.

---

### Task 1: Foreground Restore Policy

**Files:**
- Create: `entry/src/main/ets/services/RemoteForegroundRestorePolicy.ets`
- Create: `entry/src/test/RemoteForegroundRestorePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- `shouldInvalidateSurfaceAfterBackgroundDetach(rendererHandle: number, sessionId: number): boolean`
- `shouldBindSurfaceBeforeForegroundRenderer(surfaceId: string, width: number, height: number): boolean`
- `shouldPollSurfaceAfterForegroundRestore(bgRestorePending: boolean, sessionId: number, surfaceReady: boolean, cleanupStarted: boolean): boolean`

- [ ] **Step 1: Write failing tests**

Add tests asserting that a detached background renderer invalidates surface readiness, foreground reattach requires a non-empty SurfaceId and positive size before `initRenderer`, and restore-pending sessions poll when surface is not ready.

- [ ] **Step 2: Verify red**

Run the policy test target or production ArkTS build. Expected failure: missing `RemoteForegroundRestorePolicy` exports.

- [ ] **Step 3: Implement policy**

Implement only pure boolean helpers. Do not import ArkUI or native modules.

- [ ] **Step 4: Verify green**

Run the same verification and confirm the new tests compile/pass or the production build reaches later stages.

---

### Task 2: Surface Rebind Before Renderer Init

**Files:**
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`

**Interfaces:**
- Update `reattachRenderForForeground(surfaceId: string, width: number, height: number): ExtensionResult<number>`.

- [ ] **Step 1: Bind native surface first**

Call `rdpnapi.setXComponentSurfaceId(surfaceId, width, height)` before `rdpnapi.initRenderer(surfaceId, width, height)`.

- [ ] **Step 2: Fail early on invalid surface**

If the policy rejects the surface arguments or native surface binding returns false, return `ERR_SURFACE_INVALID` and do not call `initRenderer`.

- [ ] **Step 3: Keep existing handle behavior**

On success, store `rendererHandle` exactly as before. On exception, set it to `-1`.

---

### Task 3: RemoteDesktop Restore Sequencing

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consume `shouldInvalidateSurfaceAfterBackgroundDetach` and `shouldPollSurfaceAfterForegroundRestore`.

- [ ] **Step 1: Invalidate surface after background detach**

After renderer detach for background, set `surfaceReady=false` so foreground restore repolls or rebinds the SurfaceId instead of trusting the stale native window state.

- [ ] **Step 2: Preserve latest SurfaceId for fast restore**

Keep `latestSurfaceId` if known, so foreground restore can try to rebind immediately when the controller still reports the same surface.

- [ ] **Step 3: Poll when restore pending and surface is not ready**

Use the policy helper to keep `connectStarted=true` from blocking surface polling during restore.

- [ ] **Step 4: Log restore boundaries**

Add low-volume logs for detach invalidation and foreground surface rebind attempts.

---

### Task 4: Verification, Device Install, Docs, Commit

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`

**Interfaces:**
- Produces one commit with tests, code, plan, and verification notes.

- [ ] **Step 1: Run scoped diff checks**

Run `git diff --check` for touched files and `git diff --cached --check` before commit.

- [ ] **Step 2: Build**

Run DevEco `assembleHap`; expected result is `BUILD SUCCESSFUL`.

- [ ] **Step 3: Install and capture logs**

Install the HAP to the connected Pad target if available. Validate logs show detach, background task/live-view start, foreground surface rebind, renderer reattach, and restore refresh requests.

- [ ] **Step 4: Update docs and commit**

Update handoff/tasks/memory/CODEWALK with the new rule: foreground restore must rebind native SurfaceId before renderer init. Stage only touched files and commit with message `fix(remote): rebind surface on foreground restore`.
