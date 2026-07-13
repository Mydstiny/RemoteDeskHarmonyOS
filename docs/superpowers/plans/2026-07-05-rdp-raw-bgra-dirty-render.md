# RDP Raw BGRA Dirty Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve RDP render smoothness and power use by reducing full-frame CPU copies and GL texture uploads on the existing FreeRDP GDI raw BGRA path.

**Architecture:** Keep the current RDP protocol, settings, and channels unchanged. Add a dirty-rectangle render path that copies/uploads only the FreeRDP invalid region after the initial full frames, while retaining full-frame fallback whenever the dirty rectangle is invalid, too large, or the renderer is not ready.

**Tech Stack:** HarmonyOS ArkTS, native C++17, FreeRDP GDI, OpenGL ES 3.0, existing C++ unit test runner, DevEco hvigor.

## Global Constraints

- Do not change RDP user-facing personalization semantics: `rdpDesktopPreset`, `rdpColorDepth`, `rdpControlMode`, `rdpAudioEnabled`, `rdpClipboardEnabled`, `rdpDriveEnabled`, and `rdpDriveName` must continue to control the same behavior.
- Do not modify RDP connect/auth/certificate, rdpsnd audio, clipboard, rdpdr/shared drive, or RustDesk pipelines.
- Keep first frames full-frame rendered so initial desktop presentation and watchdog behavior remain reliable.
- Any dirty-rectangle optimization must fall back to full-frame rendering when coordinates are out of bounds or the dirty area is not meaningfully smaller than the full frame.
- Use masked logging only; do not log credentials or raw hostnames beyond existing safe-log behavior.

---

### Task 1: Dirty Rectangle Render Policy

**Files:**
- Modify: `entry/src/main/cpp/rdp/rdp_render_policy.h`
- Modify: `entry/src/main/cpp/test/rdp_render_policy_test.cpp`

**Interfaces:**
- Produces: `RdpRenderPolicy::DirtyRect` with `x`, `y`, `width`, `height`, `valid`.
- Produces: `RdpRenderPolicy::NormalizeDirtyRect(frameWidth, frameHeight, x, y, width, height)`.
- Produces: `RdpRenderPolicy::ShouldUseDirtyRect(renderedPaintCount, dirtyRect, fullFrameBytes)`.

- [ ] **Step 1: Write failing tests**

Add tests that assert:
- small in-bounds dirty rectangles are valid and selected after the first direct frames;
- invalid/out-of-bounds rectangles normalize to invalid;
- dirty rectangles covering most of the frame fall back to full-frame.

- [ ] **Step 2: Implement policy**

Add pure inline helpers to `rdp_render_policy.h`. Keep thresholds conservative: use dirty rect only after at least 3 rendered paints and only when dirty area is less than 70% of the frame.

- [ ] **Step 3: Run scoped native tests or build fallback**

Run the existing C++ unit test target if available. If local native test binary is not available, run production `assembleHap` later as the compiler-backed verification.

---

### Task 2: Frame Pump Carries Dirty Rectangles

**Files:**
- Modify: `entry/src/main/cpp/rdp/rdp_frame_pump.h`
- Modify: `entry/src/main/cpp/rdp/rdp_frame_pump.cpp`
- Modify: `entry/src/main/cpp/test/rdp_frame_pump_contract_test.cpp`

**Interfaces:**
- Update: `RdpFramePump::submitLatest(...)` gains dirty rectangle parameters.
- Preserve: latest-frame replacement semantics; only one pending frame is kept.

- [ ] **Step 1: Write failing contract tests**

Extend the contract test to verify the pump records submitted/replaced counts with dirty metadata and still accepts full-frame submissions.

- [ ] **Step 2: Implement metadata carry**

Store `dirtyX`, `dirtyY`, `dirtyW`, `dirtyH`, and `dirtyValid` beside the frame buffer. Pass those values to the renderer from the worker thread.

- [ ] **Step 3: Keep fallback compatibility**

If dirty metadata is invalid, render through the current full-frame path.

---

### Task 3: GL Partial Texture Upload

**Files:**
- Modify: `entry/src/main/cpp/render/gl_renderer.h`
- Modify: `entry/src/main/cpp/render/gl_renderer.cpp`

**Interfaces:**
- Add: `GLRenderer::RenderRawBGRARect(const uint8_t* bgraData, int width, int height, int stride, int dirtyX, int dirtyY, int dirtyW, int dirtyH)`.
- Add: `RendererNapi::RenderRawBgraRectActive(...)`.
- Preserve: `RenderRawBGRA(...)` full-frame behavior unchanged.

- [ ] **Step 1: Implement partial upload fallback**

The new method must initialize/rebuild the full texture exactly like `RenderRawBGRA`. If the dirty rect is invalid or dimensions changed, call `RenderRawBGRA`.

- [ ] **Step 2: Upload only dirty rows**

Use `GL_UNPACK_ROW_LENGTH` and a pointer offset `dirtyY * stride + dirtyX * 4`, then call `glTexSubImage2D(... dirtyX, dirtyY, dirtyW, dirtyH ...)`.

- [ ] **Step 3: Draw full textured quad**

After partial upload, clear/draw/swap using the same viewport and shader path as `RenderRawBGRA`, so coordinate mapping and visual output remain identical.

---

### Task 4: FreeRDP EndPaint Integration

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`

**Interfaces:**
- Consume: `NormalizeDirtyRect`, `ShouldUseDirtyRect`, and the frame pump dirty submission API.
- Preserve: first-frame direct rendering, watchdog stats, adaptive render interval, and existing channel settings.

- [ ] **Step 1: Normalize FreeRDP invalid rect**

Use `hwnd->invalid` and frame dimensions to create a safe dirty rect.

- [ ] **Step 2: Choose dirty vs full-frame per policy**

After the first direct frames, submit dirty metadata to the pump only when policy allows it. Otherwise submit/render full-frame.

- [ ] **Step 3: Log effectiveness**

Add low-volume diagnostics that show dirty rect size, mode (`dirty`/`full`), render interval, and existing perf counters.

---

### Task 5: Verification, Device Install, Docs, Commit

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` if durable rule changes.

**Interfaces:**
- Produces: one commit containing code, tests, and plan.

- [ ] **Step 1: Run diff checks**

Run `git diff --check` scoped to touched files and `git diff --cached --check` before commit.

- [ ] **Step 2: Build HAP**

Run DevEco `assembleHap`; expected result is `BUILD SUCCESSFUL`.

- [ ] **Step 3: Install on Pad**

Install the signed HAP to `192.168.31.118:40123` when connected.

- [ ] **Step 4: Validate logs**

Connect RDP and confirm logs show dirty/full mode diagnostics while existing RDP connection, audio, clipboard, drive, and settings logs remain present.

- [ ] **Step 5: Update docs and commit**

Update handoff/tasks/memory with validation evidence. Stage only touched code/test/plan files and commit with message `perf(rdp): upload dirty bgra regions`.
