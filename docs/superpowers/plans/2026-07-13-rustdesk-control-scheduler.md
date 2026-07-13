# RustDesk Control Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop RustDesk control backlog from starving encrypted receives and producing progressively higher long-session latency without dropping or reordering reliable input.

**Architecture:** Replace the unbounded `mpsc::Sender<ControlMsg>` / `Receiver<ControlMsg>` pair with a shared `ControlInbox`. The inbox stores reliable work in FIFO order and stores high-rate state work in coalescing slots. `run_streaming` consumes at most eight items per loop before servicing `crypto.recv`; disconnect uses an atomic stop request plus TCP shutdown before joining. Low-rate diagnostics identify whether later delay is in the inbox, network receive, or video callback/ACK path.

**Tech Stack:** Rust 2021, `std::sync::{Arc, Mutex, atomic}`, Rust unit tests, existing C ABI static library, OHOS arm64-v8a/x86_64 targets, DevEco/Hvigor.

**Execution status (2026-07-13):** Tasks 1-3 are implemented and committed as `9d0a0b70` and `b7e13da2`. Task 4 passed: both OHOS static archives were rebuilt, the 79-test Rust suite passed, and `assembleHap` produced a signed HAP. The SDK's LLVM 15 `llvm-nm` cannot read the Rust 1.96 LLVM 22 archive attributes, so native linkage was proved by finding `control diag reliable_depth=` in both ABI variants of the package's intermediate `librdpnapi.so`. Task 5 remains pending real-device runs.

## Global Constraints

- Work directly in `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`; do not use a separate worktree because release builds consume the main worktree's static FFI libraries.
- Preserve strict RustDesk IME ordering: `Text -> KeyEvent -> Text` must remain FIFO.
- Never drop key/text/button/wheel/clipboard/file-request work; only mouse movement, duplicate refreshes, and stale pressure values may coalesce.
- Do not change video frame ownership, decoder routing, audio routing, protocol packets, or C++/ArkTS public APIs in this phase.
- After Rust source edits, rebuild both OHOS static libraries before `assembleHap`.
- Use `cargo test --locked --all-targets --no-default-features` for host Rust verification; generated protobuf warnings are pre-existing.

---

### Task 1: Create the tested control inbox

**Files:**

- Create: `rustdesk_ffi/src/control_inbox.rs`
- Modify: `rustdesk_ffi/src/lib.rs:1-289`
- Test: `rustdesk_ffi/src/control_inbox.rs` (`#[cfg(test)]` module)

**Interfaces:**

- Produces `pub(crate) struct ControlInbox` with `enqueue(ControlMsg)`, `take_batch(limit) -> Vec<ControlMsg>`, `request_shutdown()`, `shutdown_requested()`, and `snapshot() -> ControlInboxSnapshot`.
- Consumes the existing `crate::ControlMsg` enum.
- `take_batch(8)` preserves FIFO reliable messages, then takes at most one latest mouse movement, one refresh, and one pressure update if capacity remains.

- [ ] **Step 1: Write failing inbox tests**

```rust
#[test]
fn mouse_moves_coalesce_to_the_latest_coordinate() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseMove { x: 1, y: 2 });
    inbox.enqueue(ControlMsg::MouseMove { x: 8, y: 9 });
    assert!(matches!(inbox.take_batch(8).as_slice(),
        [ControlMsg::MouseMove { x: 8, y: 9 }]));
    assert_eq!(inbox.snapshot().coalesced_mouse_moves, 1);
}

#[test]
fn reliable_ime_messages_remain_fifo_when_mouse_is_coalesced() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::Text { text: "中文😀".into() });
    inbox.enqueue(ControlMsg::MouseMove { x: 1, y: 2 });
    inbox.enqueue(ControlMsg::KeyEvent { scancode: 2014, pressed: true });
    inbox.enqueue(ControlMsg::Text { text: "X".into() });
    let batch = inbox.take_batch(8);
    assert!(matches!(batch[0], ControlMsg::Text { .. }));
    assert!(matches!(batch[1], ControlMsg::KeyEvent { .. }));
    assert!(matches!(batch[2], ControlMsg::Text { .. }));
}

#[test]
fn batch_limit_leaves_remaining_reliable_work_for_the_next_receive_turn() {
    let inbox = ControlInbox::default();
    for scancode in 0..9 { inbox.enqueue(ControlMsg::KeyEvent { scancode, pressed: true }); }
    assert_eq!(inbox.take_batch(8).len(), 8);
    assert_eq!(inbox.snapshot().reliable_depth, 1);
    assert_eq!(inbox.snapshot().batch_limit_hits, 1);
}
```

- [ ] **Step 2: Run the new tests and verify RED**

Run: `cargo test --locked control_inbox --no-default-features`

Expected: compilation fails because module `control_inbox` and `ControlInbox` do not yet exist.

