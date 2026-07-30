# Current Handoff

Updated: 2026-07-30 Asia/Shanghai

## Active VNC V2 handoff

- Branch: `codex/vnc-product-parity-sheet-remediation-v2`; base local
  `main@66fba4141`; implementation checkpoint `d17976c10`.
- Plan:
  `docs/superpowers/plans/2026-07-29-vnc-complete-product-parity-and-sheet-layout-remediation-plan-v2.md`.
- Commits: `e3c3fd7b7` plan, `6fd0e4539` Sheet/flow/settings,
  `6e47c052c` visible controls/diagnostics/panel placement, `b742f7b12`
  Cursor, `90f51eed9` bounded ZRLE and zlib compliance, `e1e23ebd6`
  implementation/release-gate documentation, `d17976c10` D-020 remediation.
- Latest evidence: native `171 passed, 0 failed`;
  `default@OhosTestCompileArkTS` passed; signed `assembleHap` passed; Light and
  `git diff --check` passed.
- The first independent D-020 audit found four gaps: text input used
  ClientCutText, synchronous connect failure retained a strong video callback,
  desktop classic FAB skipped VNC defaults, and the extreme-height layout
  policy was not wired to the production Sheet. `d17976c10` fixes all four.
- The same reviewer completed remediation, RAW_BGRA lifecycle, non-VNC
  isolation and system-zlib ABI checks with an explicit D-020 PASS and no
  P0/P1/P2. The local merge gate is satisfied.
- After review approval, fast-forward local `main`, delete only the merged VNC
  branch and preserve all unrelated dirty plan files. Do not push, create a PR
  or merge remote main.
- External release blockers: `ohosTest` task registration `00306054`, API 23
  Sheet/input/layout validation, real Mac continuous-frame/Cursor/Retina ZRLE,
  TigerVNC and UltraVNC/LibVNCServer interoperability, other-protocol smoke and
  one-/two-device/account-switch cloud matrices.
- The VNC task must close before sending the prepared RustDesk login/control
  plane implementation prompt to its existing Codex task.

## Completed cloud-data lifecycle handoff

- Branch: `codex/cloud-data-lifecycle-root-fix`; base:
  `main@23940521a`; final reviewed checkpoint: `c88fc2968`.
- Plan:
  `docs/superpowers/plans/2026-07-28-cloud-data-lifecycle-upgrade-roadmap.md`.
- Core local implementation is complete for account transitions, per-account
  physical stores, fail-closed cloud binding, durable coordinator/watchdogs,
  sensitive transfer validation, portable backup v3 and legacy partial
  restore, exclusive crypto lifecycle, Asset Store credential storage,
  device-local trust and legacy shared-store/relay/VNC migration quarantine.
- D-020 remediation through `0c0b3d4` requires a fresh OS distributed-account API
  result in addition to Account Kit, waits for cloud-first before publishing
  account ready, preserves pre-bootstrap record journal intent, persists a
  bounded cross-table download rollback transaction, blocks ordinary/VNC
  native-first during selection re-enable, accepts only proven authoritative
  empty snapshots and revokes RustDesk Pro Asset Store aliases on scope exit.
- The second review's final three P1 findings are remediated locally:
  `restored_not_uploaded` now returns `restore_pending` without publishing
  ready; VNC newly enabled scopes await cloud-first, record promotion and
  barrier release with exact rollback; RustDesk Pro scope revocation preserves
  non-secret account/server/device metadata as `requires_login` while the token
  remains deleted.
- The third review's final VNC P1 is remediated in `382fdaaa8`. Newly enabled
  scopes establish an owner/store/generation-bound checkpoint and pending
  barrier before settings or selection change. After cloud-first, the
  checkpoint is rebased to the authoritative VNC mirror plus the exact local
  settings/journal/retry/selection before-image. Promotion, both durable phase
  writes, barrier release and checkpoint deletion share one RDB transaction;
  automatic upload begins only after commit. The code-level recovery path
  restores under the barrier, never physically deletes a deterministic
  settings ID by assumption and retains checkpoint plus `recovery_required`
  if complete restoration cannot be proven; real process-interruption evidence
  is not claimed.
- The final point review's P0 and two P1 findings are remediated in
  `df2a6b4` and `88a6128`. VNC checkpoint creation, settings mutation,
  cloud-first/finalization and full-store rollback now occupy one exclusive
  coordinator queue item under the same account/store/generation lease, so the
  next normal/event/retry request waits until recovery finishes. Cloud-first
  completion atomically rebases the authoritative VNC checkpoint before
  journal replay and ordinary checkpoint deletion. Security metadata reads use
  strict present/absent/error results with read-back proof; `querySync` errors
  block native-first, promotion, retry, bootstrap publication and post-commit
  upload success instead of impersonating an absent row.
