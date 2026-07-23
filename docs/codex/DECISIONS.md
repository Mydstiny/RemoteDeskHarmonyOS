# Shared Durable Decisions

## D-001 - GitHub is the public source of truth

GitHub `main` stores public source, tests, scripts, submodule pointers and sanitized coordination state. A machine's private Codex memory is not copied wholesale.

## D-002 - One task, one branch

Each task uses one `codex/<task>` branch. Windows and macOS must not modify the same active branch concurrently. The next device starts from merged `main`.

## D-003 - Sync is a start gate

Starting a task requires a clean `main`, `git fetch --prune origin`, fast-forward-only pull of `origin/main`, recursive submodule update and no other unfinished task branch. Local changes are never auto-stashed or overwritten.

## D-004 - Private inputs stay local

Signing files, AGConnect secrets, API keys, SDKs, build caches, user data, raw logs, screenshots and machine-specific paths never enter GitHub or a migration package.

## D-005 - PR is the handoff boundary

The PR description and `docs/codex/HANDOFF.md` record completed work, verification, blockers and next steps. Merge only after the required open-source compliance check passes.

## D-006 - Keep HarmonyOS and OpenHarmony SDK roles separate on macOS

The full DevEco/HarmonyOS SDK is used by Hvigor for a project whose `runtimeOS` is
HarmonyOS. The standalone API 23 OpenHarmony SDK is used by the OHOS native
clang/CMake/Rust toolchain. `local.properties` and `scripts/macos_env.sh` must keep
these roots separate; silently selecting one for both roles produces misleading
SDK or native-link failures.

## D-007 - Do not combine `pipefail` with early-closing symbol checks

Large static archives must not be validated with `nm | grep -q` or an equivalent
early-closing consumer under `set -o pipefail`. Use a full-stream grep redirected
to `/dev/null`, or a temporary symbol list, so a successful match cannot be
reported as `nm` exit 141.

## D-008 - macOS `hdc` comes from SDK `toolchains`

DevEco's `hdc` executable is shipped under the SDK `toolchains` directory, not
the application-level `tools` directory. `scripts/macos_env.sh` puts the full
HarmonyOS SDK toolchain first and the standalone API 23 toolchain second. A Mac
CLI session must source the script before using `hdc`:

```sh
source scripts/macos_env.sh
hdc --version
hdc start
hdc list targets
```

If the command resolves and the server starts but the target list is `[Empty]`,
the toolchain is working and no HarmonyOS device or emulator is connected and
authorized yet.

## D-009 - API 23 is the compatibility ceiling

The project targets HarmonyOS API 23. Before adding an API or UI import, consult
the local API 23 reference; API 26-only facilities such as `@kit.uiMaterial` are
not valid substitutes. ArkTS strict mode requires declared interfaces and types,
rejects the affected `any`/`unknown` patterns, and uses bracket indexing for
dynamic object keys.

## D-010 - Toolchains are machine-local and ABI-explicit

Windows and macOS configure their own DevEco SDK, native SDK, LLVM/CMake/Ninja,
Node/Hvigor/ohpm, Rust targets, linkers, sysroots and private signing inputs.
Never copy caches or absolute paths across operating systems. OHOS Rust builds
must select `aarch64-unknown-linux-ohos` or `x86_64-unknown-linux-ohos` with the
matching Clang target and sysroot.

## D-011 - Verification task names are part of the contract

Use `default@OhosTestCompileArkTS` and the matching
`ohosTest@OhosTestCompileArkTS` task. The legacy
`default@OhosTestBuildArkTS` task is not the acceptance gate for this SDK.
Select native/Rust tests, both ABI builds, `assembleHap`, `git diff --check` and
the Light compliance gate according to the changed surface; a Light pass does
not claim real-device or release readiness.

## D-012 - Native dependency provenance follows the change

FreeRDP remains a public gitlink with recursive submodule initialization. Any
FreeRDP, RustDesk protocol input, FFmpeg, Opus, OpenSSL, libssh2 or other native
dependency change requires matching provenance, license, SBOM, notice and hash
updates. Do not replace a public gitlink with a dirty copied build directory.

## D-013 - Hooks are mandatory publication gates

The `.githooks` path and pre-push history/compliance checks are part of the
publication contract. Do not use `--no-verify`, push `main`, force-push, or work
around a hook failure by pushing another ref. Windows development still needs
PowerShell 7 (`pwsh`) for the mandated workflow even when local scripts happen
to run under Windows PowerShell 5.1.

## D-014 - Evidence must distinguish code, environment and device state

A build or unit test proves only its own layer. SDK discovery, missing private
credentials, locked devices, WMS/PIP behavior, endpoint availability and cloud
account state must be recorded as separate environment or device blockers. Do
not promote an old log or historical checkpoint into current acceptance
evidence.

## D-015 - Stream correctness is proven after the queue

For RustDesk control, input and file-transfer work, enqueue success does not
prove that the live streaming loop consumed the message. Encrypted TCP readers
must preserve partial BytesCodec headers and payloads across timeout retries;
`read_exact` retries must not discard bytes already read from a frame.

## D-016 - OHOS native APIs need platform-specific substitutes

Do not assume Linux C++ facilities are available in the OHOS NDK. Known fragile
assumptions include `std::random_device`, `std::filesystem` and some threading
helpers. Prefer OHOS Crypto or pthread/POSIX alternatives where required;
`Crypto_DataBlob.len` is measured in bytes, random instances are per-use, and
OHOS Crypto builds link the matching `libohcrypto.so`.

## D-017 - UI lifecycle depends on ownership and mounting

`bindSheet` failures are commonly host mounting-timing issues rather than a
global sheet-count limit. Use a mounted entry host or deliberate overlay. For
PIP and renderer work, treat transitional callbacks as transitional, wait for
terminal states, and make surface generation, renderer ownership and decoder
teardown explicit before reattachment.
