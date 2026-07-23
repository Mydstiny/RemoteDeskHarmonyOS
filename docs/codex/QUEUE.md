# Shared Queue

Updated: 2026-07-23 Asia/Shanghai

## Now

- Complete the Windows memory sanitization audit on `codex/windows-memory-sanitize`.
- Run `git diff --check`, the Light open-source gate, the workflow parser tests and the repository finish check without staging user-owned files.
- Push the branch, open a PR to `main`, wait for `open-source-compliance`, then merge with a merge commit.

## Next

- On macOS, sync the merged `main` with `./scripts/sync_workspace.sh sync` and verify recursive FreeRDP submodules.
- Configure Mac-local DevEco/API 23 SDK, native toolchain, Rust targets, PowerShell 7, signing profile and AGConnect file through private channels.
- Run the clean-clone smoke checks and record only sanitized pass/fail summaries.

## Later

- Complete real-device acceptance for RustDesk and RDP PIP/live-view registration, repeated foreground/background cycles and no-session exit behavior.
- Complete cloud-sync protection, first-install white-screen and full four-protocol release matrices on an unlocked target.
- Keep VNC, deferred file-transfer coverage and remaining release evidence separate from the migration handoff.

## Queue rules

- Only one daily `codex/<task>` branch may be active in the shared workspace.
- A new device must sync merged `main`, read `CURRENT.md`, `QUEUE.md`, `DECISIONS.md` and `HANDOFF.md`, and confirm a clean working tree before creating a task branch.
- User-owned changes are never auto-stashed, deleted, reset or mixed into a documentation commit.
- Completed items are removed or summarized in `CURRENT.md`; this file is not a session transcript.