- Policy fault injection covers rebase-write failure, commit kill-points,
  post-commit authoritative recovery state and metadata-query exceptions. This
  is code-level evidence only; real process kill, reboot and low-storage
  recovery are still NO-GO acceptance items.
- The final source review confirmed the production invariants and left one P1
  test-wiring gap. `501565e` adds implementation-level coverage through actual
  `CloudSyncCoordinator` instances and production `CloudStore` completion,
  finalization and metadata methods. A controlled retry clock and narrow
  transaction/query ports prove queue and lease ordering, one transaction for
  authoritative rebase/journal/delete, rollback and post-commit recovery, and
  fail-closed metadata-error propagation. These tests compile in the default
  ArkTS test target; no device/runtime test execution is claimed.
- The continuation review found two P1s in that test seam. `0ffaa1c` restores
  both RDB-changing CloudStore completion/finalization entries to private,
  moves their testable orchestration into a stateless module with no
  singleton/RDB handle, and makes completion, finalization and startup recovery
  share the same signed-checkpoint and barrier metadata readers. Tests now
  inject real `readLocalMetadataState` query errors before barrier release and
  after commit, and simulate a restart that routes the committed authoritative
  checkpoint into pending recovery.
- The terminal continuation review's remaining P1/P2 are remediated in
  `0d6216e`. Barrier parsing now distinguishes a missing `vncrecord` key from a
  present invalid phase and rejects every non-object JSON top level. The same
  production rollback adapter is used by the private startup and in-process
  recovery paths; it owns checkpoint deletion/read-back and fail-closed
  recovery marking. Tests cover malformed barrier JSON before and after
  commit, successful restart deletion, and checkpoint retention on
  restore/delete/commit failures.
- The final remaining P2 test-wiring gap is remediated in `0c0b3d4`. A safe
  detached verification store traverses the real `CloudStore.init` and
  `openScopeStore` startup call point, which constructs the same private
  production adapter and `CloudStoreStartupRecoveryRunner`. The fake supplies
  only bottom-level I/O, so startup-call removal and restore/checkpoint-delete
  misrouting break success/readiness or checkpoint-retention assertions.
  Restore/delete/commit failures keep the checkpoint, publish no snapshot,
  mark recovery required and leave initialization not ready. The final
  independent D-020 incremental review passed at `c88fc2968` with no
  P0/P1/P2. No ArkTS runtime execution is claimed.
- API 23 has no signed Account Kit/distributed-account link object. The
  implementation accepts only exact current ID equality and otherwise blocks
  distributed-table registration and transfer. This is deliberately
  fail-closed and still requires real-device proof before release.
- Latest current-session validation: `default@OhosTestCompileArkTS` passed;
  `assembleHap` passed and signed; `git diff --check` passed; Light compliance
  passed. `ohosTest@OhosTestCompileArkTS` is absent from the task graph
  (`00306054`) and is not claimed as passed.
- The signed upgrade-test candidate is `1.0.9 / 1000009`. A connected device
  was inspected read-only and still has `1.0.8 / 1000008`; no install, launch,
  login or device-data mutation was performed. Require explicit user approval
  and a recovery plan before an in-place upgrade test.
- Release is NO-GO pending API 23 identity-correspondence proof, real Huawei
  Cloud schema/permissions and authoritative empty-set behavior, two API 23
  devices, A/B accounts, old released APK/RDB/backup fixtures, process-kill and
  low-storage fault injection, real Documents Providers and actual Asset Store
  alias deletion. System BackupExtension, remote destructive crypto and legacy
  REST sync remain disabled.
- No sub-agent was created for this remediation. The requested targeted review
  of the new implementation-level test coverage by the main agent remains a
  merge blocker.
- Preserve the unrelated user-owned SSH, Moonlight, RustDesk, VNC and RDP plan
  edits; do not stage, reset, stash or overwrite them.

## Archived 2026-07-23 handoff

