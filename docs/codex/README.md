# Shared Codex State

This directory is the versioned, sanitized coordination state for Windows and macOS. It is the shared replacement for copying a machine's private Codex memory directory.

- `CURRENT.md`: current public commit, active task, completed work, verification and blockers.
- `QUEUE.md`: small Now/Next/Later queue. Keep only actionable items.
- `DECISIONS.md`: durable workflow and architecture decisions.
- `HANDOFF.md`: the latest task handoff checkpoint.

Do not write passwords, tokens, signing material, device addresses, personal paths, raw logs, screenshots, build output or user data here. Put those in the local handoff channel and record only a sanitized summary.

At task start, read `CURRENT.md` and `QUEUE.md`. Read `DECISIONS.md` when a workflow or architecture constraint is relevant. Update the shared files in the same task branch, then include them in the PR.
