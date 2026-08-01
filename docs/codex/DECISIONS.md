# Shared Durable Decisions

## D-001 - GitHub is the public source of truth

GitHub `main` stores public source, tests, documents, scripts, submodule pointers and sanitized coordination state. A machine's private Codex memory is not copied wholesale.

## D-002 - One task, one branch

Each task uses one `codex/<task>` branch. Windows and macOS must not modify the same active task branch concurrently. The next device starts from merged `main`.

## D-003 - Sync is a start gate

Starting a task requires a clean `main`, `git fetch --prune origin`, fast-forward-only pull of `origin/main`, recursive submodule update and no other unfinished `codex/...` task branch. Local changes are never auto-stashed or overwritten. When the tree is dirty, stop and preserve the user's files.

## D-004 - Private inputs stay local

Signing files, AGConnect secrets, API keys, SDKs, build caches, user data, raw logs, screenshots, device addresses, real `local.properties`, real `build-profile.json5` and private machine paths never enter GitHub or a migration package. Examples may contain placeholders only.

## D-005 - PR is the handoff boundary

The PR description and `docs/codex/HANDOFF.md` record completed work, verification, blockers and next steps. Merge only after the required `open-source-compliance` check passes, using the repository's merge-commit policy rather than squash.

## D-006 - Memory is distilled, not synchronized

Only durable engineering conclusions are rewritten into `docs/codex`. Do not commit raw Codex memory, chat transcripts, session logs or private investigation evidence. Every extracted fact must be repository-backed, command-verified, or explicitly marked historical/unverified.

## D-007 - HarmonyOS API 23 is the compatibility ceiling

Before changing ArkTS or HarmonyOS APIs, search the local API 23 reference documentation. Do not import `@kit.uiMaterial` or other API 26-only facilities; use API 23-compatible UIDesignKit/HDS or native alternatives. ArkTS strict mode requires declared interfaces/types, avoids `any`/`unknown` in the affected patterns, and uses bracket indexing for dynamic object keys.

## D-008 - RDB cloud sync binds to the AGC store id, not the app account

OpenHarmony RDB cloud sync registers distributed tables against the local
store id (`StoreConfig.name` minus `.db`), and the AGC cloud schema
`database.name` must equal that store id (`rdb_schema_config` matches
`schema.name == storeName`; `RdbGeneralStore::SetDistributedTables` returns
14800000 when `CreateDistributedTable` fails). The AGC schema is deployed per
OS user/bundle and cannot contain per-account database names, so per-account
physical stores (`remotedesktop_owner-<sha>.db`) can never sync cloud data.
Consequences:
- Exactly one canonical cloud store (`remotedesktop.db`) exists per OS user;
  only an account whose platform cloud identity is verified opens it.
- Unverified accounts and device-local scopes use local-only stores
  (`remotedesktop_owner-<sha>.db` / `remotedesktop_device_local.db`) with cloud
  fail-closed; cloud isolation across accounts relies on the OS Huawei account
  dimension, not on app-level store names.
- In-app account switching to a different OS Huawei account falls back to the
  local hashed store; it never reads the previous account's canonical store.

## D-009 - One table's platform failure never blocks login or other tables

The startup bootstrap (cloud-first) is the upload gate: `bootstrapCompleted`
stays false and transfers stay fail-closed until an authoritative pull
succeeds. But a single table/platform failure (for example the AGC
`vncrecord` table missing its primary key, which makes the platform sync
return code=1) must not roll account login back to device-local, freeze every
other table's manual upload, or roll back a locally persisted VNC scope
selection. The account scope stays active with sync paused for the affected
table; resolution happens in that table's own settings (or in AGC for
cloud-table schema problems).

## D-010 - Encryption and backup sensitivity are user choices, not presumptions

Portable backup supports an explicit full mode selected at export time that
keeps passwords, SSH private keys, 2FA, VNC secrets/trust and device trust
(SSH host public keys / RDP certificates are public data and are retained in
every mode). Encryption configuration is the user's explicit choice: without
a configured crypto contract, sensitive rows upload/back up as stored
(plaintext by consent); with a configured contract every secret must be
ciphertext.

## D-008 - Toolchains are machine-local and ABI-explicit

Windows and macOS each configure their own DevEco SDK, native SDK, LLVM/CMake/Ninja, Node/Hvigor/ohpm, Rust/Cargo targets, linker, sysroot and private signing inputs. Do not migrate caches or assume a path from the other OS. OHOS Rust builds must select `aarch64-unknown-linux-ohos` or `x86_64-unknown-linux-ohos` with the matching Clang target and sysroot.

## D-009 - Keep HarmonyOS and OpenHarmony SDK roles separate on macOS

The full DevEco/HarmonyOS SDK is used by Hvigor for a product whose `runtimeOS` is HarmonyOS. The standalone API 23 OpenHarmony SDK is used by native clang/CMake/Rust tooling. `local.properties` and `scripts/macos_env.sh` keep these roots separate; silently selecting one for both roles produces misleading SDK or native-link failures.

## D-010 - macOS `hdc` comes from SDK toolchains

DevEco's `hdc` executable is shipped under the SDK `toolchains` directory. Source `scripts/macos_env.sh` before using `hdc`; it prefers the full HarmonyOS SDK toolchain and keeps the standalone API 23 toolchain as fallback. `hdc start` succeeding with an empty target list means the toolchain works but no authorized device is connected.

## D-011 - Verification names are part of the contract

Use `default@OhosTestCompileArkTS`; the legacy `default@OhosTestBuildArkTS` is not the valid HarmonyOS extension-Kit gate for this SDK. Use `ohosTest@OhosTestCompileArkTS` for the test module. Native/Rust tests, ABI builds, `assembleHap`, `git diff --check` and the Light compliance gate must be selected according to the changed surface. A Light pass does not claim real-device or Release readiness.