## Source and scope

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public `main` after PR merge: `a60d0e743`
- Previous Windows audit base: `c502221e3`
- Audit branch: `codex/windows-memory-sanitize`
- Audit commits: `27e185f42` and `a24568990`
- Pull request: `https://github.com/Mydstiny/RemoteDeskHarmonyOS/pull/35`
- Merge result: PR #35 merged with a merge commit after `open-source-compliance` passed (run `30023107202`).
- Scope: sanitize Windows Codex development knowledge into public, platform-neutral documentation and merge it with the latest Mac handoff state.
- Runtime source, tests, dependencies, signing data and user evidence were not changed by this audit branch.

## What was read

- `AGENTS.md`, `README.md`, `docs/CROSS_DEVICE_GITHUB_WORKFLOW.md`, `docs/BUILD_BASELINE.md`.
- The four shared `docs/codex` state files and the workflow, build, dependency, compliance and hook scripts.
- Build/test, FreeRDP provenance, RustDesk FFI reproducible-build, Opus, signing and IDE-related project documents.
- Selected Windows Codex memory covering API 23, ArkTS strict mode, bindSheet mounting, OHOS Crypto/C++ limitations, RustDesk frame boundaries/control consumption, PIP lifecycle and public Git workflow.
- The public Mac helper scripts added to `main`: `macos_env.sh`, `resolve_ohos_sdk.sh` and `resolve_powershell.sh`.

Raw memory directories, chat/session transcripts, device logs, screenshots, crash reports and private paths were not copied or committed.

## Windows environment audit

| Component | Windows result | Mac status |
| --- | --- | --- |
| DevEco Studio | `6.1.1.280` installation metadata | Public handoff records `6.1.1`; verify locally |
| HarmonyOS/API | Repository targets `6.1.0(23)` / API 23; SDK and native SDK layout present | Full DevEco SDK and standalone API 23 native SDK have separate roles |
| Runtime/project | `runtimeOS: HarmonyOS`, product `default`, module `entry` | Same project settings expected |
| Bundled Node | `18.20.1` | Public Mac helper resolves bundled Node; verify locally |
| Hvigor | CLI `6.24.2` | Public Mac handoff build passed; verify locally |
| ohpm | `6.1.2.268` | Public Mac helper resolves it; verify locally |
| CMake / Ninja | `3.29.2` / `1.12.0` | Public Mac native build passed; verify locally |
| LLVM/Clang | `15.0.4` | Public Mac helper configures native LLVM; verify locally |
| Rust / Cargo | `1.96.0` / `1.96.0` | Public Mac handoff built both ABIs; verify locally |
| Rust targets | `aarch64-unknown-linux-ohos`, `x86_64-unknown-linux-ohos` installed | Both targets required |
| PowerShell | Windows PowerShell `5.1.26100.8875`; `pwsh` absent | `resolve_powershell.sh` supports system or repository-local fallback; stable PowerShell 7 recommended |
| FreeRDP | Public gitlink; baseline `3.26.1-dev0`; default `USE_REAL_FREERDP=OFF` | Initialize recursively |
| Opus | Build script pins `1.5.2` | Build locally when RustDesk input changes |
| OpenSSL/libssh2 | Historical project baseline only; not revalidated in this audit | Configure local artifacts |

The safe product example is the source for `entry`, `default`, API 23 and `runtimeOS`. Real signing fields, AGConnect values and local properties were intentionally not read.

## IDE continuation procedure

1. Open the repository root in DevEco Studio, not only the `entry` directory.
2. Let the IDE index the project and import the `entry` module and `default` target. Confirm product `default`, `runtimeOS: HarmonyOS`, device types and API 23 SDK selection.
3. Configure each machine's full DevEco SDK, standalone native SDK, Node, Hvigor, ohpm, Rust targets, linker and sysroot. Do not copy build caches or signing material from Windows to Mac.
4. On macOS, source `scripts/macos_env.sh` before CLI work. It resolves the two SDK roles, bundled tools, both Rust linkers/sysroots, `hdc` and the PowerShell resolver without requiring a machine-specific repository path.
5. Use the IDE task search or Hvigor wrapper for `default@OhosTestCompileArkTS`; use `ohosTest@OhosTestCompileArkTS` for the test module. Do not use the obsolete `default@OhosTestBuildArkTS` gate.
6. Build `assembleHap` for product `default`. Expected stages include ArkTS, native compilation/link, package/packing checks and signing when the local profile is configured. A signed HAP is local output, not migration content.
7. Attach a permitted HarmonyOS device through the local `hdc` configuration and inspect build/deploy logs in DevEco. Device addresses, identifiers and logs remain local.

## Standard commands

Commands below use repository-relative paths and placeholders so they can be run on either machine after local toolchain setup.

