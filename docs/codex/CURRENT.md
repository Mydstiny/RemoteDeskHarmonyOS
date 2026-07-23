# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public branch: `main`
- Public main commit at audit start: `c502221e3` (`Merge PR #28: refresh shared handoff state`)
- Audit branch: `codex/windows-memory-sanitize`, based on synchronized `main`
- No unfinished local `codex/...` branch existed before this audit.
- The workspace contains user-owned test edits, logs, screenshots, XML and native build evidence. They remain local and are not part of this task.

## Current phase

- Windows Codex memory sanitization and cross-device development handoff audit.
- No runtime, ArkTS, C/C++, Rust, FreeRDP, dependency or signing configuration was changed.
- The normal `start` command could not be used because the working tree is intentionally dirty with user evidence. The branch was created directly from synchronized `main`; only the four `docs/codex` files are in scope.

## Windows evidence collected in this audit

| Item | Result | Scope |
| --- | --- | --- |
| DevEco Studio | `6.1.1.280` installation metadata | Windows verified |
| HarmonyOS target | API 23, `targetSdkVersion`/`compatibleSdkVersion` `6.1.0(23)` | Repository configuration verified |
| Runtime and module | `runtimeOS: HarmonyOS`, product `default`, module `entry` | Repository configuration verified |
| DevEco bundled Node | `18.20.1` | Windows verified |
| Hvigor CLI | `6.24.2` | Windows verified |
| ohpm | `6.1.2.268` | Windows verified |
| CMake / Ninja | `3.29.2` / `1.12.0` | Windows verified |
| OHOS LLVM/Clang | `15.0.4` | Windows verified |
| Rust / Cargo | `1.96.0` / `1.96.0` | Windows verified |
| Rust OHOS targets | `aarch64-unknown-linux-ohos`, `x86_64-unknown-linux-ohos` | Windows verified |
| Windows PowerShell | `5.1.26100.8875`; `pwsh` is not installed | Windows verified |
| API 23 reference docs | Local copy is present | Windows verified; content stays local |

The old baseline's Node 24 and approximate DevEco 26.0 entries are historical and are not current Windows facts. Mac tool versions and SDK installation remain unverified.

## Audit result

- Shared docs previously pointed at `c5347f141`; the actual synchronized `main` and `origin/main` are `c502221e3`.
- `scripts/macos_env.sh`, `scripts/resolve_ohos_sdk.sh` and `scripts/resolve_powershell.sh` are not present. They are migration documentation gaps, not permission to invent or add runtime scripts in this task.
- The repository already contains the cross-device workflow, migration bundle generator, public Git history, submodule pointer and sanitized state files.
- Windows Codex memory contains useful technical conclusions about API 23, ArkTS strict mode, bindSheet mounting, OHOS C++/Crypto APIs, RustDesk stream framing/control consumption and Git safety. These conclusions are summarized in `DECISIONS.md` and `HANDOFF.md`; raw memory is not copied.

## Verification status

- `git status --short --branch`: confirmed `main` was synchronized before branch creation and showed only user-owned local material outside this task.
- `git log`: confirmed `c502221e3` is the current public merge tip.
- Direct tool checks confirmed the Windows versions listed above.
- The recorded public runtime checkpoints include native/RustDesk tests, `default@OhosTestCompileArkTS`, production `assembleHap`, `git diff --check` and Light compliance. Those records are not a substitute for new Mac or real-device verification.
- This audit branch still requires the final document diff check, Light gate, DCO commit, push, PR check and merge workflow.

## Next

- Finish and publish the four sanitized handoff documents from `codex/windows-memory-sanitize`.
- After PR merge, have macOS sync the merged `main`, configure machine-local SDK/toolchains/private files, and run the clean-clone workflow.
- Complete real-device acceptance for PIP/live-view, RDP/RustDesk background restore, cloud sync and first-install behavior.

## Local-only boundary

SDKs, signing profiles, AGConnect configuration, `local.properties`, real `build-profile.json5`, build caches, device data, raw logs, screenshots, private device addresses and Codex's original machine memory are intentionally not represented here.
