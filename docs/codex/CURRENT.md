# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public branch: `main`
- Public main commit restored from the migration bundle: `c502221e3` (`Merge PR #28: refresh shared handoff state`)
- Canonical development model: one local workspace, one active `codex/<task>` branch, protected PR merge.

## Current phase

- Cross-device collaboration bootstrap is merged and available on `main`; this Mac workspace restored the public source and Git history from the migration bundle, including freerdp at `dae8276ac`.
- The active migration task is `codex/mac-migration-bootstrap` at `aca6c1e`; it preserves executable mode bits and adapts the shared workflow/build helpers to macOS.
- The 1.0.8 runtime, cloud-sync protection, onboarding and PIP/RDP lifecycle changes are in public history; device acceptance remains a separate validation item.

## Completed verification recorded in public history

- Native and RustDesk FFI test suites passed for the published runtime checkpoints.
- `default@OhosTestCompileArkTS`, production HAP build, `git diff --check` and Light open-source compliance passed for the published runtime checkpoints.
- The restored workspace has `core.hooksPath=.githooks`; `sync_workspace.sh status` and `doctor` passed before the migration task branch was created.
- The freerdp submodule is initialized at `dae8276ac7361b8d14f7b87d41163fe03dbb944e`.
- Bash/zsh syntax checks, workflow policy tests, FreeRDP provenance, pre-push history protection and Light open-source compliance pass on macOS.
- `source scripts/macos_env.sh` exposes DevEco's Node/Hvigor/ohpm, OHOS LLVM/CMake/Ninja and rustup cargo/rustc; the local ignored PowerShell fallback reports `7.7.0-preview.3`.

## Next

- Publish and review the Mac migration workflow fix, then run the required open-source compliance check before merging.
- Install stable PowerShell 7 if a system `pwsh` is preferred, install the project's API 23 SDK, and add the OHOS Rust targets/native inputs required for builds.
- Verify the cross-device synchronization gate on a clean Windows clone and a clean macOS clone.
- On an unlocked HarmonyOS target, complete the remaining PIP, live-view, cloud-sync and first-install acceptance matrix.
- Keep all raw device evidence and private build inputs local-only.

## Migration blocker

- GitHub fetch/push and PR operations are not currently available from this environment because connections to `github.com` fail at DNS/SSL. The bundle refs are restored locally, but remote equality still needs a networked run.
- The installed DevEco SDK is API 24 (`6.1.1`), while the project baseline is API 23 (`6.1.0(23)`); API 23 remains a manual SDK Manager requirement.
- Stable system PowerShell installation remains manual because the Homebrew cask requires interactive sudo; the ignored user-level preview fallback is available after sourcing `scripts/macos_env.sh`.

## Local-only state

SDKs, signing profiles, AGConnect configuration, local properties, build caches, logs, screenshots, device databases and Codex's private machine memory are intentionally not represented here.