## D-012 - Native dependency provenance is coupled to the change

FreeRDP remains a public gitlink with recursive submodule initialization. RustDesk protocol inputs, FreeRDP, FFmpeg, Opus, OpenSSL, libssh2 or other build inputs require matching provenance, license, SBOM, notice and hash updates. The default configuration keeps `USE_REAL_FREERDP=OFF`; missing optional prebuilt libraries must produce an actionable build message.

## D-013 - Hooks are mandatory publication gates

The repository hook path is `.githooks`. The pre-push hook rejects archive/private history and verifies the actual pushed commit. It resolves `pwsh`, `powershell.exe` and the repository-local fallback through `scripts/resolve_powershell.sh` where applicable. Do not use `--no-verify`, push `main`, force-push or work around a hook failure by pushing another ref.

## D-014 - Evidence must distinguish code, environment and device state

A build or unit test proves only its own layer. SDK discovery failures, missing credentials, locked devices, WMS/PIP behavior, remote endpoint availability and cloud-account state must be reported as separate environment or device blockers. Do not promote an old log or a historical checkpoint into current acceptance evidence.

## D-015 - Stream correctness is proven after the queue

For RustDesk control/input/file-transfer work, an ArkTS/NAPI enqueue success is insufficient. Logs or counters must prove that the live streaming loop consumed the message. Encrypted TCP frame readers must preserve partial BytesCodec frames across timeout retries; `read_exact()` retries must not discard already-read bytes.

## D-016 - OHOS native APIs need platform-specific substitutes

Do not assume Linux C++ facilities are available in the OHOS NDK. `std::random_device`, `std::filesystem` and some thread/shared-pointer patterns have known limitations. Prefer OHOS Crypto APIs or pthread/POSIX alternatives; `Crypto_DataBlob.len` is bytes, `OH_CryptoRand` Create instances are per-use, and Crypto CMake must link `libohcrypto.so`.

## D-017 - UI lifecycle depends on ownership and mounting

`bindSheet` failures are primarily host-node mounting-timing issues, not a global sheet-count limit. Use a mounted `@Entry` host or a deliberate overlay. For PIP/renderer work, treat `ABOUT_TO_*` as transitional and wait for `STOPPED`/`ERROR`; surface generation, renderer ownership and decoder/frame-pump teardown must be explicit before reattachment.

## D-018 - Shell boundaries are explicit

Bash and PowerShell use different environment assignment and path syntax. Set `DEVECO_SDK_HOME`/`OHOS_SDK_HOME` in the shell that invokes a script, source `scripts/macos_env.sh` on macOS, normalize paths in Bash and use `powershell.exe`/`pwsh` only for PowerShell scripts. Do not assume IDE-bundled tools are on PATH.

## D-019 - Avoid early-closing symbol checks under `pipefail`

Large static archives must not be validated with `nm | grep -q` or an equivalent early-closing consumer under `set -o pipefail`. Use a full-stream match such as `grep -Eq` or capture the symbol list first, so a successful match cannot be reported as `nm` exit 141.

## D-020 - Planned implementation requires independent review before merge

For every task that changes source code, begin from synchronized `main` and create or continue exactly one documented `codex/<task>` branch. Record a concrete plan, implement it step by step, run the validation required for the changed surface and make task-scoped commits. After implementation, the main agent must spawn a sub-agent to independently compare the plan, the reported user problem, the diff and the verification evidence. Any review finding is a blocker until it is fixed, revalidated and committed. Merge the task branch back to `main` only after the sub-agent explicitly passes the review and the repository's required checks pass; then synchronize `main` and clean up the merged local/remote branch. Never merge with unresolved review findings, and never mix unrelated user changes into these commits.

## D-021 - Hvigor compile and assembleHap are mandatory closure gates

Every repository change must run the current checkout's DevEco Hvigor compile gate and production HAP packaging gate before commit completion, review, merge or delivery. On macOS, source `scripts/macos_env.sh`, then run `hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon` and `hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon`; Windows uses the DevEco-bundled Hvigor launcher with the same module, product, task parameters and non-daemon exit. Both commands must succeed on the current commit. Previous-session logs, a partial compile, or an environment failure cannot be reported as a pass; record the exact command, result and any blocker in `docs/codex/CURRENT.md`. The legacy `default@OhosTestBuildArkTS` task is never an acceptable substitute.

## D-022 - Cloud isolation follows the physical store boundary

HarmonyOS `setDistributedTables` and `cloudSync` operate at the physical database/table boundary; a SQL `userid` predicate cannot prove that a shared distributed store will not publish another owner's rows. Anonymous/device-local data and every verified Huawei owner therefore use separate physical RDB store identities. Only the current account's verified binding may register distributed tables or transfer cloud data. Every CRUD, migration, backup, crypto and callback path carries an account scope/generation; blank or mismatched owner, stale generation and unverified cloud identity fail closed.

## D-023 - Destructive data transitions require durable, scoped proof

Cloud-first apply, portable/system restore, schema migration and crypto disable/reset must not infer success from an accepted callback, an empty table, a local nonempty state or a UI step sequence. They use scoped durable state/receipts, transactional apply, mutation journal/checkpoint or quarantine, read-back validation and explicit terminal states. Sensitive native-first transfer is blocked unless the full payload is safe for the active encryption contract; absent backup sections are no-ops; device trust, plaintext consent and login/protocol tokens never enter cloud or portable backup. System BackupExtension and remote destructive operations remain disabled until real device/cloud evidence exists.
