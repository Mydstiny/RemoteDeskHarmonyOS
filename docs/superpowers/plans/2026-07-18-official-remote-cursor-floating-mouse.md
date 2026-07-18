# Official Remote Cursor and Floating Mouse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the temporary text arrow with protocol-native RDP/RustDesk cursor shapes while retaining the optional circle, and add an opt-in RustDesk-style floating mouse controller for phone and Pad.

**Architecture:** RDP and RustDesk adapters normalize shape, hotspot, position, visibility, revisions, and session identity into a native `RemoteCursorSnapshot`. NAPI exposes a cheap metadata poll plus shape bytes only when the shape revision changes; ArkUI renders either the retained circle or the actual cursor and hosts a protocol-neutral floating controller that emits normalized mouse actions.

**Tech Stack:** HarmonyOS NEXT API 23, ArkTS/ArkUI, NAPI C++, FreeRDP pointer API, Rust FFI, RustDesk protobuf, Hypium, native C++ tests, Rust tests.

## Global Constraints

- Use only `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`; do not create a persistent worktree.
- Preserve unrelated dirty files and stage only the exact files named by each task.
- Keep RustDesk AGPL code behind the existing Rust FFI/process boundary; do not copy RustDesk Flutter source into the app.
- Do not change cloud table schemas. New defaults use the existing `usersettings` key/value adapter.
- Keep `virtualMouseStyle` storage values `circle | arrow`; `arrow` now means the protocol-native pointer and is the default only when no prior value exists.
- Existing users who explicitly stored `circle` remain on circle.
- Floating mouse and joystick default to off. Session-only state and controller position never upload to cloud.
- Direct touch hides the virtual cursor; touchpad mode shows circle or pointer; PC/physical mouse behavior remains unchanged.
- Any disconnect, cancellation, rotation, backgrounding, or component destruction must release held buttons and stop timers.
- Validate HarmonyOS APIs against local API 23 documentation before adding new image or gesture APIs.

---

## File Structure

### New files

- `entry/src/main/cpp/input/remote_cursor_snapshot.h`: bounded native cursor snapshot/store shared by protocol adapters.
- `entry/src/main/cpp/input/remote_cursor_snapshot.cpp`: validation, revision, cache, and copy implementation.
- `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`: native validation/session/revision tests.
- `rustdesk_ffi/src/cursor_state.rs`: RustDesk protobuf cursor cache and normalized update state.
- `entry/src/main/ets/services/RemoteCursorSnapshotPolicy.ets`: ArkTS snapshot validation, hotspot geometry, and polling decisions.
- `entry/src/test/RemoteCursorSnapshotPolicy.test.ets`: pure ArkTS cursor geometry and revision tests.
- `entry/src/main/ets/services/FloatingRemoteMousePolicy.ets`: safe-area positioning, collapse eligibility, joystick gain, and held-button policy.
- `entry/src/test/FloatingRemoteMousePolicy.test.ets`: pure controller policy tests.
- `entry/src/main/ets/components/RemoteCursorOverlay.ets`: circle/PixelMap/fallback cursor rendering.
- `entry/src/main/ets/components/FloatingRemoteMouse.ets`: floating buttons, wheel, drag handle, collapse, and optional joystick.

### Existing files to modify

- `entry/src/main/cpp/extensions/protocol_adapter.h`
- `entry/src/main/cpp/CMakeLists.txt`
- `entry/src/main/cpp/napi_init.cpp`
- `entry/src/main/cpp/rdp/freerdp_adapter.h`
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- `rustdesk_ffi/src/lib.rs`
- `rustdesk_ffi/src/connector.rs`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`
- `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
- `entry/src/test/RemoteCursorStylePolicy.test.ets`
- `entry/src/test/CloudSyncSettingsPolicy.test.ets`
- `entry/src/test/List.test.ets`

---

### Task 1: Native cursor snapshot contract

