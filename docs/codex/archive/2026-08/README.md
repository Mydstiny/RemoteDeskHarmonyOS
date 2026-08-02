# 2026-08 Shared State Archive

This archive was created on 2026-08-02. The three legacy files are preserved
byte-for-byte from the pre-compaction state; nothing was removed from the
shared memory record.

- `CURRENT-legacy.md`: full historical checkpoints and verification notes.
- `QUEUE-legacy.md`: historical Now/Next/Later entries and queue rules.
- `HANDOFF-legacy.md`: completed-task handoffs and historical validation notes.

Do not read these files during normal startup. Use `scripts/sync_workspace.sh
status` or the Windows `dev_workflow.ps1 status` output first, then read the
short `CURRENT.md` and `QUEUE.md`. Search this archive only when the current
task links to a historical checkpoint, reviewer finding, or decision that is
not present in `DECISIONS.md`.