- [ ] **Step 3: Implement the minimal inbox**

```rust
pub(crate) const CONTROL_BATCH_LIMIT: usize = 8;

pub(crate) struct ControlInbox {
    shutdown: AtomicBool,
    state: Mutex<ControlInboxState>,
}

struct ControlInboxState {
    reliable: VecDeque<ControlMsg>,
    mouse_move: Option<ControlMsg>,
    refresh_pending: bool,
    video_pressure: Option<u32>,
    snapshot: ControlInboxSnapshot,
}
```

`enqueue` must put only `MouseMove`, `RefreshVideo`, and `VideoPressure` into coalescing slots. It must push every other message into `reliable`. `take_batch` must pop FIFO reliable work first and must record a batch-limit hit whenever pending work remains after returning `limit` entries.

- [ ] **Step 4: Run focused inbox tests and the full Rust suite**

Run: `cargo test --locked control_inbox --no-default-features` then `cargo test --locked --all-targets --no-default-features`

Expected: all new inbox tests and the existing 72-test baseline pass.

- [ ] **Step 5: Commit the isolated inbox behavior**

```powershell
git add rustdesk_ffi/src/control_inbox.rs rustdesk_ffi/src/lib.rs
git commit -m "test(rustdesk): specify control inbox fairness"
```

### Task 2: Route FFI callers and streaming through the inbox

**Files:**

- Modify: `rustdesk_ffi/src/lib.rs:700-1070`
- Modify: `rustdesk_ffi/src/connector.rs:680-845`
- Test: `rustdesk_ffi/src/connector.rs:2060-2095`

**Interfaces:**

- `RustDeskClient` owns `controls: Arc<ControlInbox>` instead of `tx: Sender<ControlMsg>`.
- `RustDeskConnector::run_streaming(..., controls: Arc<ControlInbox>, ...)` replaces the `Receiver<ControlMsg>` argument.
- All exported FFI send functions call `controls.enqueue(...)`; their ABI and return values remain unchanged.

- [ ] **Step 1: Write failing connector scheduling tests**

Replace the mpsc-only IME test with an inbox-based test and add a pure helper test:

```rust
#[test]
fn control_batch_is_limited_before_the_next_receive_turn() {
    let inbox = Arc::new(ControlInbox::default());
    for scancode in 0..9 {
        inbox.enqueue(ControlMsg::KeyEvent { scancode, pressed: true });
    }
    assert_eq!(RustDeskConnector::next_control_batch(&inbox).len(), CONTROL_BATCH_LIMIT);
    assert_eq!(inbox.snapshot().reliable_depth, 1);
}
```

- [ ] **Step 2: Run the focused connector tests and verify RED**

Run: `cargo test --locked connector::tests::control_batch --no-default-features`

Expected: fails because `next_control_batch` does not yet exist or still accepts an mpsc receiver.

- [ ] **Step 3: Integrate the inbox with the FFI and loop**

```rust
let controls = Arc::new(ControlInbox::default());
let stream_controls = Arc::clone(&controls);
// spawn: c.run_streaming(..., stream_controls, ...)

for control in Self::next_control_batch(&controls) {
    if controls.shutdown_requested() { break 'streaming; }
    // retain the existing Shutdown/VideoPressure/SendFile/Clipboard/control-send handling
}
// after this bounded loop, execute exactly one crypto.recv() path.
```

Do not process an unbounded `try_recv()` loop. Preserve the existing `VideoPressure` branch that updates `requested_pressure_level`, and preserve clipboard/file special handling.

- [ ] **Step 4: Run focused and full Rust tests**

Run: `cargo test --locked connector::tests --no-default-features` then `cargo test --locked --all-targets --no-default-features`

Expected: IME FIFO and new batch-fairness tests pass; no test count regresses.

- [ ] **Step 5: Commit the scheduler integration**

```powershell
git add rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "fix(rustdesk): bound control scheduling per receive turn"
```

### Task 3: Make disconnect preempt backlog and add diagnostics

**Files:**

- Modify: `rustdesk_ffi/src/lib.rs:837-850`
- Modify: `rustdesk_ffi/src/connector.rs:710-950`
- Test: `rustdesk_ffi/src/control_inbox.rs`

**Interfaces:**

- `rustdesk_disconnect` calls `controls.request_shutdown()`, takes and shuts down `shutdown_stream`, then joins `stream_handle`.
- `ControlInboxSnapshot` contains `reliable_depth`, `max_reliable_depth`, `coalesced_mouse_moves`, `coalesced_refreshes`, `coalesced_video_pressure`, and `batch_limit_hits`.

- [ ] **Step 1: Write failing shutdown and diagnostic-state tests**

