# Shared Current State

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- Code checkpoints: `6924a1124` (`feat: harden remote sessions and SSH workspace`), `a9554a331` (`fix: harden DevEco builds and session recovery`), `fec26e2` (`fix: close SFTP and pointer recovery races`), `0be27d7` (`feat(ssh): add forwarding workspace`), `bc5132c` (`fix(ssh-ui): finalize forwarding workspace`), `41944ff` (`feat(settings): finalize 1.1.0 personalization defaults`), `29073afaf` (`fix: prioritize TOTP issuer logos`), `b1635d30a` (`fix(ui): dock Pad touchpad controls on right`), `6b17444a9` (`fix(rustdesk): repair mobile relay spacing`), `01d191b` (`feat(onboarding): refresh 1.1.0 guide pages`), `98a18c40f` (`fix(ssh-ui): remove keyboard mode bottom gap`), `a5ba18c87` (`fix(rustdesk): repair PC hardware presentation`), `6f8f387` (`feat(settings): expose onboarding review guides`), `d1e4acfba` (`chore(repo): ignore generated Python bytecode`), `dec23b430` (`fix(compliance): require licensed TOTP brand assets`) and `f61bafa` (`test(ssh): avoid secret scanner false positive`).
- Phase: implementation and independent review are complete; push, PR, required `open-source-compliance` and merge are pending. Remaining device acceptance and endpoint interoperability stay open; xterm.js remains the visible renderer.

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
- 1.1.0 captures a clean-install profile before LoginPage writes its launch marker. Saved update-user preferences remain authoritative; new Phone/Pad installs default remote controls to touchpad and SSH to the software keyboard, while new PC installs default all four protocols to physical keyboard/mouse. Canvas pinch zoom and RustDesk presence/grouping default off, official remote cursor/background display/real 2FA logos default on, SSH uses the system terminal-style symbol, and VNC option rows now use semantic symbols.
- Phone RustDesk relay lists now own a 200 vp scroll-tail clearance, keeping the final card above the parent FAB even with many relays. The classic relay add sheet fits its collapsed content and switches to the large resize-only layout only after advanced configuration is expanded; the VNC gateway editor remains large.
- The 1.1.0 update Swiper is rewritten as 12 focused pages led by VNC, followed by RustDesk, host organization/monitoring, SSH/SFTP/forwarding, RDP certificate validation, authenticator logos and input fixes. First-install and Settings usage guides now share nine instructional pages plus their own final page; long release notes use a compact numeric pager.
- Settings → Tutorial keeps three non-duplicated entries: `本版本更新日志`, `简单使用教程` and the prerequisite guide. The first-install guide remains part of onboarding but is no longer repeated in Settings; opening the release notes never changes the startup release-read marker.
- The collapsed RustDesk relay add/edit sheet now uses 68–72% of the available window height, bounded to 480–620 vp when space permits; advanced configuration still expands to the large resize-only layout.
- The 1.1.0 update Swiper passed direct device review. Its explicit `FORCE_RELEASE_NOTES_REVIEW` acceptance switch is disabled again, restoring the normal once-per-version startup policy.

## IDE Build Repair

- The DevEco failure was caused by GUI PATH isolation: CMake found an absolute Cargo binary, but Cargo tried to launch bare `rustc`; the next hidden dependency was bare target `clang++`/sysroot flags.
- CMake now resolves and validates absolute Cargo plus matching rustc, preferring Cargo's sibling compiler before PATH/rustup fallback. It injects absolute OHOS C/C++/AR/linker paths and an absolute sysroot.
- `CARGO_ENCODED_RUSTFLAGS` preserves a Windows DevEco sysroot containing spaces. The generated Ninja command no longer depends on shell PATH for cargo, rustc or clang++.
- Stale generated conflict files such as `string 2.json` and duplicated SVGs were isolated by rebuilding `entry/build` and `entry/.cxx`; the recoverable old outputs are under `/private/tmp/remotedesk-generated-conflicts.ctIwI7` until normal temporary cleanup.

## Verification (2026-08-09)