**Files:**
- Create: `entry/src/main/cpp/input/remote_cursor_snapshot.h`
- Create: `entry/src/main/cpp/input/remote_cursor_snapshot.cpp`
- Create: `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`
- Modify: `entry/src/main/cpp/extensions/protocol_adapter.h`
- Modify: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces: `RemoteCursorShape`, `RemoteCursorSnapshot`, `RemoteCursorStore::setShape`, `setPosition`, `setVisible`, `snapshot`, and `reset`.
- Produces: `ProtocolAdapter::getRemoteCursorSnapshot(bool includePixels)` with an empty default implementation.

- [ ] **Step 1: Write the failing native tests**

Add tests that require the store to reject malformed pixels, increment shape and position revisions independently, preserve hotspot, and clear session-owned state:

```cpp
RDP_TEST_CASE(remote_cursor_shape_revision_changes_only_for_valid_shape) {
    RemoteCursorStore store;
    store.reset(42, "rustdesk");
    const std::vector<uint8_t> rgba(16 * 16 * 4, 0xFF);
    RDP_REQUIRE(store.setShape(7, 16, 16, 2, 3, rgba));
    const auto first = store.snapshot(true);
    RDP_REQUIRE(first.shapeRevision == 1);
    RDP_REQUIRE(first.hotX == 2 && first.hotY == 3);
    RDP_REQUIRE(!store.setShape(8, 16, 16, 0, 0, std::vector<uint8_t>(3)));
    RDP_REQUIRE(store.snapshot(false).shapeRevision == 1);
}

RDP_TEST_CASE(remote_cursor_position_does_not_copy_or_rev_shape) {
    RemoteCursorStore store;
    store.reset(9, "rdp");
    store.setPosition(100, 200);
    const auto snap = store.snapshot(false);
    RDP_REQUIRE(snap.positionRevision == 1);
    RDP_REQUIRE(snap.shapeRevision == 0);
    RDP_REQUIRE(snap.rgba.empty());
}
```

- [ ] **Step 2: Build the native tests and verify RED**

Run the existing native test configure/build command recorded in `CURRENT.md`, then run:

```powershell
& 'C:\tmp\remotedesk-native-tests\rdp_native_tests.exe'
```

Expected: compile failure because `RemoteCursorStore` does not exist.

- [ ] **Step 3: Implement the bounded store**

Use exact limits and signatures:

```cpp
constexpr int kRemoteCursorMaxDimension = 384;
constexpr size_t kRemoteCursorMaxBytes = 384ULL * 384ULL * 4ULL;

struct RemoteCursorSnapshot {
    uint64_t sessionId = 0;
    std::string protocol;
    uint64_t shapeId = 0;
    int x = 0, y = 0, width = 0, height = 0, hotX = 0, hotY = 0;
    bool visible = false;
    uint64_t shapeRevision = 0, positionRevision = 0;
    std::vector<uint8_t> rgba;
};

class RemoteCursorStore {
public:
    void reset(uint64_t sessionId, const std::string& protocol);
    bool setShape(uint64_t shapeId, int width, int height, int hotX, int hotY,
                  const std::vector<uint8_t>& rgba);
    void setPosition(int x, int y);
    void setVisible(bool visible);
    RemoteCursorSnapshot snapshot(bool includePixels) const;
};
```

Protect state with one mutex; copy RGBA only when `includePixels` is true. Reject non-positive dimensions, dimensions above 384, non-matching `width * height * 4`, and hotspot outside the shape.

- [ ] **Step 4: Add the protocol default and CMake entries**

Add:

```cpp
virtual RemoteCursorSnapshot getRemoteCursorSnapshot(bool includePixels) {
    return {};
}
```

Register `input/remote_cursor_snapshot.cpp` in production and `test/remote_cursor_snapshot_test.cpp` in the native test executable.

- [ ] **Step 5: Run native tests and verify GREEN**

Expected: all existing tests plus the new cursor tests pass.

- [ ] **Step 6: Commit only Task 1 files**

