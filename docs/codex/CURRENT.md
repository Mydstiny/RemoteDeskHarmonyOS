# Shared Current State

This file is the compact startup resume card. Historical checkpoints are
preserved in `docs/codex/archive/2026-08/`; do not read the archive unless the
task or state below links to it.

## Active Task

- Task: `rustdesk-complete-repair`
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `54023b3f4`, based on `main@34946adbc`; branch is ahead by 6 and not behind.
- Phase: RustDesk repair checkpoint committed; existing review blocker remains unchanged.
- Worktree: clean after the RustDesk repair commit. Do not stage unrelated changes.
- Next: resume the existing RustDesk review state without redispatching the incomplete reviewer.

## Current Findings

- `RemoteDesktop.doConnect()` initializes the renderer before `loader.connect()` creates the VNC session owner.
- The native renderer entry point requires an active owner before `GLRenderer::Init()`, so cold-start VNC can fail with `rc=-1` before EGL/GL.
- The repair boundary is reservation -> renderer owner bind -> activation transaction. Do not relax owner checks, reuse stale owners, or fabricate tokens.
- The VNC TLS/settings/Repeater V3 plan is documented but not implemented. Keep its direct-host and Repeater-Gateway trust ownership separate.

## RustDesk Repair Checkpoint

- A successful RustDesk 2FA binding now enables auto-submit by default; TOTP privacy protection gates binding/auto-fill only when `totpLocked` is enabled.
- Automatic 2FA submission no longer reopens the manual sheet on every auth poll; manual entry is retained for missing entries, failed submission, cancellation, and wrong-code responses.
- Request-approval connections clear transient passwords and pass `rdAuthMode=1`; the existing FFI core waits for remote approval instead of falling back to password login.
- TOTP cards now render bundled rawfile brand assets directly, including the RustDesk logo, with initials only as an explicit/failure fallback.

## Blockers

- `hdc list targets` and `hdc shell` return `Connect server failed`; no current `hilog` evidence is available.
- The previously dispatched read-only reviewer (`019faca9-bf75-7e62-a251-541ce970c029`) produced no report because of capacity limits. This is `BLOCKED`, not PASS; resume it or record a new explicitly authorized review after the existing task state changes, never duplicate it solely because of context compression.
- API 23 real-device, endpoint interoperability, cloud and cross-protocol acceptance remain separate from local source/build evidence.

## Verification

- The current state records `default@OhosTestCompileArkTS`, signed `assembleHap`, Light compliance, and `git diff --check` as passed on 2026-08-02.
- Both gates were rerun after `54023b3f4` and passed on 2026-08-02; output still contains only existing dependency/deprecation warnings.
- `ohosTest@OhosTestCompileArkTS` remains unavailable when task `00306054` is not registered.

## Review Protocol

- Machine state: `docs/codex/STATE.json`.
- Receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- Run `scripts/sync_workspace.sh status` or `scripts/dev_workflow.ps1 status` and obey `review=...`.
- `SKIP_FULL_REVIEW` means the declared base, plan hash, and code-scope tree hash still match a PASS receipt; do not reopen that unchanged scope.
- `REVIEW_REQUIRED` means inspect only the reported scope/delta after a checkpoint commit.
- `RESUME_REVIEW` means continue the recorded reviewer task; a missing report is never a pass.

## Handoff

Full pre-compaction records are preserved in `docs/codex/archive/2026-08/`.
Durable architecture rules remain in `docs/codex/DECISIONS.md`.
