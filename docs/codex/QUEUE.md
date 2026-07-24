# Shared Queue

Updated: 2026-07-24 Asia/Shanghai

## Now

- Code implementation and automated verification for RustDesk/RDP pinch zoom are complete.
- Final diff review, merge into main, merged-worktree verification and repair-branch deletion completed in 408902c22.
- Keep the two user-owned untracked planning documents outside commits.

## Next

- Execute the API 23 real-device matrix: RustDesk Windows, RustDesk macOS static desktop, RDP Windows and optional RustDesk remote-app TouchScale.
- During each session collect only sanitized counters for transform submit latency, retained redraw, frame-pump progress, input delivery and touch queue depth.
- Confirm cancel, surface destroy/recreate, PIP, background/foreground, rotation and reconnect return pinch/input state to idle.

## Later

- Tune thresholds against target-device refresh rate and high-resolution retained-frame copy cost.
- Decide whether the optional feature-flag rollback scheme is needed after device evidence; do not add flags solely to mask an unverified lifecycle issue.
- Complete the wider release matrix after pinch acceptance.

## Queue rules

- Only one daily codex/<task> branch may be active in the shared workspace.
- A new device must sync merged main, read CURRENT.md, QUEUE.md, DECISIONS.md and HANDOFF.md, and confirm a clean working tree before creating a task branch.
- User-owned changes are never auto-stashed, deleted, reset or mixed into a documentation commit.
- Completed implementation items are summarized in CURRENT.md; this file is not a session transcript.
