# Shared Current State

## Active task

- Task: `moonlight-cloud-delete-compat`
- Branch/base: `codex/moonlight-cloud-delete-compat` from synchronized `main@c0e0b5fdc`.
- Phase: validated implementation; checkpoint commit and independent review next.
- Plan: `docs/codex/plans/2026-08-27-moonlight-cloud-delete-compat.md`

## Confirmed diagnosis

- Moonlight is durably selected for cloud sync by default, including legacy upgrades and device-local scope.
- Ordinary host/profile deletion treats durable selection as a requirement for an authoritative cloud pull before any local mutation.
- Huawei-account users without Cloud Space, offline users, device-local users, bootstrap-pending sessions and stale deletion checkpoints can therefore receive `cloud_unavailable` and cannot delete local Moonlight data.
- RDP/RustDesk/SSH already use local-first mutation journals; Moonlight has local tombstone primitives but the production delete route does not use their offline-compatible semantics.

## Implementation boundary

- Make ordinary Moonlight host/profile deletion local-first and durable, with deferred cloud promotion instead of an online-cloud admission gate.
- Preserve strict cloud readiness only for explicit cloud-wide deletion.
- Keep tombstones across restart/export/import and ensure later cloud recovery cannot resurrect deleted records.
- Isolate mixed batch results and replace raw internal error codes with actionable UI state.
- Cover device-local, Huawei account without Cloud Space, offline, bootstrap/checkpoint, legacy-upgrade and recovery cases.

## Verification

- Baseline: clean synchronized `main@c0e0b5fdc`.
- Exact `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 24 s 411 ms`).
- Exact signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 22 s 828 ms`).
- Light open-source compliance: PASS; `git diff --check`: PASS.
- Regression sources cover cloud-unavailable ordinary deletion, unreadable selection, non-deployed cloud table, cloud-first tombstone convergence, reset-epoch revival and old checkpoint completion.
- Independent review is required after the implementation checkpoint commit.

## Blockers

- Device Hypium execution is unavailable because the repository's `ohosTest@OhosTestCompileArkTS` task is absent (`00306054`); this is an existing test-infrastructure limitation, not a product-path failure. No device runtime acceptance is claimed in this task.
