# Shared Current State

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoints: `6924a1124` (`feat: harden remote sessions and SSH workspace`), `a9554a331` (`fix: harden DevEco builds and session recovery`), `10a8c02` (`perf: smooth RustDesk VP9 backpressure`) and `fec26e2` (`fix: close SFTP and pointer recovery races`).
- Phase: Level A hardening and accepted Pad/PC SFTP workspace; xterm.js remains the visible SSH renderer. Level B endpoint interoperability is still open.

## Current Outcome

- SSH sessions are keyed by session/channel/generation; tab detach, background/PiP ownership, reconnect, prompt brokerage and stale callback fencing no longer depend on one global active adapter.
- Password and keyboard-interactive authentication support multi-prompt/multi-round flows. Prompt responses remain one-shot and are cleared after handoff.
- SFTP uses durable endpoint-aware tasks. The Pad/PC workspace keeps the current SSH host on the left; the right side starts blank and changes only after `本机文件` or `选择 SSH 主机`. The nested host selector is an independent bindSheet. Phone keeps the 1.0.8 single-column bottom-sheet interaction.
- The wireless Pad interaction matrix was accepted on `192.168.3.236:40123`: root close/reopen, picker cancel/reopen, current/other host selection, SSH/local switching, repeated host replacement, list viewport and transfer-direction labels.
- SSH-to-SSH transfer is page-independent and binds both endpoint sessions explicitly. Native SFTP errors publish transport loss before their Promise resolves; the task engine consumes that signal before a reconnect can hide it. Atomic upload persists and flushes `commitState=renaming` before rename, recovers by checking the final target first, then persists `renamed`; late callbacks cannot overwrite pause/cancel.
- ProxyJump route modeling, forwarding lifecycle contracts and raw `frp_tcp` exist. Visitor/STCP/SUDP/XTCP remain explicit fail-closed routes until a version-locked FRP transport and real endpoints are available.
- RustDesk/RDP/VNC work already present in the mixed tree was preserved. RustDesk VP9 software pressure and high-resolution FPS ceiling changes are included in the current checkpoint; RDP Gateway trust stages remain separate and fail closed for unsupported credential combinations.

## IDE Build Repair

- The DevEco failure was caused by GUI PATH isolation: CMake found an absolute Cargo binary, but Cargo tried to launch bare `rustc`; the next hidden dependency was bare target `clang++`/sysroot flags.
- CMake now resolves and validates absolute Cargo plus matching rustc, preferring Cargo's sibling compiler before PATH/rustup fallback. It injects absolute OHOS C/C++/AR/linker paths and an absolute sysroot.
- `CARGO_ENCODED_RUSTFLAGS` preserves a Windows DevEco sysroot containing spaces. The generated Ninja command no longer depends on shell PATH for cargo, rustc or clang++.
- Stale generated conflict files such as `string 2.json` and duplicated SVGs were isolated by rebuilding `entry/build` and `entry/.cxx`; the recoverable old outputs are under `/private/tmp/remotedesk-generated-conflicts.ctIwI7` until normal temporary cleanup.

## Verification (2026-08-08)

- `git diff --check`: pass.
- Host native suite outside the sandbox for this checkpoint: `337 passed, 0 failed, 337 total`.
- `default@OhosTestCompileArkTS`: pass after `fec26e2` with the final shared-tree state present.
- `assembleHap`: `BUILD SUCCESSFUL in 13 s 515 ms`; `BuildNativeWithNinja`, PackageHap and SignHap passed. A preceding non-incremental run exercised the repaired Rust/Ninja path and succeeded in `1 min 16 s 607 ms`.
- IDE-like Ninja command inspection under `PATH=/usr/bin:/bin` shows absolute Cargo, rustc, clang/clang++, llvm-ar, sysroot and encoded rustflags.
- Signed HAP: `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `c0601bc1218624f86af292b5514a680e09fb00438e79038baf34b17e57ddb8d3`.
- Full Rust run outside the sandbox: `176 passed, 1 existing rendezvous public-address fixture failure`; all VP9, terminal, cursor and network groups affected by the current diff passed.
- `ohosTest@OhosTestCompileArkTS` remains unavailable because task registration fails with `00306054`.

## Review

- Independent review of the checkpoint found cursor Promise ownership, SFTP transport-loss classification, durable rename recovery, late cancel callback and VP9 pressure-policy issues in addition to the earlier IDE toolchain findings.
- The IDE/toolchain findings were addressed in `a9554a331`; the final SFTP/cursor/VP9 findings were addressed in `fec26e2`. A read-only follow-up review is running on exactly that increment. Do not mark the whole SSH plan merged or Level A complete until the remaining endpoint evidence is closed.

## Next

1. Record the final `fec26e2` reviewer result and commit the compact state/plan updates.
2. Continue second-host SSH switching plus physical/virtual-keyboard, IME and function-bar acceptance on xterm.js.
3. Implement and validate real local/remote/dynamic forwarding and ProxyJump host-key behavior against OpenSSH endpoints.
4. Add the version-locked FRP non-TCP transport, then run Visitor/STCP/SUDP/XTCP interoperability without fallback.

## Blockers / Evidence Gaps

- No real OpenSSH bastion, forwarding or FRP endpoint matrix is currently available.
- Background SFTP process-restart/authentication recovery and real endpoint interruption tests remain open despite durable code paths.
- Native Drawing remains disabled for visible SSH after API 23 `41207000` / BufferQueue `SIGABRT`; xterm.js is the acceptance renderer.
- External keyboard plus third-party IME coverage is incomplete.
- Light compliance is blocked by baseline SBOM package `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