```powershell
git add -- entry/src/main/cpp/input/remote_cursor_snapshot.h entry/src/main/cpp/input/remote_cursor_snapshot.cpp entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp entry/src/main/cpp/extensions/protocol_adapter.h entry/src/main/cpp/CMakeLists.txt
git commit -m "feat(input): add native remote cursor snapshot"
```

---

### Task 2: RustDesk cursor protobuf and FFI callback

**Files:**
- Create: `rustdesk_ffi/src/cursor_state.rs`
- Modify: `rustdesk_ffi/src/lib.rs`
- Modify: `rustdesk_ffi/src/connector.rs`

**Interfaces:**
- Produces: `CursorState::apply_data`, `apply_id`, `apply_position`, `current_shape`.
- Produces C ABI: `FfiCursorUpdate` and `CursorCallback` passed to `rustdesk_connect`.
- Consumes: RustDesk `CursorData`, `cursor_id`, and `CursorPosition` protobuf messages.

- [ ] **Step 1: Write failing Rust cursor-state tests**

```rust
#[test]
fn cursor_id_selects_cached_shape_and_preserves_hotspot() {
    let mut state = CursorState::new(4);
    state.apply_data(cursor_data(7, 2, 3, 16, 16, vec![255; 1024]));
    assert!(state.apply_id(7));
    let shape = state.current_shape().unwrap();
    assert_eq!((shape.hot_x, shape.hot_y), (2, 3));
}

#[test]
fn malformed_or_oversized_cursor_is_rejected() {
    let mut state = CursorState::new(4);
    assert!(!state.apply_data(cursor_data(1, 0, 0, 16, 16, vec![0; 3])));
    assert!(!state.apply_data(cursor_data(2, 0, 0, 385, 1, vec![0; 1540])));
}
```

- [ ] **Step 2: Run Rust tests and verify RED**

```powershell
cargo test --manifest-path rustdesk_ffi/Cargo.toml cursor_state -- --nocapture
```

Expected: compile failure because `cursor_state` is absent.

- [ ] **Step 3: Implement bounded RustDesk cache**

Implement a four-entry LRU-like cache keyed by cursor ID. Validate maximum 384×384, RGBA length, and hotspot. `colors` is copied once on `cursor_data`; `cursor_id` emits the cached shape without reparsing.

- [ ] **Step 4: Extend the C ABI**

```rust
#[repr(C)]
pub struct FfiCursorUpdate {
    pub kind: c_int, // 0=shape, 1=position, 2=visibility
    pub shape_id: u64,
    pub x: c_int,
    pub y: c_int,
    pub width: c_int,
    pub height: c_int,
    pub hot_x: c_int,
    pub hot_y: c_int,
    pub rgba: *const u8,
    pub rgba_len: usize,
    pub visible: bool,
}

pub type CursorCallback = extern "C" fn(*const FfiCursorUpdate, *mut c_void);
```

Add `on_cursor: Option<CursorCallback>` before `on_disconnect` in `rustdesk_connect`, update all call sites/tests, and guarantee callback buffers live for the duration of the call.

- [ ] **Step 5: Dispatch all cursor message kinds**

Replace the current count-only arms for `cursor_data` and `cursor_position`, and add the missing `cursor_id` arm. Emit shape updates only after validation, position updates for every changed position, and visible=true with a selected valid shape.

- [ ] **Step 6: Run full Rust tests**

```powershell
cargo test --manifest-path rustdesk_ffi/Cargo.toml --all-features
```

Expected: all Rust tests pass.

- [ ] **Step 7: Commit only Task 2 files**

```powershell
git add -- rustdesk_ffi/src/cursor_state.rs rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "feat(rustdesk): forward remote cursor updates"
```

---

### Task 3: RustDesk bridge integration

**Files:**
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.h`
- Modify: `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- Test: `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`

**Interfaces:**
- Consumes: `FfiCursorUpdate` from Task 2.
- Produces: `RustDeskBridge::getRemoteCursorSnapshot(bool)`.

