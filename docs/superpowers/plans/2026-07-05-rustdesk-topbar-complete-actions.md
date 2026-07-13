# RustDesk Topbar Complete Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the RustDesk in-session topbar auto-collapse when idle, replace low-quality text symbols with system icons, and ensure every visible menu item is either wired to RustDesk personalization/runtime behavior or disabled with a clear reason.

**Architecture:** Keep decisions in `RemoteSessionTopBarPolicy.ets`, keep `RemoteSessionTopBar.ets` UI-only, and keep runtime effects in `RemoteDesktop.ets` callbacks. RDP settings and RustDesk settings remain protocol-namespaced and independent.

**Tech Stack:** ArkTS, ArkUI `SymbolGlyph`, Hypium policy tests, DevEco hvigor production build.

## Global Constraints

- RustDesk topbar shows on PC all window sizes and on Pad/Phone only in keyboard-mouse mode.
- RDP must never render or be affected by the RustDesk topbar.
- RustDesk preferences use `rustdesk*`; RDP preferences use `rdp*`.
- Visible official RustDesk toolbar actions without a verified local/native bridge must be disabled with a reason, not clickable no-ops.
- Do not modify RDP/RustDesk native protocol, video, audio, clipboard, or file-transfer pipelines for this UI fix.

---

### Task 1: Policy Tests For Idle Collapse And Action Availability

**Files:**
- Modify: `entry/src/test/RemoteSessionTopBarPolicy.test.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`

**Interfaces:**
- Produces: `rustDeskTopBarAutoCollapseDelayMs(pinned: boolean, menuOpen: boolean): number`
- Produces: `rustDeskActionAvailability(actionId: string): RemoteTopBarActionAvailability`

- [x] **Step 1: Write failing tests**

Add tests asserting unpinned/no-menu returns `5000`, pinned returns `0`, menu-open returns `0`, and no-op items (`screenshot`, `resolutionSettings`, `virtualDisplay`, `browseMode`, `lockRemote`, `recordSession`) are disabled with reasons.

- [x] **Step 2: Run the relevant build/test command**

Run production build after the policy changes because ohosTest is currently blocked by existing HostListPage/sourcemap issues.

- [x] **Step 3: Implement policy**

Add the helper and reclassify unwired items as disabled. Keep existing enabled actions for disconnect, refresh, file transfer, Ctrl+Alt+Del, keyboard, display preferences, keyboard/mouse preferences, privacy, audio, clipboard, and file paste.

### Task 2: Topbar Timer And System Icons

**Files:**
- Modify: `entry/src/main/ets/components/RemoteSessionTopBar.ets`

**Interfaces:**
- Consumes: `rustDeskTopBarAutoCollapseDelayMs(pinned, menuOpen)`
- Consumes: `rustDeskActionAvailability(actionId)`

- [x] **Step 1: Replace text icons**

Use `SymbolGlyph` with system symbols already known in the project/docs: `ohos_lock`, `lock_fill`, `bolt_fill`, `desktop_fill`, `keyboard`, `message`, `record_circle`, `xmark`, `chevron_down`, `ellipsis_bubble`, and fallback after build if any symbol is unavailable.

- [x] **Step 2: Add inactivity collapse**

Schedule collapse after `5000ms` only when unpinned and no menu is open. Clear timers when pinned, menu open, or component disappears. Reschedule after user activity on the toolbar.

- [x] **Step 3: Remove clickable no-ops**

Point `分辨率`, `虚拟显示器`, `浏览模式`, `截屏`, `锁定远程电脑`, `录制`, chat/voice to distinct action IDs so disabled reasons are displayed instead of executing empty callbacks.

### Task 3: Runtime Callback Sanity

**Files:**
- Modify only if necessary: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Existing `rustDeskTopBarActions()` callbacks remain the runtime boundary.

- [x] **Step 1: Verify linked actions**

Confirm enabled items still call existing callbacks and persist `rustdesk*` preferences.

- [x] **Step 2: Keep unsupported callback path**

Unwired official features continue to show `toastUnsupportedRustDeskAction(actionId, reason)`.

### Task 4: Verification And Handoff

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if a durable rule changes.

- [x] **Step 1: Run checks**

Run scoped `git diff --check` and production `assembleHap`.

- [x] **Step 2: Preserve unrelated dirty files**

Stage only RustDesk topbar plan/code/test files unless intentionally committing previous verified pointer work separately.

- [x] **Step 3: Update handoff**

Record the root cause, fix, validation, and pending device checks.
