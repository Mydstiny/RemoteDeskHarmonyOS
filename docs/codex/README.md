# Shared Codex State

This directory is the versioned, sanitized coordination state for Windows and
macOS. It is the shared replacement for copying a machine's private Codex
memory directory.

- `STATE.json`: compact machine-readable task, blocker, plan, and review state.
- `CURRENT.md`: short startup resume card; keep it below 120 lines.
- `QUEUE.md`: actionable Now/Next/Later queue; completed items leave this file.
- `REVIEW_RECEIPTS.jsonl`: content-addressed review receipts, not chat logs.
- `DECISIONS.md`: durable workflow and architecture decisions.
- `HANDOFF.md`: short handoff for the active task.
- `archive/YYYY-MM/`: complete historical snapshots, searchable but not startup input.

Do not write passwords, tokens, signing material, device addresses, personal
paths, raw logs, screenshots, build output, user data, or raw model/session
transcripts here. Record only sanitized facts that another session can verify.

At task start, run the platform workflow `status` command. It prints the
compact state and the review action. Read `CURRENT.md` and `QUEUE.md`; read
`DECISIONS.md`, `HANDOFF.md`, a plan, or an archive only when the status or
task scope links to it.

## Review Receipts

A PASS receipt is valid only when the task base, declared plan hash, and
declared code-scope tree hash match the current checkout. Documentation-only
changes do not invalidate a code receipt. Code, plan, base, or scope changes
produce `REVIEW_REQUIRED`. A BLOCKED receipt produces `RESUME_REVIEW`; an
incomplete reviewer is never converted to PASS by a later session.

The receipt records a reviewer task ID so a compressed session can continue
the same review instead of dispatching a duplicate. Review status is separate
from build, device, endpoint, cloud, and release readiness.

Before an independent review, declare exact file paths or directory prefixes
in `STATE.json.review.scope`, make a checkpoint commit, and run:

```sh
node scripts/codex_state.mjs snapshot
```

After an explicit reviewer PASS, append one JSON line containing the printed
`base`, `scopeTreeHash`, `planHash`, reviewer task ID, reviewed head, and
`status: "PASS"`. Never hand-edit a BLOCKED receipt into PASS; resolve the
reviewer task or create a new review after the code/plan state genuinely
changes.