- [ ] **Step 1: Add a failing callback-copy test**

Expose a small internal conversion helper that proves FFI bytes are copied before the callback returns and rejects a null pointer with non-zero length.

- [ ] **Step 2: Build and verify RED**

Expected: missing conversion helper / callback.

- [ ] **Step 3: Wire the FFI callback into `RemoteCursorStore`**

Add `RemoteCursorStore cursorStore` to `RustDeskBridge::Impl`, reset it with the active session generation at connect, clear it at disconnect, and map update kinds to `setShape`, `setPosition`, or `setVisible`. Do not log pixel bytes or raw peer identity.

- [ ] **Step 4: Add the adapter getter**

```cpp
RemoteCursorSnapshot RustDeskBridge::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}
```

- [ ] **Step 5: Rebuild Rust static library and native tests**

Run:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/build_rustdesk_ffi_ohos.sh all
& 'C:\tmp\remotedesk-native-tests\rdp_native_tests.exe'
```

Expected: both OHOS Rust targets build, the arm64-v8a C ABI links, and all native tests pass.

- [ ] **Step 6: Commit Task 3 source files**

```powershell
git add -- entry/src/main/cpp/rustdesk/rustdesk_bridge.h entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp
git commit -m "feat(rustdesk): bridge remote cursor snapshots"
```

The Rust static archives and target directories are generated and must not be staged.

---

### Task 4: FreeRDP pointer adapter

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`

**Interfaces:**
- Consumes: FreeRDP `rdpPointer` callbacks and `freerdp_image_copy_from_pointer_data`.
- Produces: `FreeRDPAdapter::getRemoteCursorSnapshot(bool)`.

- [ ] **Step 1: Write failing mask conversion/cache tests**

Create a tiny 2×2 known cursor fixture and assert BGRA from FreeRDP becomes RGBA with hotspot preserved; assert cached pointer selection reuses the converted shape and null/default visibility transitions are correct.

- [ ] **Step 2: Build and verify RED**

Expected: conversion/registration functions are missing.

- [ ] **Step 3: Implement an app-owned `rdpPointer` prototype**

Follow the vendored FreeRDP Android client pattern: `New` calls `freerdp_image_copy_from_pointer_data(..., PIXEL_FORMAT_BGRA32, ...)`, converts BGRA to RGBA, and stores shape data; `Free` releases app-owned memory; `Set`, `SetPosition`, `SetNull`, and `SetDefault` update `RemoteCursorStore`.

- [ ] **Step 4: Register after GDI is ready**

Call `graphics_register_pointer(context->graphics, &prototype)` in the established post-connect path. Reset the store before each connection and during teardown. Ensure callbacks never touch a destroyed adapter by using the existing context/session lifecycle.

- [ ] **Step 5: Run native tests**

Expected: all tests pass, including color, cached, null, default, and position cases.

- [ ] **Step 6: Commit Task 4 files**

```powershell
git add -- entry/src/main/cpp/rdp/freerdp_adapter.h entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp
git commit -m "feat(rdp): expose protocol-native cursor"
```

---

### Task 5: NAPI cursor snapshot bridge

