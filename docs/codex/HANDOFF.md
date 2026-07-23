# Current Handoff

Updated: 2026-07-23 Asia/Shanghai

## Source

- Migration baseline: `main` at `b71639512`, with PR #31 merged using a merge commit
- Active task branch: none; the completed Mac `hdc` PATH fix is ready for PR publication
- FreeRDP submodule: `dae8276ac7361b8d14f7b87d41163fe03dbb944e`

## Completed

- Complete public source and Git history were restored from the migration bundle;
  the recursive FreeRDP submodule is initialized, and the bootstrap plus final
  verification state are merged to public `main`.
- DevEco Studio 6.1.1 opens the repository root. API 23 remains the project
  baseline, with the full HarmonyOS SDK and standalone API 23 native SDK kept in
  separate local properties.
- Mac build helpers resolve the platform SDK layout, use the bundled DevEco JBR,
  configure OHOS clang/Cargo linkers and build both RustDesk FFI ABIs.
- The FFI migration script's `nm | grep -Eq` SIGPIPE false failure was fixed;
  both architecture symbol checks now pass.
- `assembleHap --no-daemon` passed through packaging, signing and debug symbol
  collection with the Mac-local private signing profile. Signing files remain
  local-only.
- `scripts/macos_env.sh` now exposes the DevEco/native SDK `hdc` toolchain. After
  sourcing it, `hdc --version` reports `3.2.0d`; `hdc start` succeeds and
  `hdc list targets` reports `[Empty]` only because no device is connected or
  authorized.
- `AGENTS.md` now directs both platforms to the sanitized `docs/codex/` state and
  explicitly forbids sharing raw Codex memory directories.

## Verification

- The post-merge `sync_workspace.sh sync`, task-start gate and final
  `sync_workspace.sh status`/`doctor` checks passed. The hdc PATH fix was
  verified on macOS.
- `hvigorw tasks` and `hvigorw init` passed.
- Opus and RustDesk FFI builds passed for `arm64-v8a` and `x86_64`.
- `default@OhosTestCompileArkTS` passed. `assembleHap --no-daemon` passed through
  ArkTS, CMake/Ninja, native strip, `PackageHap`, `PackingCheck`, `SignHap` and
  debug symbol collection using the Mac-local private signing profile.
- Shell syntax, workflow policy, pre-push history protection, FreeRDP provenance,
  and Light compliance checks pass on macOS, including the repository-local
  PowerShell wrapper when no shell setup is sourced first.

## Private input status

- Signed builds: the private profile is already configured locally and `SignHap`
  passed. The `.p12`, `.p7b`, `.cer`, alias and passwords remain outside Git and
  shared memory.
- Cloud features: `entry/src/main/resources/rawfile/agconnect-services.json` is
  not present on this Mac; provide it securely only when cloud features are needed.
- Real-device authorization, logs, screenshots and user data stay on the device or
  local machine and are not part of the migration handoff.

## Next owner action

1. After the hdc PR is merged, start Windows from synchronized `main` and run the
   shared-state, submodule and history gates.
2. Configure AGConnect locally only if cloud features are required, then complete
   the remaining real-device protocol and cloud-sync acceptance matrix.
