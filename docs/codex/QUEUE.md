# Shared Queue

Updated: 2026-07-23 Asia/Shanghai

## Now

- No active migration task. Windows memory sanitization and the Mac migration handoff are merged in `main` through normal merge commits.

## Next

- On the next task, sync `main` first and confirm a clean working tree.
- On Windows, confirm PowerShell 7 availability and run the shared-state, submodule and history gates from a clean clone.
- On macOS, source `scripts/macos_env.sh`, verify the full DevEco SDK/native API 23 SDK role split, Rust targets, `hdc` and the PowerShell resolver.
- Run the clean-clone smoke checks and record only sanitized pass/fail summaries.

## Later

- Complete real-device acceptance for RustDesk and RDP PIP/live-view registration, repeated foreground/background cycles and no-session exit behavior.
- Complete cloud-sync protection, first-install white-screen and full four-protocol release matrices on an unlocked target.
- Extend remote file-transfer coverage and complete the deferred release matrix.

## Queue rules

- Only one daily `codex/<task>` branch may be active in the shared workspace.
- A new device must sync merged `main`, read `CURRENT.md`, `QUEUE.md`, `DECISIONS.md` and `HANDOFF.md`, and confirm a clean working tree before creating a task branch.
- User-owned changes are never auto-stashed, deleted, reset or mixed into a documentation commit.
- Completed items are removed or summarized in `CURRENT.md`; this file is not a session transcript.