**Files:**
- Modify: `entry/src/main/cpp/napi_init.cpp`
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`

**Interfaces:**
- Produces NAPI: `getRemoteCursorSnapshot(sessionId: number, includePixels: boolean): RemoteCursorSnapshot | null`.
- Consumes: `ProtocolAdapter::getRemoteCursorSnapshot(bool)`.

- [ ] **Step 1: Add a failing serialization test**

Test that metadata-only snapshots have no pixel buffer, shape requests return exactly `width * height * 4`, and unknown sessions return null.

- [ ] **Step 2: Implement NAPI serialization**

Return exact fields:

```ts
interface RemoteCursorSnapshot {
  sessionId: number;
  protocol: string;
  shapeId: number;
  x: number;
  y: number;
  width: number;
  height: number;
  hotX: number;
  hotY: number;
  visible: boolean;
  shapeRevision: number;
  positionRevision: number;
  rgba?: ArrayBuffer;
}
```

Use a copied ArrayBuffer only when requested. Never expose native vector memory with a lifetime shorter than the JS object.

- [ ] **Step 3: Run native tests and ArkTS compile**

Expected: serialization tests and `default@OhosTestCompileArkTS` pass.

- [ ] **Step 4: Commit Task 5 files**

```powershell
git add -- entry/src/main/cpp/napi_init.cpp entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp
git commit -m "feat(napi): bridge remote cursor snapshots"
```

---

### Task 6: ArkUI cursor policy, overlay, and default migration

**Files:**
- Create: `entry/src/main/ets/services/RemoteCursorSnapshotPolicy.ets`
- Create: `entry/src/test/RemoteCursorSnapshotPolicy.test.ets`
- Create: `entry/src/main/ets/components/RemoteCursorOverlay.ets`
- Modify: `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`
- Modify: `entry/src/test/RemoteCursorStylePolicy.test.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces: `shouldFetchCursorPixels(previousShapeRevision, nextShapeRevision)` and `cursorTopLeft(hitX, hitY, hotX, hotY, scale)`.
- Produces component props: `RemoteCursorOverlay({ style, connected, touchpadMode, hitX, hitY, buttonState, snapshot })`.
- Consumes: NAPI `RemoteCursorSnapshot` from Task 5.

- [ ] **Step 1: Write failing ArkTS policy tests**

```ts
expect(shouldFetchCursorPixels(3, 3)).assertFalse();
expect(shouldFetchCursorPixels(3, 4)).assertTrue();
const point = cursorTopLeft(100, 80, 4, 6, 1.5);
expect(point.x).assertEqual(94);
expect(point.y).assertEqual(71);
expect(normalizeRemoteCursorStyle(undefined)).assertEqual('arrow');
expect(normalizeRemoteCursorStyle('circle')).assertEqual('circle');
```

- [ ] **Step 2: Run test compile and verify RED**

Expected: missing policy/component symbols.

- [ ] **Step 3: Implement polling and PixelMap lifecycle**

Poll metadata at a bounded 16–33 ms interval only while connected and foreground. Request pixels only on shape revision change. Create an RGBA_8888 PixelMap from the copied ArrayBuffer using the verified API 23 image API; release the previous PixelMap after replacement and release the final PixelMap on disappearance.

- [ ] **Step 4: Implement overlay branches**

- Circle: retain current ring/dot/button colors centered on the hit point.
- Arrow/real pointer: render PixelMap at `hitPoint - hotspot`; use an app-owned black/white SVG or Path arrow only while no valid shape exists.
- Both: `HitTestMode.None`, same remote-to-local mapping, same reactive cursor revision.

Delete the temporary `Text('➤')` branch completely.

- [ ] **Step 5: Change only the missing-value default**

Set `@StorageLink('virtualMouseStyle')` defaults and `normalizeRemoteCursorStyle(undefined/invalid)` to `arrow`. During preferences initialization, use a presence check before applying the default so stored `circle` is never overwritten. Rename the visible option to `鼠标指针` without changing its stored `arrow` value.

- [ ] **Step 6: Run ArkTS test compile and assembleHap**

Expected: both succeed; no PixelMap leak warning in a connect/disconnect loop.

- [ ] **Step 7: Commit Task 6 files**

Stage only the exact files listed in this task.

---

### Task 7: Floating mouse policies, component, and preferences

**Files:**
- Create: `entry/src/main/ets/services/FloatingRemoteMousePolicy.ets`
- Create: `entry/src/test/FloatingRemoteMousePolicy.test.ets`
- Create: `entry/src/main/ets/components/FloatingRemoteMouse.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
- Modify: `entry/src/test/CloudSyncSettingsPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces: `clampFloatingMousePosition`, `restoreNormalizedPosition`, `joystickVelocity`, `shouldAutoCollapse`, and `buttonsToRelease`.
- Produces component callbacks: `onMove(dx, dy)`, `onButton(button, pressed)`, `onWheel(delta)`, and `onPositionChanged(normalizedX, normalizedY)`.
- Consumes: existing `sendMouseNow`, `sendMouseWheel`, remote cursor coordinates, and safe-area dimensions.

