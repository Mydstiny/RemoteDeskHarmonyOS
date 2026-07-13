# SSH Terminal Open-Source Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring SSH terminal input, scrollback, per-row refresh, and cursor movement into parity with mature terminal projects.

**Architecture:** Keep ArkTS input as a thin adapter that routes all bytes through `SshTerminalInputPolicy`; keep Rust `terminal_core` as the authoritative VT state machine; keep ArkTS renderers responsible only for drawing snapshots and forwarding user scroll requests. Align the terminal state model with xterm.js/Alacritty/libvterm: primary screen creates scrollback, alternate screen does not, display viewport is separate from active cursor state, and damage/dirty rows drive repaint.

**Tech Stack:** ArkTS/ArkUI, Rust `terminal_core` with `vte`, C ABI/NAPI bridge, DevEco hvigor build.

## Global Constraints

- Do not reintroduce renderer-local grid shifting; T-283 proved it causes terminal information misalignment.
- Do not bypass `SshTerminalInputPolicy` from `SshTerminal.ets`, hidden `TextInput`, or `VirtualKeyBar`.
- PTY rows ignore transient soft-keyboard height and only subtract navigation/indicator plus `VirtualKeyBar.TOTAL_H`.
- Main-screen scrollback and alternate-screen behavior must match xterm-style terminals: primary screen history scrolls, alternate screen is independent and does not pollute main history.
- Every production code change must have a failing test first where feasible.
- Preserve unrelated dirty worktree files and only stage files touched for this SSH task.

---

## Reference Alignment

- xterm.js: `ybase`/`ydisp`, IME composition guard, input is `onData -> pty.write`.
- Alacritty: history size plus `display_offset`, scrollback creation only for full primary-screen scroll-up.
- libvterm: main screen top-line push callbacks for scrollback, alternate screen excluded.
- ConnectBot termlib: Android terminal surface uses libvterm-style terminal core with scrolling, resize, selection, and touch UI around the core.

## File Structure

- Modify `rustdesk_ffi/Cargo.toml`: add a host-test-friendly feature gate so terminal_core tests can run without linking Opus on Windows.
- Modify `rustdesk_ffi/src/lib.rs`: gate Opus audio module and audio decode queue behind the new feature while preserving OHOS release behavior.
- Modify `rustdesk_ffi/src/terminal_core/terminal.rs`: fix primary-screen scrollback, dirty row coverage, cursor row damage, trim behavior, and full/partial scroll region semantics.
- Modify `rustdesk_ffi/src/terminal_core/tests.rs`: add RED tests for scrollback, dirty rows, cursor old/new row, alternate screen, and scroll region parity.
- Modify `entry/src/main/ets/components/NativeTerminalRenderer.ets`: avoid forcing `followBottom=true` when viewport grows while the user is reading history; ensure grid-top changes trigger full repaint.
- Modify `entry/src/main/ets/components/TerminalEmulator.ets`: mirror fixed dirty-row/cursor/follow-bottom behavior for fallback.
- Modify `entry/src/test/SshTerminalInputPolicy.test.ets`: extend input edge coverage only if investigation finds missing cases.
- Modify `entry/src/test/SshTerminalScrollPolicy.test.ets`: extend viewport/follow-bottom policy coverage if ArkTS policy changes.

## Task 1: Make Terminal Core Tests Runnable

**Files:**
- Modify: `rustdesk_ffi/Cargo.toml`
- Modify: `rustdesk_ffi/src/lib.rs`

**Interfaces:**
- Produces: a host test path where `cargo +stable-x86_64-pc-windows-gnu test terminal_core::tests --lib --no-default-features` does not require `-lopus`.

- [ ] **Step 1: Write the failing verification command**

Run:

```powershell
cargo +stable-x86_64-pc-windows-gnu test terminal_core::tests::writing_past_bottom_scrolls_active_screen --lib --no-default-features
```

Expected before fix: link failure with `cannot find -lopus`.

- [ ] **Step 2: Gate Opus host linking**

Add a feature such as `opus-audio`, make OHOS release builds still enable/compile audio, and prevent host terminal_core tests from linking Opus.

- [ ] **Step 3: Run the test command**

Expected after fix: terminal_core test binary links and runs.

## Task 2: Lock Scrollback and Viewport Semantics

**Files:**
- Modify: `rustdesk_ffi/src/terminal_core/tests.rs`
- Modify later: `rustdesk_ffi/src/terminal_core/terminal.rs`

**Interfaces:**
- Produces: tests proving `screen_top`, `view_top`, and `is_at_bottom` match xterm/Alacritty primary-screen behavior.

- [ ] **Step 1: Add RED tests**

Tests:
- `primary_full_screen_scroll_creates_scrollback_history`
- `user_view_stays_parked_when_new_output_arrives`
- `scroll_region_inside_screen_does_not_create_scrollback`
- `alternate_screen_scroll_does_not_modify_main_scrollback`

- [ ] **Step 2: Run RED tests**

Expected: at least the primary-screen scrollback test fails because `screen_top` remains `0`.

- [ ] **Step 3: Fix Rust scroll behavior**

Implement primary full-screen scroll by advancing screen history; keep partial DECSTBM scrolls as in-screen row moves; keep alternate screen independent.

- [ ] **Step 4: Run GREEN tests**

Expected: all new terminal_core scrollback tests pass.

