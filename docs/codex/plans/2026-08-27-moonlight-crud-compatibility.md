# Moonlight CRUD Compatibility Plan

## Goal

Make every Moonlight local CRUD operation remain usable under no-account, no-Cloud-Space, legacy upgrade, malformed optional data and transient readback conditions, without weakening account isolation or tombstone convergence.

## Audited failure classes

1. Optional Moonlight schema or one malformed row can close the shared mutation gate.
2. Full-owner reads couple unrelated hosts and rebuildable app cache to targeted CRUD.
3. Settings tombstones cannot be explicitly revived and duplicate settings cannot self-heal.
4. Host edits can commit durably while UI reports failure; unchanged order reports a false commit.
5. Host and trust creation spans two transactions and is not crash atomic.
6. Portable restore blindly overwrites newer rows and tombstones.
7. Legacy host IDs and malformed deletion checkpoints have no deterministic recovery path.
8. Local unpair is blocked by remote bridge/readiness even though local trust is authoritative.

## Implementation sequence

1. Add focused policy/service tests for each failure class.
2. Decouple optional Moonlight projection from shared scope activation; quarantine bad rows and discard invalid rebuildable cache entries.
3. Preserve or increment reset epochs for settings and legacy host revival; deterministically converge duplicate settings.
4. Normalize post-commit mutation results and UI refresh behavior.
5. Introduce an atomic host/trust local commit boundary or durable recovery checkpoint.
6. Resolve portable restore against existing Moonlight rows through the conflict policy.
7. Recover or quarantine unreadable deletion checkpoints without blocking ordinary local CRUD.
8. Commit local unpair first and make Sunshine notification best effort.

## Required verification

- Focused ArkTS policy/service tests and test registration.
- `default@OhosTestCompileArkTS`.
- Signed `assembleHap`.
- `git diff --check` and open-source Light gate.
- Independent sub-agent review of the committed implementation scope, followed by remediation and re-verification if needed.

## Safety constraints

- Never delete legacy protocol data because optional Moonlight storage is unavailable.
- Never revive an equal/lower reset-epoch tombstone implicitly.
- Never cross account/store lease boundaries.
- Never report a durable local commit as an uncommitted failure.
- Cloud projection and remote Sunshine operations remain best effort after local truth is durable.
