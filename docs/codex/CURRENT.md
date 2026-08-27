# Shared Current State

## Active task

- Task: `moonlight-cloud-delete-compat`
- Branch/base: `codex/moonlight-cloud-delete-compat` from synchronized `main@c0e0b5fdc`.
- Phase: independently reviewed and release-gated; remote PR delivery next.
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
- Reviewed code head: `b295ec7575a212aab322e45515c9c9a6af3c912b` (three focused commits over `main`).
- Exact `default@OhosTestCompileArkTS`: PASS on the clean reviewed head (`BUILD SUCCESSFUL in 6 s 152 ms`).
- Exact signed `assembleHap`: PASS on the clean reviewed head (`BUILD SUCCESSFUL in 13 s 195 ms`); signed HAP SHA-256 `7e9446ce1b6577202561b525580aaba4b3d0c73ae2ab978a9d8596fdb1324c01`.
- Light open-source compliance: PASS; `git diff --check`: PASS.
- Regression sources cover cloud-unavailable ordinary deletion, unreadable selection, non-deployed cloud table, cloud-first tombstone convergence, reset-epoch revival and old checkpoint completion.
- Independent review `/root/review_moonlight_delete`: initial P2/P3 findings remediated; final P0/P1/P2/P3 all zero.

## Blockers

- Device Hypium execution is unavailable because the repository's `ohosTest@OhosTestCompileArkTS` task is absent (`00306054`); this is an existing test-infrastructure limitation, not a product-path failure. No device runtime acceptance is claimed in this task.
