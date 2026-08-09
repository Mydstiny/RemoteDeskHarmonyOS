# Shared Current State

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoints: `6924a1124` (`feat: harden remote sessions and SSH workspace`), `a9554a331` (`fix: harden DevEco builds and session recovery`), `fec26e2` (`fix: close SFTP and pointer recovery races`), `0be27d7` (`feat(ssh): add forwarding workspace`) and `bc5132c` (`fix(ssh-ui): finalize forwarding workspace`).
- Phase: Level A and SFTP UI are accepted; Level B proxy/forwarding code, Pad UI and real Local-forward traffic are implemented. Remaining endpoint interoperability and independent review stay open; xterm.js remains the visible renderer.

## Current Outcome

- SSH sessions are keyed by session/channel/generation; tab detach, background/PiP ownership, reconnect, prompt brokerage and stale callback fencing no longer depend on one global active adapter.
- Password and keyboard-interactive authentication support multi-prompt/multi-round flows. Prompt responses remain one-shot and are cleared after handoff.
- SFTP uses durable endpoint-aware tasks. The Pad/PC workspace keeps the current SSH host on the left; the right side starts blank and changes only after `本机文件` or `选择 SSH 主机`. The nested host selector is an independent bindSheet. Phone keeps the 1.0.8 single-column bottom-sheet interaction.
- The wireless Pad interaction matrix was accepted on `192.168.3.236:40123`: root close/reopen, picker cancel/reopen, current/other host selection, SSH/local switching, repeated host replacement, list viewport and transfer-direction labels.
- SSH-to-SSH transfer is page-independent and binds both endpoint sessions explicitly. Native SFTP errors publish transport loss before their Promise resolves; the task engine consumes that signal before a reconnect can hide it. Atomic upload persists and flushes `commitState=renaming` before rename, recovers by checking the final target first, then persists `renamed`; late callbacks cannot overwrite pause/cancel.
- Direct/HTTP CONNECT/SOCKS5/one-to-three-hop ProxyJump/external FRP TCP endpoint profiles now have one unified editor and session handoff. External Visitor is represented only by the ordinary TCP endpoint exposed by an external frpc; the App contains no FRP control plane or secret.
- Local/remote/dynamic forwarding is wired through the existing Native listeners/channels with generation-owned controller/runtime cleanup. The terminal has a compact dark forwarding bindSheet, separate dark add/edit and confirmation sheets, public-listener confirmation, manual/automatic lifecycle, live runtime metrics and serialized close/reopen behavior. Runtime cards now read reactive snapshots directly instead of retaining their first Builder argument.
- Visitor/STCP/SUDP/XTCP protocol handling remains explicit fail-closed; it is not silently downgraded to Direct, proxy or `frp_tcp`.
- RustDesk/RDP/VNC work already present in the mixed tree was preserved. RustDesk VP9 software pressure and high-resolution FPS ceiling changes are included in the current checkpoint; RDP Gateway trust stages remain separate and fail closed for unsupported credential combinations.

## IDE Build Repair

- The DevEco failure was caused by GUI PATH isolation: CMake found an absolute Cargo binary, but Cargo tried to launch bare `rustc`; the next hidden dependency was bare target `clang++`/sysroot flags.
- CMake now resolves and validates absolute Cargo plus matching rustc, preferring Cargo's sibling compiler before PATH/rustup fallback. It injects absolute OHOS C/C++/AR/linker paths and an absolute sysroot.
- `CARGO_ENCODED_RUSTFLAGS` preserves a Windows DevEco sysroot containing spaces. The generated Ninja command no longer depends on shell PATH for cargo, rustc or clang++.
- Stale generated conflict files such as `string 2.json` and duplicated SVGs were isolated by rebuilding `entry/build` and `entry/.cxx`; the recoverable old outputs are under `/private/tmp/remotedesk-generated-conflicts.ctIwI7` until normal temporary cleanup.

## Verification (2026-08-09)

- `git diff --check`: pass.
- Host native suite outside the sandbox: `339 passed, 0 failed, 339 total`; the sandbox run reached 323/339 with only 16 existing VNC loopback fixture startup failures.
- `default@OhosTestCompileArkTS`: pass after `bc5132c`, including the forwarding snapshot statistics regression.
- `assembleHap`: `BUILD SUCCESSFUL in 32 s 998 ms`; `BuildNativeWithNinja`, PackageHap and SignHap passed.
- IDE-like Ninja command inspection under `PATH=/usr/bin:/bin` shows absolute Cargo, rustc, clang/clang++, llvm-ar, sysroot and encoded rustflags.
- Signed HAP: `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `f07a54cf5a5e57b16411faa95295dbd6214c77bb39b2ba20bc35a0835fa36946`.
- Wireless MLR-AL10 `192.168.3.236:40123`: direct SSH connected and Local `127.0.0.1:8022 -> 127.0.0.1:22` listened under the App UID. A temporary HDC `28022 -> 8022` mapping carried a real OpenSSH banner, client identification and server KEXINIT in both directions; the dark Pad sheet updated to `连接 1` / `流量 1.1 KB`. The temporary mapping was removed after acceptance.
- Full Rust run outside the sandbox: `176 passed, 1 existing rendezvous public-address fixture failure`; all VP9, terminal, cursor and network groups affected by the current diff passed.
- `ohosTest@OhosTestCompileArkTS` remains unavailable because task registration fails with `00306054`. Light could not start because `pwsh` is absent; the existing SBOM `NOASSERTION` blocker also remains.

## Review

- `0be27d7..bc5132c` received a direct changed-path review, `git diff --check`, both Hvigor gates and wireless Pad UI/data-flow acceptance. The user requested direct completion without subagent delegation, so this is not an independent reviewer pass.
- Keep `review=REVIEW_REQUIRED` until an independent reviewer checks the committed increment. Do not mark Level B endpoint interoperability complete without real traffic evidence.

## Next

1. Provision real HTTP CONNECT, SOCKS5, one-to-three-hop OpenSSH, external FRP TCP/Visitor plus Remote/Dynamic forwarding endpoints and run the remaining matrix.
2. Run an independent review through `bc5132c` and resolve findings without touching SFTP or other protocols.
3. Continue Phone/PC, physical keyboard, third-party IME, rotation, split-window, PiP, foreground/background and network-switch acceptance.

## Blockers / Evidence Gaps

- Local forwarding has real SSH banner/KEX traffic evidence; real OpenSSH bastion, HTTP/SOCKS proxy, Remote/Dynamic forwarding and external FRP endpoint matrices are still unavailable.
- Background SFTP process-restart/authentication recovery and real endpoint interruption tests remain open despite durable code paths.
- Native Drawing remains disabled for visible SSH after API 23 `41207000` / BufferQueue `SIGABRT`; xterm.js is the acceptance renderer.
- External keyboard plus third-party IME coverage is incomplete.
- Light compliance cannot run locally because `pwsh` is missing and is also blocked by baseline SBOM package `totp-reviewed-brand-assets` with `licenseDeclared=NOASSERTION`.
- Independent review of the forwarding workspace is pending by explicit direct-execution instruction.