- [ ] **Step 1: Write failing policy tests**

Cover safe-area clamping, rotation restore, 7-second collapse blocking while active, joystick dead zone/max velocity, and release of every held button on cancel.

- [ ] **Step 2: Run ArkTS test compile and verify RED**

Expected: missing policy functions.

- [ ] **Step 3: Implement the protocol-neutral controller**

Build the controller from ArkUI shapes/symbols with: left/right press regions, wheel up/down repeat, middle click, drag handle, edge snapping, seven-second collapse timer, and optional joystick. Every down path records held state; every up/cancel/disappear path emits a paired release.

- [ ] **Step 4: Integrate session controls**

Add “悬浮实体鼠标” and dependent “虚拟摇杆” toggles to the existing control panel. Session toggles initialize from defaults at connection start but do not persist changes made inside the session.

- [ ] **Step 5: Add personalization defaults and cloud whitelist**

Use keys:

```text
floatingMouseDefaultEnabled = false
floatingMouseJoystickDefaultEnabled = false
```

Persist from personalization with the existing `persistPref` and `usersettings` flow. Keep normalized controller coordinates in local Preferences under device-local keys and out of `CloudSyncSettingsPolicy`.

- [ ] **Step 6: Run ArkTS tests and assembleHap**

Expected: all compile, cloud policy accepts only the two defaults, and session position/state keys are rejected.

- [ ] **Step 7: Commit Task 7 files**

Stage only the exact files listed in this task.

---

### Task 8: Integration, performance, and device verification

**Files:**
- No production file is planned for modification. A failing integration check returns to the task that owns that component before verification resumes.
- Update: `C:\Users\14288\.codex\projects\C--Users-14288\memory\CURRENT.md`
- Update: `C:\Users\14288\.codex\projects\C--Users-14288\memory\QUEUE.md`

**Interfaces:**
- Consumes all previous tasks.
- Produces a device-verified implementation and exact validation record.

- [ ] **Step 1: Run complete automated verification**

```powershell
cargo test --manifest-path rustdesk_ffi/Cargo.toml --all-features
& 'C:\tmp\remotedesk-native-tests\rdp_native_tests.exe'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --daemon
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify_open_source_release.ps1 -Mode Light
```

Expected: every command succeeds with zero new errors.

- [ ] **Step 2: Install on device 38451 and capture logs**

Install the signed HAP, clear only app log buffers if needed, and verify no malformed cursor rejection, stale session callback, PixelMap allocation loop, held-button leak, or render-frame regression.

- [ ] **Step 3: Verify RDP Windows**

Test normal, text, resize, busy, link, hidden/default, and drag cursors; circle/pointer switching; hotspot accuracy under scaling/letterbox; all official touchpad gestures; rotation and reconnect.

- [ ] **Step 4: Verify RustDesk Windows and macOS**

Repeat shape/hotspot/gesture checks in direct and relay modes. Confirm `cursor_data`, `cursor_id`, and `cursor_position` update the UI and that VP9 video cadence remains stable while the cursor moves.

- [ ] **Step 5: Verify floating controller on phone and Pad**

Check default off, session toggle, left/right/middle pairing, repeat wheel, joystick release, drag/snap, seven-second collapse, keyboard avoidance, portrait/landscape normalized position, background/disconnect cleanup, and circle/pointer coexistence.

- [ ] **Step 6: Update memory and make the final scoped commit**

Record exact command results and device findings. Stage only this feature's remaining files and memory files; do not stage `.appanalyzer/`, local signing files, unrelated plans, or user data.
