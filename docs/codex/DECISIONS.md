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
