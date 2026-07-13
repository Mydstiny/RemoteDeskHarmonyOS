# SSH Terminal Optimization Work Log

## 2026-06-16

### Step 1: Repository And Plan Baseline

Status: completed.

Actions:

- Confirmed current working tree only had untracked `AGENTS.md` before this step.
- Confirmed `rustdesk_ffi` is a single lightweight Rust crate with `src/lib.rs`.
- Decided to place Phase 1 terminal core under `rustdesk_ffi/src/terminal_core/` instead of converting the repository to a Rust workspace.
- Created the regression baseline document at `docs/SSH_TERMINAL_TEST_CASES.md`.

Notes:

- `TerminalEmulator.ets` remains the fallback.
- No ArkTS UI behavior is changed in this step.

### Step 2: Minimal Rust Terminal Core

Status: completed with a local-tooling caveat.

Actions:

- Added `rustdesk_ffi/src/terminal_core/`.
- Added `Cell`, `CellAttrs`, row helpers, snapshot structs, `Terminal`, and a `vte::Perform` adapter.
- Added dependencies: `vte` and `unicode-width`.
- Added unit tests for plain text, newline, carriage return, backspace, clear screen, SGR color, scrollback, user scroll, bottom-following output, and resize.

Verification:

- Harmony build passed:
  `node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry assembleHap`

Blocked verification:

- `cargo test` was not executed because `cargo` and `rustc` are not available in the current PATH.
- Next executor with Rust installed should run `cargo test` inside `rustdesk_ffi/` before Phase 2.

### Step 3: Rust Toolchain And Core Hardening

Status: completed.

Actions:

- Installed Rustup into the user profile.
- Installed `stable-x86_64-pc-windows-msvc`; local tests could not link with it because `link.exe` is not installed.
- Installed `stable-x86_64-pc-windows-gnu` and used `C:\Strawberry\c\bin\gcc.exe` as the linker path.
- Fixed `vte 0.15` parser usage to pass byte slices to `Parser::advance`.
- Adjusted scrollback tests to use CRLF where shell output semantics require carriage return.
- Added terminal behavior support for:
  - `CSI J` modes 0, 1, 2, and 3
  - `CSI K` modes 0, 1, and 2
  - `CSI ?25l` / `CSI ?25h` cursor visibility
  - multi-parameter SGR coverage such as `1;31m`
  - scrollback trimming coverage
- Added `.gitignore` coverage for Rust `target/` build artifacts.

Verification:

- `cargo +stable-x86_64-pc-windows-gnu test`: 16 passed.
- `cargo +stable-x86_64-pc-windows-gnu fmt`: passed after installing rustfmt.
- Harmony build passed:
  `node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry assembleHap --info`

Next:

- Commit this Phase 1.5 hardening work.
- Start Phase 2 by designing the FFI/NAPI snapshot bridge without switching the current UI away from `TerminalEmulator.ets`.

### Step 4: Rust C ABI And ArkTS Bridge

Status: completed.

Actions:

- Added `rustdesk_ffi/src/terminal_core/ffi.rs`.
- Exported C ABI functions for:
  - `terminal_core_create`
  - `terminal_core_destroy`
  - `terminal_core_write`
  - `terminal_core_resize`
  - `terminal_core_scroll_view`
  - `terminal_core_scroll_to_bottom`
  - `terminal_core_snapshot`
  - `terminal_core_dirty_snapshot`
  - `terminal_core_free_snapshot`
- Added C-compatible snapshot structs for cells, dirty rows, cursor metadata, and viewport metadata.
- Added a Rust FFI roundtrip test.
- Added ArkTS bridge file: `entry/src/main/ets/napi/TerminalCoreBridge.ets`.
- Added terminalCore* declarations and snapshot interfaces to `entry/src/main/ets/types/rdpnapi.d.ts`.

Verification:

- `cargo +stable-x86_64-pc-windows-gnu test`: 17 passed.
- Harmony build passed:
  `node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry assembleHap --info`

Notes:

- The current SSH page still uses `TerminalEmulator.ets`.
- `TerminalCoreBridge.ets` is intentionally a dormant wrapper until C++ NAPI registers terminalCore* methods on `librdpnapi.so`.
- Next step is C++ NAPI registration and CMake linkage for the Rust terminal core.
