# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public branch: `main`
- Public main commit: `c502221e3` (`Merge PR #28: refresh shared handoff state`)
- Active task: `codex/mac-migration-bootstrap`; the migration adapter commit is
  `ffbd1f5`.
- Local `main` equals local `origin/main`; the task branch is based directly on that
  public commit.

## Current phase

- The migration package restored the complete public source, Git history and
  recursive `freerdp` submodule on macOS.
- DevEco Studio 6.1.1 opens the repository root successfully. The project remains
  `runtimeOS: HarmonyOS` with `targetSdkVersion` and `compatibleSdkVersion`
  `6.1.0(23)`.
- Cross-device memory is the sanitized content under `docs/codex/`; no Windows or
  Mac Codex raw memory directory is copied or used as shared state.

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
  OHOS LLVM/CMake/Ninja, Rust/Cargo and the local PowerShell fallback.
- API 23 Rust targets are installed:
  `aarch64-unknown-linux-ohos` and `x86_64-unknown-linux-ohos`.
- Opus and RustDesk FFI dependencies build successfully for both `arm64-v8a` and
  `x86_64`; the FFI symbol checks pass after fixing the `pipefail`/SIGPIPE false
  failure in the migration script.
- `hvigorw tasks`, `hvigorw init`, native CMake/Ninja and ArkTS compilation pass.
  `assembleHap` reaches `PackageHap` and `PackingCheck`, producing the local
  unsigned artifact at `entry/build/default/outputs/default/entry-default-unsigned.hap`.
- `core.hooksPath=.githooks`, the sync workflow, history guard, FreeRDP provenance
  checks and Light compliance checks were validated on the restored workspace.

## Blockers

- GitHub fetch/push/PR operations need a networked run; the current environment has
  intermittent DNS/SSL failures for `github.com`.
- A signed HAP requires private local signing material and matching values in the
  ignored `build-profile.json5`: `.p12`, `.p7b`, `.cer`, store/key passwords and
  alias. These must be transferred through a secure channel and never committed.
- AGConnect is optional for import/build but cloud features require the local
  ignored `entry/src/main/resources/rawfile/agconnect-services.json`; never place
  its secrets in shared docs or Git.
- The local PowerShell fallback works for repository checks, but a stable system
  PowerShell 7 install remains preferable. API 23 native SDK and Rust targets are
  already present on this Mac.

## Next

- Run the final post-commit checks and push `codex/mac-migration-bootstrap`.
- Create the PR, wait for `open-source-compliance`, merge with a merge commit, then
  fast-forward local `main` and delete the merged task branch.
- Configure private signing/AGConnect values locally if signed or cloud-enabled
  device validation is required; keep device data and raw evidence local-only.
