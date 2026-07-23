# Current Handoff

Updated: 2026-07-23 Asia/Shanghai

## Source

- Public source of truth: current synchronized `main`
- Mac hdc workflow fix: `dc715d230`, with PR #32 merged using a merge commit
- Windows source reviewed: sanitized commit `27e185f42` on
  `codex/windows-memory-sanitize`; its durable conclusions are integrated below
- Active task branch: none
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

## Windows handoff snapshot

The Windows-side sanitized audit reported the following machine-local tool
versions. They document the known Windows baseline and must not be turned into
Mac absolute paths:

- DevEco Studio `6.1.1.280`, bundled Node `18.20.1`, Hvigor `6.24.2` and ohpm
  `6.1.2.268`.
- CMake `3.29.2`, Ninja `1.12.0`, OHOS LLVM/Clang `15.0.4`.
- Rust/Cargo `1.96.0` with `aarch64-unknown-linux-ohos` and
  `x86_64-unknown-linux-ohos` installed.
- Windows PowerShell `5.1` was present but `pwsh` was absent in that snapshot;
  install PowerShell 7 before the mandated Windows sync, finish-check and push
  workflow.
- API 23 reference documentation was available locally on Windows. Its contents,
  paths and raw evidence remain local-only.

## Durable Windows development notes

- Treat API 23 as the compatibility ceiling. Check the local API 23 reference
  before importing HarmonyOS APIs; do not use API 26-only `@kit.uiMaterial`.
  Keep ArkTS strict types explicit and use bracket indexing for dynamic keys.
- Keep each OS's SDK, native SDK, LLVM/CMake/Ninja, Rust target, linker and
  sysroot machine-local. Build the matching `aarch64-unknown-linux-ohos` and
  `x86_64-unknown-linux-ohos` ABIs explicitly when the change affects native
  output.
- Use `default@OhosTestCompileArkTS` and `ohosTest@OhosTestCompileArkTS`; the
  legacy `default@OhosTestBuildArkTS` task is not the current API 23 acceptance
  gate. Separate build evidence from real-device evidence.
- OHOS native code may need Crypto or pthread/POSIX substitutes for Linux C++
  facilities. `Crypto_DataBlob.len` is bytes, random instances are per-use, and
  OHOS Crypto code links `libohcrypto.so`.
- RustDesk queue/enqueue success does not prove live-loop consumption. Preserve
  partial encrypted TCP/BytesCodec frames across timeout retries and prove
  consumption in the streaming loop before changing UI or renderer timing.
- `bindSheet` depends on a mounted host and ownership. PIP and renderer callbacks
  are transitional; wait for terminal states and make surface, decoder and
  renderer teardown explicit before reattachment.
- Keep the `.githooks` publication gate enabled, use one task branch at a time,
  and never share raw Codex memory, logs, screenshots, device data, secrets or
  machine-specific private paths.

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

1. Start Windows from synchronized `main` and run the shared-state, submodule and
   history gates.
2. Configure AGConnect locally only if cloud features are required, then complete
   the remaining real-device protocol and cloud-sync acceptance matrix.
