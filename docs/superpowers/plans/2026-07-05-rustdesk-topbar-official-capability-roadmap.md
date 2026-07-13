# RustDesk Topbar Official Capability Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track and incrementally land the remaining RustDesk topbar capabilities while keeping unfinished items explanatory instead of silent no-ops.

**Architecture:** Maintain one source of truth in `RemoteSessionTopBarPolicy.ets` for enabled/disabled state and user-facing reasons. Land low-risk ArkTS-only capabilities first, then add RustDesk Rust FFI/native bridge work for official protocol features.

**Tech Stack:** ArkTS/ArkUI, RustDesk Rust FFI, C++ NAPI, HarmonyOS permissions/media APIs, DevEco hvigor.

## Global Constraints

- RDP and RustDesk settings must stay independent: `rdp*` keys for RDP, `rustdesk*` keys for RustDesk.
- Visible unfinished topbar items must call `onUnsupported(actionId, reason)` and show a precise reason to the user.
- Do not alter RustDesk/RDP native video, audio, clipboard, or file-transfer pipelines unless the task explicitly implements that capability.
- Each capability must have a pure policy test before production code where feasible.

---

## Capability Backlog

### Task 1: Browser Mode (ArkTS-only, low risk) - Done 2026-07-05

**Goal:** Add `rustdeskBrowseMode` that makes RustDesk sessions view-only by blocking outgoing input while leaving video/audio/file-transfer intact.

**Files:**
- Create: `entry/src/main/ets/services/RemoteInputGuardPolicy.ets`
- Create: `entry/src/test/RemoteInputGuardPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`
- Modify: `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`
- Modify: `entry/src/main/ets/components/RemoteSessionTopBar.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Acceptance:**
- `浏览模式` appears enabled in the RustDesk topbar.
- Tapping it toggles a persisted `rustdeskBrowseMode` setting.
- When enabled, keyboard, mouse, touchpad, direct touch, gesture tap/pan, virtual key bar, and soft keyboard input are dropped for RustDesk only.
- RDP input and RustDesk video/audio/file transfer are not affected.

### Task 2: Screenshot (medium)

**Need:** Latest rendered frame bytes or renderer snapshot API, image encoder, user-visible save/share destination.

**How to get it:**
- Add renderer/latest-frame snapshot export through C++ NAPI, preferably from the latest decoded/rendered BGRA buffer.
- Encode PNG/JPEG using HarmonyOS image APIs or a small native encoder.
- Save via picker/media/file APIs and show success/failure toast.

### Task 3: Lock Remote Computer (medium)

**Need:** OS-aware remote lock action.

**How to get it:**
- Minimal Windows path: send Win+L with existing key dispatch path.
- Complete path: expose RustDesk peer OS/capability info through Rust FFI and map lock command per OS.

### Task 4: Resolution Switching (medium-high)

**Need:** RustDesk peer display/resolution list and switch-display/resize command.

**How to get it:**
- Read upstream RustDesk `pi.resolutions`, `display`, and `getResolutionMenu` paths.
- Expose peer info and display commands from Rust FFI to ArkTS.
- Add display menu state and switch command with failure reporting.

### Task 5: Virtual Display (high)

**Need:** RustDesk virtual-display capability, remote driver/support detection, command bridge.

**How to get it:**
- Confirm upstream protocol messages and peer feature flags.
- Expose feature flag and command through Rust FFI.
- Keep disabled when remote peer lacks support.

### Task 6: Text Chat (high)

**Need:** RustDesk chat message channel, receive callback/event stream, ArkTS chat overlay.

**How to get it:**
- Port upstream `ChatModel` send/receive flow into Rust FFI.
- Add NAPI callback/event queue.
- Build a session chat sheet/overlay with unread state.

### Task 7: Voice Call (high)

**Need:** microphone capture, Opus encode/decode, RustDesk voice-call signaling, permissions, audio focus/background policy.

**How to get it:**
- Complete real audio capturer path on HarmonyOS.
- Wire Opus encoding and RustDesk call signaling.
- Integrate call state and mute/hang-up UI.

### Task 8: Recording (high)

**Need:** frame capture, optional audio capture/mix, media encoder, file saving, long-running task policy.

**How to get it:**
- Reuse renderer/latest-frame tap or decoder output.
- Encode video with HarmonyOS media APIs, optionally mux audio later.
- Save to user location and expose recording state in the topbar.

## Required Rule For All Future Tasks

- Any topbar item that remains unfinished must stay visible but disabled with a precise user-facing reason.
- When a capability becomes partially available, gate it by actual capability/peer support instead of globally enabling it.