```rust
#[test]
fn shutdown_is_visible_without_waiting_for_a_queued_message() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::KeyEvent { scancode: 1, pressed: true });
    inbox.request_shutdown();
    assert!(inbox.shutdown_requested());
    assert_eq!(inbox.snapshot().reliable_depth, 1);
}

#[test]
fn duplicate_refresh_and_pressure_are_coalesced() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::RefreshVideo);
    inbox.enqueue(ControlMsg::RefreshVideo);
    inbox.enqueue(ControlMsg::VideoPressure { level: 1 });
    inbox.enqueue(ControlMsg::VideoPressure { level: 3 });
    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.coalesced_refreshes, 1);
    assert_eq!(snapshot.coalesced_video_pressure, 1);
}
```

- [ ] **Step 2: Run and verify RED**

Run: `cargo test --locked shutdown_is_visible duplicate_refresh_and_pressure --no-default-features`

Expected: fails until the atomic stop path and snapshot counters are implemented.

- [ ] **Step 3: Implement stop-first disconnect and low-rate logs**

```rust
ctx.controls.request_shutdown();
if let Some(stream) = ctx.shutdown_stream.take() {
    let _ = stream.shutdown(Shutdown::Both);
}
if let Some(handle) = ctx.stream_handle.take() {
    let _ = handle.join();
}
```

In `run_streaming`, once every five seconds log the inbox snapshot, last successful `crypto.recv()` gap, and batch-limit hits. Around `on_video(vf)` and `Session::send_video_received(crypto)`, measure elapsed time and log only slow calls or the five-second aggregate; do not change their synchronous ownership model.

- [ ] **Step 4: Run Rust tests**

Run: `cargo test --locked --all-targets --no-default-features`

Expected: all tests pass.

- [ ] **Step 5: Commit diagnostics and shutdown behavior**

```powershell
git add rustdesk_ffi/src/control_inbox.rs rustdesk_ffi/src/lib.rs rustdesk_ffi/src/connector.rs
git commit -m "fix(rustdesk): preempt backlog during disconnect"
```

### Task 4: Rebuild and verify HarmonyOS integration

**Files:**

- Generated: `rustdesk_ffi/target/aarch64-unknown-linux-ohos/release/librustdesk_ffi.a`
- Generated: `rustdesk_ffi/target/x86_64-unknown-linux-ohos/release/librustdesk_ffi.a`
- Verify only: `entry/src/main/cpp/CMakeLists.txt`

**Interfaces:**

- Both imported static libraries expose the unchanged C ABI consumed by `RustDeskBridge`.

- [ ] **Step 1: Rebuild both target libraries**

```powershell
Set-Location rustdesk_ffi
cargo +stable-x86_64-pc-windows-gnu build --locked --release --target aarch64-unknown-linux-ohos
cargo +stable-x86_64-pc-windows-gnu build --locked --release --target x86_64-unknown-linux-ohos
```

- [ ] **Step 2: Check the exported symbols remain present**

```powershell
llvm-nm target/aarch64-unknown-linux-ohos/release/librustdesk_ffi.a | Select-String 'rustdesk_(connect|disconnect|send_mouse|send_text)'
llvm-nm target/x86_64-unknown-linux-ohos/release/librustdesk_ffi.a | Select-String 'rustdesk_(connect|disconnect|send_mouse|send_text)'
```

Expected: each ABI reports all existing exported C entry points.

- [ ] **Step 3: Build the signed production HAP**

Run the project-standard `assembleHap` command from `CODEWALK.md` section 8.

Expected: `BUILD SUCCESSFUL`; retain any existing generated-protobuf or AGConnect warnings separately from failures.

- [ ] **Step 4: Commit source and plan state only**

```powershell
git add rustdesk_ffi/src docs/superpowers/specs/2026-07-13-rustdesk-control-scheduler-design.md docs/superpowers/plans/2026-07-13-rustdesk-control-scheduler.md
git commit -m "docs: record rustdesk control scheduler verification"
```

### Task 5: Device validation and phase-two gate

**Files:**

- Create: `docs/test-results/rustdesk-control-scheduler-2026-07-13.md`

- [ ] **Step 1: Capture four 30-60 minute runs**

1. No input.
2. Continuous mouse movement.
3. Mouse movement plus clicks and typing.
4. Repeat with video pressure reporting disabled for diagnosis only.

- [ ] **Step 2: Classify the result**

- Inbox depth and batch-limit hits grow with receive gaps: control scheduling root cause confirmed.
- Inbox stays stable while callback/ACK durations or video ingress gaps grow: plan a separate bounded video-dispatch worker.
- Video ingress is stable while decoder drops grow: tune local decoder only.
- Audio continues while video ingress stops with a stable inbox: inspect remote/relay/ACK cadence rather than reconnecting.

- [ ] **Step 3: Do not merge video-thread changes into this task**

Record the selected classification and create a separate design/plan before changing callback ownership, ACK timing, or `ffiHandle` lifetime.
