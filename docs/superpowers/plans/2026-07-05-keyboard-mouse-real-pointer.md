# Keyboard Mouse Real Pointer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In PC mode and Pad/phone keyboard-mouse mode, show the real system mouse pointer and never reuse the touch-mode circular indicator as a mouse cursor.

**Architecture:** Keep the native RDP/RustDesk input forwarding path unchanged. Add a tiny ArkTS policy that separates touch feedback from keyboard-mouse pointer behavior, then wire `RemoteDesktop` to hide the touch indicator in keyboard-mouse mode and set the XComponent cursor to the system default pointer.

**Tech Stack:** HarmonyOS ArkTS, ArkUI XComponent, `@kit.InputKit` pointer styles, Hypium policy tests.

## Global Constraints

- Do not change RDP/RustDesk protocol, video, audio, clipboard, file-transfer, or personalization settings semantics.
- Touchpad/direct-touch modes keep the existing blue/red/orange circular touch feedback.
- Keyboard-mouse mode uses the system pointer (`pointer.PointerStyle.DEFAULT`) and must not draw the circular touch indicator.
- Existing ohosTest target may remain blocked by the known HostListPage parser/sourcemap issue; production `assembleHap` is the required build gate.

---

### Task 1: Pointer Mode Policy

**Files:**
- Create: `entry/src/main/ets/services/RemotePointerModePolicy.ets`
- Create: `entry/src/test/RemotePointerModePolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces: `shouldRenderTouchPointerIndicator(indicatorVisible: boolean, keyboardMouseMode: boolean): boolean`
- Produces: `shouldUseSystemMousePointer(keyboardMouseMode: boolean): boolean`

- [ ] **Step 1: Write failing test**

Add tests asserting keyboard-mouse mode never renders the touch indicator and does use the system pointer.

- [ ] **Step 2: Run test target**

Run `default@OhosTestBuildArkTS`. If blocked by the known HostListPage/sourcemap issue before reaching the new test, record the blocker.

- [ ] **Step 3: Implement policy**

Implement the two pure functions.

- [ ] **Step 4: Register test**

Import and call `remotePointerModePolicyTest()` from `List.test.ets`.

### Task 2: RemoteDesktop Integration

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes: `shouldRenderTouchPointerIndicator()`
- Consumes: `shouldUseSystemMousePointer()`

- [ ] **Step 1: Import pointer and policy**

Import `pointer` from `@kit.InputKit` and the new policy helpers.

- [ ] **Step 2: Replace touch indicator decision**

Make `shouldShowTouchIndicator()` return false whenever keyboard-mouse mode is active, regardless of RustDesk local cursor preference.

- [ ] **Step 3: Apply system pointer style**

Add `.cursor(pointer.PointerStyle.DEFAULT)` to the remote XComponent so external mouse devices show the real system arrow over the remote surface.

### Task 3: Verification and Delivery

**Files:**
- No new source files unless verification exposes a compile issue.

- [ ] **Step 1: Run scoped diff check**

Run `git diff --check` for touched files.

- [ ] **Step 2: Build production HAP**

Run the standard DevEco `assembleHap`.

- [ ] **Step 3: Install to emulator**

Install `entry-default-signed.hap` to `127.0.0.1:5555`.

- [ ] **Step 4: Update handoff and commit**

Update HANDOFF/TASKS/memory/CODEWALK only if a durable rule is added, then selected-files commit.
