# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public `main` after merge: `a60d0e743` (`Merge pull request #35 from Mydstiny/codex/windows-memory-sanitize`)
- Previous Windows audit base: `c502221e3`
- Active task: none; the Windows audit is merged into public `main`
- Audit commits: `27e185f42`, `a24568990`
- Audit PR: `#35` (`https://github.com/Mydstiny/RemoteDeskHarmonyOS/pull/35`)
- No runtime, ArkTS, C/C++, Rust, FreeRDP or dependency source was changed by this audit branch.
- User-owned test edits, logs, screenshots, XML and native build evidence remain local and are not part of this task.

## Current phase

- Windows Codex memory sanitization and cross-device development handoff audit.
- Public `main` includes the Mac migration/`hdc` workflow, the prior Windows handoff integration and this detailed structured audit record.
- The normal task start gate was intentionally not used because the workspace contained user-owned changes. The branch was created from synchronized public history without stashing, resetting or deleting those files.

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
| API 23 reference docs | Local copy is present | Windows verified; contents stay local |

The old baseline's Node 24 and approximate DevEco 26.0 entries are historical and are not current Windows facts. Mac versions and machine paths are not inferred from them.

## Cross-device state inherited from public main

- `scripts/macos_env.sh`, `scripts/resolve_ohos_sdk.sh` and `scripts/resolve_powershell.sh` are now present on public `main`; the initial Windows audit observed them before the concurrent main update.
- The Mac helper keeps the full DevEco/HarmonyOS SDK role separate from the standalone API 23 native SDK role, resolves bundled Node/Hvigor/ohpm/Java/LLVM/CMake/Rust tools, configures both OHOS Rust ABIs and exposes the SDK `hdc` toolchain.
- Public Mac handoff records report successful source/submodule restoration, both-ABI Opus/RustDesk FFI builds, `default@OhosTestCompileArkTS`, non-daemon `assembleHap`, hook checks and Light compliance. These are inherited public evidence, not new Windows device acceptance.
- Mac `hdc` availability was verified in public history; an empty target list means no authorized device is connected, not that the toolchain is missing.

## Audit result

- Shared docs that previously pointed at `c5347f141` are corrected to the current public history.
- The Windows memory conclusions about API 23, ArkTS strict mode, bindSheet mounting, OHOS C++/Crypto APIs, RustDesk stream framing/control consumption, PIP ownership and Git safety are distilled into `DECISIONS.md` and `HANDOFF.md`.
- Raw Codex memory, chat/session transcripts, device evidence and private inputs were not copied.

## Verification status

- Windows direct checks confirmed the tool versions and API 23 reference availability listed above.
- `git diff --check`, Light compliance, workflow policy tests, Opus artifact-location tests and the pre-push public-history guard passed before the merge.
- PR #35 was merged with a normal merge commit after its `open-source-compliance` check passed.
- Real-device, cloud-account and Mac clean-clone acceptance remain separate from this document audit.

## Next

- On the next device, read these four files, sync `main`, configure machine-local SDK/toolchains/private inputs and run the platform-specific workflow.
- Keep one task branch active at a time and do not start new work until the next task has been explicitly selected.
- Complete real-device acceptance for PIP/live-view, RDP/RustDesk background restore, cloud sync and first-install behavior.

## Local-only boundary

SDKs, signing profiles, AGConnect configuration, `local.properties`, real `build-profile.json5`, build caches, device data, raw logs, screenshots, private device addresses and Codex's original machine memory are intentionally not represented here.
