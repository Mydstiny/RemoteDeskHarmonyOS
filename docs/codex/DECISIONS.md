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