### Synchronization and task branch

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 sync
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 start -Task <lowercase-kebab-task>
```

macOS/Linux:

```sh
./scripts/sync_workspace.sh sync
./scripts/sync_workspace.sh start <lowercase-kebab-task>
source scripts/macos_env.sh
hdc --version
hdc start
hdc list targets
```

Expected result: clean `main`, `origin/main` fast-forward synchronized, recursive submodule update, no other unfinished task branch, then one new `codex/<task>` branch. A dirty tree must stop the workflow and preserve the local files. `hdc list targets` may be empty when no device is authorized.

### ArkTS, native, Rust and HAP validation

```text
default@OhosTestCompileArkTS
ohosTest@OhosTestCompileArkTS
cargo fmt --check
cargo test --lib --no-default-features
bash scripts/build_opus_ohos.sh all
bash scripts/build_rustdesk_ffi_ohos.sh all
bash scripts/build_freerdp_ohos.sh all       # only when real FreeRDP is enabled/needed
assembleHap --mode module --module entry --product default
```

The RustDesk build script maps `arm64-v8a` to `aarch64-unknown-linux-ohos` and `x86_64` to `x86_64-unknown-linux-ohos`, sets the matching Clang/sysroot variables, builds Opus first and checks exported FFI symbols.

Native tests are generated as `rdp_native_tests` by the project CMake configuration. Run the selected test binary or its DevEco/CTest target on the matching ABI. The public 2026-07-23 checkpoint recorded `129 passed, 0 failed`; real device behavior remains separate.

### Compliance and publication

```powershell
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify_open_source_release.ps1 -Mode Light
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/tests/test_workflow_scripts.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/tests/test_pre_push_history_guard.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/tests/test_opus_artifact_location.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 finish-check
```

On macOS, `scripts/sync_workspace.sh` sources `resolve_powershell.sh` for `finish-check`; it accepts a system `pwsh`, `powershell.exe` where available, or the repository-local ignored fallback. `finish-check` still requires a clean feature branch, an upstream branch and `main` as an ancestor. The pre-push hook verifies the pushed commit in a temporary detached worktree, refuses archive/private history and runs Light for ordinary branches.

## Sanitized pitfalls

### P-001

- ID: `P-001`
- 平台: Both
- 现象: API imports compile or run on a newer SDK but fail on the target device.
- 根因: Full HarmonyOS SDK/API 23 native SDK assumptions were mixed; `uiMaterial` is API 26-only.
- 正确修复: Select API 23, read the local API 23 reference first, and use API 23-compatible UIDesignKit/HDS/native APIs.
- 错误做法: Copy an API 26 sample or import `@kit.uiMaterial` into this API 23 product.
- 验证命令: `default@OhosTestCompileArkTS`; API 23 device smoke test.
- 当前状态: 已修复/已知限制; the repository configuration is API 23, but every new API still needs review.
- 是否适合写入长期规则: 是

### P-002

- ID: `P-002`
- 平台: Both
- 现象: Cargo build cannot link, links the wrong architecture or fails while compiling a native dependency.
- 根因: Cargo target, OHOS Clang target, sysroot or linker was inferred from the host instead of selected explicitly.
- 正确修复: Configure the matching OHOS Rust target, Clang/C++/AR variables and native sysroot for each ABI; build both ABIs when the release contract requires it.
- 错误做法: Reuse a Linux/macOS linker or copy a Windows absolute SDK path to Mac.
- 验证命令: `rustup target list --installed`; `bash scripts/build_rustdesk_ffi_ohos.sh all`; `assembleHap`.
- 当前状态: 已修复/待 Mac 验证; public Mac records pass, but each new machine must be checked.
- 是否适合写入长期规则: 是

### P-003

- ID: `P-003`
- 平台: Both
- 现象: Bash dependency scripts cannot find the SDK after variables were set in PowerShell, or PowerShell commands fail on Mac.
- 根因: Environment assignment syntax and path separators differ between shells; Windows backslashes can also reach Bash unchanged.
- 正确修复: Set `DEVECO_SDK_HOME`/`OHOS_SDK_HOME` in the shell that invokes the script, source `scripts/macos_env.sh` on Mac, normalize paths in Bash and use the platform-specific PowerShell command.
- 错误做法: Paste `$env:NAME=...` into Bash or `export NAME=...` into PowerShell.
- 验证命令: `scripts/check_native_deps.ps1`; `bash scripts/build_opus_ohos.sh all`; `source scripts/macos_env.sh`.
- 当前状态: 已修复; resolver helpers are on public `main`, with Mac clean-clone verification still required for a new machine.
- 是否适合写入长期规则: 是

### P-004

- ID: `P-004`
- 平台: Both
- 现象: A symbol check reports failure even though the symbol exists.
- 根因: `set -o pipefail` combined with `nm | grep -q` lets `grep` exit early and makes `nm` report SIGPIPE.
- 正确修复: Use `grep -Eq` without early exit or capture `nm` output before matching.
- 错误做法: Treat every pipeline nonzero status as a missing symbol without checking SIGPIPE.
- 验证命令: `bash scripts/build_rustdesk_ffi_ohos.sh <abi>` and the symbol checks in that script.
- 当前状态: 已修复; the current script uses non-quiet extended matching.
- 是否适合写入长期规则: 是

### P-005

- ID: `P-005`
- 平台: Both
- 现象: ArkTS test compilation fails with missing HarmonyOS Kit imports or a secondary SourceMap error.
- 根因: `default@OhosTestBuildArkTS` is the legacy task and does not receive the current HarmonyOS extension API path.
- 正确修复: Run `default@OhosTestCompileArkTS` and the corresponding `ohosTest` compile task.
- 错误做法: Use the old task name as the release acceptance gate or fix the secondary SourceMap exception first.
- 验证命令: `default@OhosTestCompileArkTS`; `ohosTest@OhosTestCompileArkTS`.
- 当前状态: 已修复; the 2026-07-13 recovery record passed both compile tasks.
- 是否适合写入长期规则: 是

### P-006

- ID: `P-006`
- 平台: Windows / macOS
- 现象: DevEco imports but Hvigor, Node or ohpm is not found; on the audited Windows shell `pwsh` is missing.
- 根因: IDE-bundled tools are not guaranteed to be on PATH, and PowerShell 7 is not part of every installation.
- 正确修复: Configure explicit machine-local tool paths; source `scripts/macos_env.sh` on Mac; use the repository PowerShell resolver for the compliance gate; do not silently skip the hook.
- 错误做法: Assume the IDE automatically exports all tool paths, or bypass the hook when `pwsh` is missing.
- 验证命令: `node --version`; `ohpm --version`; `source scripts/macos_env.sh`; `git config --get core.hooksPath`.
- 当前状态: 已修复/待新机验证; public helpers exist, Windows PowerShell 7 and Mac local discovery still need confirmation per machine.
- 是否适合写入长期规则: 是

### P-007

- ID: `P-007`
- 平台: Both
- 现象: Real FreeRDP builds fail after a clone, or source differs between machines.
- 根因: `freerdp/` is a gitlink and recursive submodules were not initialized or the source origin/revision was changed.
- 正确修复: Clone with `--recurse-submodules` or run `git submodule update --init --recursive`; preserve the public gitlink and provenance.
- 错误做法: Copy a dirty build directory or switch to an untracked mirror without updating provenance.
- 验证命令: `git submodule status --recursive`; `powershell.exe -File scripts/check_native_deps.ps1`.
- 当前状态: 已修复/待新机验证; public source is recorded, clean-clone verification remains queued.
- 是否适合写入长期规则: 是

### P-008

- ID: `P-008`
- 平台: Both
- 现象: A local commit pushes without the expected compliance check, or a private/archive ref is exposed.
- 根因: `core.hooksPath` was not `.githooks`, or the pre-push hook was bypassed.
- 正确修复: Install the repository hook, confirm `.githooks`, and let the hook verify the exact pushed tip in a temporary worktree.
- 错误做法: Use `--no-verify`, push `main`, push archive refs, or force-push to work around a failure.
- 验证命令: `powershell.exe -File scripts/install_git_hooks.ps1`; `git config --get core.hooksPath`; `scripts/tests/test_pre_push_history_guard.ps1`.
- 当前状态: 已修复; hook logic and tests are tracked and passed for this branch.
- 是否适合写入长期规则: 是

### P-009

- ID: `P-009`
- 平台: Both
- 现象: Two devices overwrite each other's task progress or a new task starts from stale code.
- 根因: Both devices edited one active branch, or a task started without syncing merged `main`.
- 正确修复: Use `main -> sync -> codex/<task> -> commit -> push -> PR -> required check -> merge commit -> main -> sync`; allow one active task branch only.
- 错误做法: Continue from an old branch, push directly to `main`, squash away the handoff boundary, or use `git add -A`.
- 验证命令: `scripts/sync_workspace.sh status` or `powershell.exe -File scripts/dev_workflow.ps1 status`; `finish-check`.
- 当前状态: 已修复; the shared workflow is public. PR #35 required a normal main merge after a concurrent main update.
- 是否适合写入长期规则: 是

### P-010

- ID: `P-010`
- 平台: Both
- 现象: A clean clone cannot sign or connect to cloud services, or private values leak into a PR.
- 根因: Signing profile, AGConnect file and `local.properties` are machine-local and were treated as source files.
- 正确修复: Create them from safe examples or private AGC/DevEco channels on each machine; verify only presence and configuration shape.
- 错误做法: Commit `.p12`, `.p7b`, `.cer`, secret-bearing AGConnect content, real build profile or local properties.
- 验证命令: `git ls-files build-profile.json5 local.properties entry/src/main/resources/rawfile/agconnect-services.json`; Light compliance gate.
- 当前状态: 已修复; private files are local configuration and are not part of the public audit commit.
- 是否适合写入长期规则: 是

### P-011

- ID: `P-011`
- 平台: Both
- 现象: OHOS native code fails to compile, links the wrong crypto library or produces memory/length errors.
- 根因: Linux C++/OpenSSL assumptions were applied to OHOS NDK and `Crypto_DataBlob.len`/random instance ownership were misunderstood.
- 正确修复: Use OHOS Crypto APIs, pthread/POSIX alternatives where required, byte lengths, per-use `OH_CryptoRand` instances and `libohcrypto.so`.
- 错误做法: Assume `std::filesystem`/`std::random_device`/all `std::thread` helpers are available or link `libcrypto_framework.so` for the OHOS Crypto API.
- 验证命令: Native CMake test target; `assembleHap`; targeted crypto tests where available.
- 当前状态: 已知限制; durable implementation guidance exists, but each ABI/build still needs validation.
- 是否适合写入长期规则: 是

### P-012

- ID: `P-012`
- 平台: Both
- 现象: RustDesk video/input/file transfer appears queued successfully but later freezes or has frame-size/decrypt errors.
- 根因: Enqueue success does not prove streaming-loop consumption; timeout retries can lose partial encrypted BytesCodec frames and desynchronize the stream.
- 正确修复: Instrument and prove consumption in the live loop; retain partial headers/payloads across timeout retries before decrypting complete frames.
- 错误做法: Keep changing ArkTS controls or GL timing after only observing NAPI enqueue success, or retry `read_exact()` from the middle of a frame.
- 验证命令: `cargo test --lib --no-default-features`; targeted crypto/control tests; filtered sanitized runtime evidence.
- 当前状态: 已修复 in the recorded public checkpoints; endpoint and device retest remains separate.
- 是否适合写入长期规则: 是

## Verification evidence summary

- Public history now includes the Mac migration and helper-script checks through merge commits; the Windows snapshot reports DevEco `6.1.1.280`, Node `18.20.1`, Hvigor `6.24.2`, ohpm `6.1.2.268`, LLVM `15.0.4`, Rust/Cargo `1.96.0` and both OHOS Rust targets.
- Windows audit checks: `git diff --check`, `verify_open_source_release.ps1 -Mode Light`, workflow policy tests, Opus artifact-location test and pre-push public-history guard all passed.
- Public runtime evidence: native `rdp_native_tests` `129 passed, 0 failed`; `default@OhosTestCompileArkTS` passed; production `assembleHap` passed. These do not replace Mac or real-device checks.
- The first direct workflow status run was blocked by a local Git global-ignore permission warning and by missing `pwsh`; no repository files were changed to hide that environment issue.
- The PR became dirty only because `origin/main` advanced concurrently; it was resolved with a normal merge before the required check and final merge.

## Next owner action

1. On the next device, sync public `main` and read the four shared state files before selecting a new task.
2. Source the Mac helper script or configure the Windows toolchain locally; do not copy caches, credentials or raw evidence.
3. Run sync/doctor/clean-clone checks and record only sanitized evidence.
4. Complete the remaining real-device RDP, RustDesk, SSH/SFTP, VNC, PIP/live-view and cloud-sync acceptance matrix.

## Explicit exclusion confirmation

This handoff contains no passwords, tokens, API keys, private-key contents, certificate contents, AGConnect secrets, real signing fields, raw Codex memory, session transcripts, logs, screenshots, device data, device serials or build artifacts.