## Task 3: Lock Dirty Rows and Cursor Refresh

**Files:**
- Modify: `rustdesk_ffi/src/terminal_core/tests.rs`
- Modify later: `rustdesk_ffi/src/terminal_core/terminal.rs`

**Interfaces:**
- Produces: dirty row metadata that lets ArkTS repaint every changed row and old/new cursor rows.

- [ ] **Step 1: Add RED tests**

Tests:
- cursor movement marks old and new cursor rows dirty.
- full-screen scroll marks all visible rows dirty.
- `EL/ED/ICH/DCH/ECH/IL/DL` mark affected rows dirty and clear stale wrap markers.
- trim keeps `wrapped_rows`, `screen_top`, and `view_top` aligned.

- [ ] **Step 2: Run RED tests**

Expected: cursor movement dirty-row test fails if only the new row or no row is dirty.

- [ ] **Step 3: Fix dirty row bookkeeping**

Add a small helper that marks cursor old/new rows around cursor motion, and ensure row-moving operations mark all impacted visible rows.

- [ ] **Step 4: Run GREEN tests**

Expected: dirty row tests pass.

## Task 4: Align ArkTS Renderer Follow-Bottom and Repaint

**Files:**
- Modify: `entry/src/main/ets/components/NativeTerminalRenderer.ets`
- Modify: `entry/src/main/ets/components/TerminalEmulator.ets`
- Test: `entry/src/test/SshTerminalScrollPolicy.test.ets` if a pure policy is extracted.

**Interfaces:**
- Consumes: Rust snapshots with correct `screenTop/viewTop/dirtyRows`.
- Produces: no forced bottom jump while the user is viewing history; no residual old cursor or stale row artifacts.

- [ ] **Step 1: Add policy test if behavior can be pure**

Cover viewport growth while `followBottom=false` should not force `followBottom=true`.

- [ ] **Step 2: Update renderer behavior**

Only auto-scroll when already following bottom. Keep full repaint on grid-top, resize, and viewport-height changes.

- [ ] **Step 3: Build ArkTS**

Run `assembleHap`.

## Task 5: Recheck Unified Input and Virtual Keybar

**Files:**
- Modify: `entry/src/test/SshTerminalInputPolicy.test.ets`
- Modify only if needed: `entry/src/main/ets/services/SshTerminalInputPolicy.ets`
- Modify only if needed: `entry/src/main/ets/components/VirtualKeyBar.ets`
- Modify only if needed: `entry/src/main/ets/pages/SshTerminal.ets`

**Interfaces:**
- Produces: all keyboard paths still flow through one encoder and one send outlet.

- [ ] **Step 1: Add edge tests**

Cover CJK/emoji soft insert, multi-character soft delete, Shift/Ctrl/Alt text, Shift+Tab, modified arrows, and physical Backspace.

- [ ] **Step 2: Run ArkTS test target if available**

If ohosTest remains blocked by existing AGConnect/sourcemap issues, record the blocker and rely on source-level build plus test registration.

## Task 6: Full Verification and Handoff

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify if a permanent rule is established: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`

**Interfaces:**
- Produces: committed, build-verified SSH terminal repair with documented next device validation steps.

- [ ] **Step 1: Run Rust terminal_core tests**

Run the host terminal_core test command that no longer links Opus.

- [ ] **Step 2: Rebuild OHOS Rust static libraries if Rust changed**

Run both OHOS release targets for `aarch64-unknown-linux-ohos` and `x86_64-unknown-linux-ohos`.

- [ ] **Step 3: Run DevEco build**

Run `assembleHap` and require `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit touched SSH files only**

Stage only plan/code/test/handoff files owned by this task.

- [ ] **Step 5: Device validation checklist**

On device, verify:
- soft keyboard input, CJK/emoji, delete, enter.
- virtual Ctrl/Alt/Shift plus arrows/Home/End/PgUp/PgDn.
- long output beyond one page scrolls with `screenTop/viewTop` changing.
- alternate-screen apps such as `top`, `vim`, or `less` do not pollute shell history.
- no line misalignment, cursor residue, stale row, or forced jump while scrolled up.

---

## Execution Update 2026-07-01

- T-285 committed the primary-screen scrollback repair, Opus feature gate, cursor/dirty-row fixes, input edge tests, and initial Native renderer follow-bottom repair.
- Follow-up optimization centralized viewport-change auto-bottom behavior into `SshTerminalScrollPolicy` and wired both `NativeTerminalRenderer` and fallback `TerminalEmulator` through the same policy.
- Added ArkTS policy coverage for viewport growth while the user is parked in history, and for preserving bottom-following behavior while already at bottom.
- Added Rust terminal_core coverage proving soft-wrap cursor movement damages both old/new rows and full-screen scroll damages all visible rows.
- Verified on host and build chain:
  - `cargo +stable-x86_64-pc-windows-gnu test --lib --no-default-features` passed 70/70.
  - `cargo +stable-x86_64-pc-windows-gnu build --release --target aarch64-unknown-linux-ohos` passed.
  - `cargo +stable-x86_64-pc-windows-gnu build --release --target x86_64-unknown-linux-ohos` passed.
  - DevEco `assembleHap` passed with existing third-party/deprecation warnings only.
- Device validation is still pending because `hdc list targets` returned `[Empty]`.
