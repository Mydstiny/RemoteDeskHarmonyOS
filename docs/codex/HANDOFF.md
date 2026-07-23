# Current Handoff

Updated: 2026-07-23 Asia/Shanghai

## Source

- Base: `main` at `c502221e3`, restored from the migration package
- Active task branch: `codex/mac-migration-bootstrap`
- Migration adapter commit: `ffbd1f5`
- FreeRDP submodule: `dae8276ac7361b8d14f7b87d41163fe03dbb944e`

## Completed

- Complete public source and Git history were restored from the migration bundle;
  the recursive FreeRDP submodule is initialized.
- DevEco Studio 6.1.1 opens the repository root. API 23 remains the project
  baseline, with the full HarmonyOS SDK and standalone API 23 native SDK kept in
  separate local properties.
- Mac build helpers resolve the platform SDK layout, use the bundled DevEco JBR,
  configure OHOS clang/Cargo linkers and build both RustDesk FFI ABIs.
- The FFI migration script's `nm | grep -Eq` SIGPIPE false failure was fixed;
  both architecture symbol checks now pass.
- `assembleHap` reaches packaging and creates an unsigned HAP. Signing is the only
  remaining build-stage requirement and is intentionally local-only.
- `AGENTS.md` now directs both platforms to the sanitized `docs/codex/` state and
  explicitly forbids sharing raw Codex memory directories.

## Verification

- `sync_workspace.sh status` and `doctor` passed on the restored clean `main`
  checkout before the task branch was created.
- `hvigorw tasks` and `hvigorw init` passed.
- Opus and RustDesk FFI builds passed for `arm64-v8a` and `x86_64`.
- `assembleHap --no-daemon` passed through ArkTS, CMake/Ninja, native strip,
  `PackageHap` and `PackingCheck`; `SignHap` stops on the placeholder certificate
  path in the ignored local profile.
- Shell syntax, workflow policy, pre-push history protection, FreeRDP provenance,
  and Light compliance checks pass on macOS, including the repository-local
  PowerShell wrapper when no shell setup is sourced first.

## Private inputs still local

- Signed builds: `.p12`, `.p7b`, `.cer`, certificate alias and passwords, configured
  only in the ignored `build-profile.json5`.
- Cloud features: local
  `entry/src/main/resources/rawfile/agconnect-services.json` with its secret fields.
- Real-device authorization, logs, screenshots and user data stay on the device or
  local machine and are not part of the migration handoff.

## Next owner action

1. Run the final post-commit checks and inspect the clean working tree.
2. Push only `codex/mac-migration-bootstrap` and create a PR.
3. Wait for `open-source-compliance`, merge without squash, then run `main` sync and
   delete the merged branch.
4. Report the final Mac commit/branch, `main` equality, submodule, hook, PowerShell,
   sync-script, clean-worktree and private-input status.
