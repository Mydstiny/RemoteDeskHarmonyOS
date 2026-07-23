# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public branch: `main`
- Last migration merge commit: `dc715d230` (PR #32, merged with a merge commit)
- Active task: none; the completed Mac `hdc` toolchain fix is already merged.
- Shared state is synchronized with public `main`; the next device must sync before
  starting an independent task.

## Current phase

- The migration package restored the complete public source, Git history and
  recursive `freerdp` submodule on macOS; the bootstrap and final verification
  records are merged to public `main` through PRs #29 and #30.
- DevEco Studio 6.1.1 opens the repository root successfully. The project remains
  `runtimeOS: HarmonyOS` with `targetSdkVersion` and `compatibleSdkVersion`
  `6.1.0(23)`.
- Cross-device memory is the sanitized content under `docs/codex/`; no Windows or
  Mac Codex raw memory directory is copied or used as shared state.
- Both the full DevEco SDK and standalone API 23 SDK contain executable arm64
  `hdc` binaries. `scripts/macos_env.sh` now adds the full HarmonyOS SDK
  `toolchains` first and the standalone API 23 `toolchains` as a fallback.

## Completed verification

- `freerdp` is initialized at `dae8276ac7361b8d14f7b87d41163fe03dbb944e`.
- The local ignored `build-profile.json5` and `local.properties` are generated;
  `local.properties` intentionally separates the full DevEco SDK from the
  standalone API 23 native SDK.
- Mac SDKs detected:
  - Full HarmonyOS SDK for Hvigor:
    `/Applications/DevEco-Studio.app/Contents/sdk`
  - Standalone OpenHarmony API 23 native SDK:
    `/Users/mydestiny/Library/OpenHarmony/Sdk/23`
- `scripts/macos_env.sh` detects DevEco Node/Hvigor/ohpm, the bundled JBR/Java,
  OHOS LLVM/CMake/Ninja, Rust/Cargo, `hdc` and the local PowerShell fallback.
- API 23 Rust targets are installed:
  `aarch64-unknown-linux-ohos` and `x86_64-unknown-linux-ohos`.
- Opus and RustDesk FFI dependencies build successfully for both `arm64-v8a` and
  `x86_64`; the FFI symbol checks pass after fixing the `pipefail`/SIGPIPE false
  failure in the migration script.
- `default@OhosTestCompileArkTS` passes. The non-daemon `assembleHap` build passes
  through native Ninja, ArkTS, `PackageHap`, `PackingCheck`, `SignHap` and debug
  symbol collection with the Mac-local private signing profile.
- `hvigorw tasks`, `hvigorw init`, native CMake/Ninja and ArkTS compilation pass.
  The local build produces both unsigned and signed HAP artifacts; neither is
  tracked or uploaded.
- `core.hooksPath=.githooks`, the sync workflow, history guard, FreeRDP provenance
  checks and Light compliance checks were validated on the restored workspace.
- After `source scripts/macos_env.sh`, `hdc --version` resolves to DevEco hdc
  `3.2.0d`. `hdc start` succeeds; `hdc list targets` reports `[Empty]` because no
  HarmonyOS device or emulator is currently connected and authorized.

## Blockers

- No SDK or signing input remains required for the current local build: DevEco,
  API 23 native tooling, Rust targets and the private signing profile are present
  on this Mac. Signing files and passwords remain local-only.
- AGConnect is optional for import/build and is not currently configured; provide
  `entry/src/main/resources/rawfile/agconnect-services.json` through a secure
  channel only if cloud features or cloud-device validation are needed.
- Device validation remains pending until a HarmonyOS device or emulator is
  connected and authorized for `hdc`.
- The repository-local PowerShell 7 fallback (`7.7.0-preview.3`) passes the
  compliance gate; a stable system PowerShell 7 install is still recommended but
  is not blocking this workspace.

## Next

- On a clean Windows clone, run the shared-state, submodule and history gates.
- Configure AGConnect locally only if cloud features or cloud-device validation are
  needed; keep device data and raw evidence local-only.
- Complete real-device acceptance for RDP, RustDesk, SSH/SFTP, VNC, PIP/live-view
  and cloud-sync checkpoints.
