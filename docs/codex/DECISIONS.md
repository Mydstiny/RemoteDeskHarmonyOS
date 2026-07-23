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
