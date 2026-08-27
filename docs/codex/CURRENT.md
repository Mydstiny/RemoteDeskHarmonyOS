# Shared Current State

## Active task

- Task: `moonlight-crud-compatibility`
- Branch/base: `codex/moonlight-crud-compatibility` from synchronized `main@a773346f6`.
- Phase: independent review in progress for checkpoint `9e800bc5`.
- Plan: `docs/codex/plans/2026-08-27-moonlight-crud-compatibility.md`

## Objective

- Make Moonlight local CRUD authoritative and usable without Huawei Cloud Space.
- Keep legacy/pre-Moonlight data, malformed optional Moonlight data and cloud failures from blocking unrelated protocols or valid Moonlight hosts.
- Preserve tombstone/reset-epoch conflict semantics across settings revival, host re-add, backup restore and cloud projection.
- Report durable local commits truthfully and make compound host/trust creation crash-safe.

## Confirmed review scope

- Optional Moonlight schema/projection activation and malformed-row isolation.
- Host, trust, settings, profile and application-cache create/read/update/delete paths.
- Single/batch deletion, local unpair, no-account storage, export/import and portable restore.
- Legacy IDs, duplicate settings, deletion checkpoints and post-commit readback behavior.

## Implemented

- Ordinary host/profile deletion and local unpair are local-first; Huawei account login without Cloud Space cannot return `cloud_unavailable` for those actions.
- Host + trust creation/deletion and duplicate alias convergence use one local transaction; durable commits remain successful when only post-commit readback is transiently unavailable.
- Invalid optional Moonlight rows/cache entries are isolated instead of poisoning unrelated CRUD; malformed deletion checkpoints are quarantined and released.
- Settings tombstones and legacy aliases resolve deterministically, revive with a higher reset epoch and converge in one save.
- Pre-release host IDs are reused/converged, portable restore uses the Moonlight conflict policy, and missing additive columns are repaired without rejecting harmless legacy extras.
- Explicit owner-local deletion clears hidden malformed Moonlight rows and caches, while remote Sunshine unpair and rebuildable cache cleanup remain best effort.

## Verification

- Baseline `main@a773346f6` was clean and equal to `origin/main` when the task started.
- Exact `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 8 s 573 ms`).
- Exact signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 27 s 656 ms`).
- Signed HAP SHA-256: `ef646302f966b53bbc4539a7c7d57801e556ebbf941431c1c4f595b7da9361a4`.
- Legacy replay: PASS for `1.0.7`, `1.0.8-initial` and `1.1.1-initial`; all legacy rows preserved and schema converged to v5.
- `git diff --check`: PASS. Open-source compliance Light: PASS.
- `ohosTest@OhosTestCompileArkTS`: unavailable because the task is not registered (`00306054`); no device-test execution is claimed.

## Next

1. Await `/root/review_moonlight_crud_compat` review of `a773346f6..9e800bc5`.
2. Remediate any findings and rerun all required gates.
3. Complete branch/PR/main closure after review PASS.

## Blockers

- Device Hypium task remains unregistered (`00306054`); no on-device test claim will be made unless the task becomes available.