- `git diff --check`: pass.
- Host native suite outside the sandbox: `339 passed, 0 failed, 339 total`; the sandbox run reached 323/339 with only 16 existing VNC loopback fixture startup failures.
- `default@OhosTestCompileArkTS`: final code candidate `f61bafa` passed with `BUILD SUCCESSFUL in 8 s 411 ms`.
- `assembleHap`: final code candidate `f61bafa` passed with `BUILD SUCCESSFUL in 15 s 27 ms`, including BuildNativeWithNinja, PackageHap and SignHap.
- IDE-like Ninja command inspection under `PATH=/usr/bin:/bin` shows absolute Cargo, rustc, clang/clang++, llvm-ar, sysroot and encoded rustflags.
- Signed HAP: `entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `61c9604123eaa9cbf89c7613a67f7522459a0ea7ccfa87f579d807ca383ec8d6`.
- Wireless MLR-AL10 `192.168.3.236:40123`: direct SSH connected and Local `127.0.0.1:8022 -> 127.0.0.1:22` listened under the App UID. A temporary HDC `28022 -> 8022` mapping carried a real OpenSSH banner, client identification and server KEXINIT in both directions; the dark Pad sheet updated to `连接 1` / `流量 1.1 KB`. The temporary mapping was removed after acceptance.
- Full Rust run outside the sandbox: `176 passed, 1 existing rendezvous public-address fixture failure`; all VP9, terminal, cursor and network groups affected by the current diff passed.
- TOTP generator check is synchronized; validator reports 280 assets, zero errors and synchronized compliance records. The reviewed package now declares `AGPL-3.0-or-later AND CC0-1.0 AND MIT`; no package has `licenseDeclared=NOASSERTION`.
- Local open-source compliance `Light`: pass using the ignored repository-local PowerShell runtime. The same required check must still pass on GitHub before merge.
- `ohosTest@OhosTestCompileArkTS` remains unavailable because task registration fails with `00306054`.

## Review

- `0be27d7..bc5132c` received a direct changed-path review, `git diff --check`, both Hvigor gates and wireless Pad UI/data-flow acceptance. The user requested direct completion without subagent delegation, so this is not an independent reviewer pass.
- `41944ff` received a direct changed-path/default-inheritance audit, `git diff --check` and both Hvigor gates. Clean-install/update and Phone/Pad/PC visual acceptance remain separate from this build evidence.
- `29073afaf..6b17444a9` received a direct changed-path audit, layout policy coverage, `git diff --check` and both Hvigor gates. TOTP logo preference, Pad control docking and the RustDesk relay Phone layout still need device acceptance.
- `01d191b` received a direct content/path audit, registry regression coverage, `git diff --check` and both Hvigor gates. Phone/Pad Swiper pagination, text fit and Settings-sheet visual acceptance remain open.
- `6f8f387` received a direct changed-path audit, `git diff --check` and both Hvigor gates. Its two Settings review entries still need device visual acceptance.
- Independent reviewer `019fe594-c49a-77f2-ad7f-1c76c1fc6ef4` (`gpt-5.6-sol`, low) reviewed `origin/main@34946adbc..f61bafa` read-only and returned `PASS`: no blocking or actionable correctness, race, regression, sensitive-file or machine-local-file findings. It explicitly confirmed that the post-hook fixture split preserves runtime semantics and does not expand the secret-scanner allowlist. Documentation-only receipt updates after `f61bafa` do not invalidate this code review.
- Do not mark Level B endpoint interoperability complete without real traffic evidence.

## Next

1. Push `codex/ssh-terminal-complete-upgrade`, open a ready PR, wait for required `open-source-compliance`, then merge and synchronize local `main` without including the rolled-back independent-window stash.
2. Review both explicit Settings tutorial Swipers, then validate clean-install versus update inheritance plus Phone/Pad/PC defaults, the SSH/VNC symbols, TOTP logo matching, Pad control docking and the RustDesk relay Phone layout on devices.
3. Provision real HTTP CONNECT, SOCKS5, one-to-three-hop OpenSSH, external FRP TCP/Visitor plus Remote/Dynamic forwarding endpoints and run the remaining matrix.

## Blockers / Evidence Gaps

- Local forwarding has real SSH banner/KEX traffic evidence; real OpenSSH bastion, HTTP/SOCKS proxy, Remote/Dynamic forwarding and external FRP endpoint matrices are still unavailable.
- Background SFTP process-restart/authentication recovery and real endpoint interruption tests remain open despite durable code paths.
- Native Drawing remains disabled for visible SSH after API 23 `41207000` / BufferQueue `SIGABRT`; xterm.js is the acceptance renderer.
- External keyboard plus third-party IME coverage is incomplete.
- 1.1.0 clean-install/update classification and the Phone/Pad/PC default matrix are code/test-compile/build verified but not yet device accepted.
- RustDesk relay Phone FAB clearance and collapsed/advanced add-sheet sizing are policy-test-compile/build verified but not yet device accepted.
- The 12-page release Swiper passed direct device review; the 10-page first-install/Settings tutorials remain registry-test-compile/build verified but not yet visually accepted on Phone/Pad.
- The simplified three-entry Settings tutorial section and adaptive RustDesk relay editor height are not yet visually accepted on a device.
