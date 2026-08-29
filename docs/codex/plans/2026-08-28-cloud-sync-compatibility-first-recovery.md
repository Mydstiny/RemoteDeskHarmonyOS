# Cloud sync compatibility-first recovery

## Root cause

- On `192.168.3.235:38451` at 2026-08-28 19:48:42, Account Kit authentication and local RDB creation succeeded, then an optional historical account-store migration returned `401 invalid parameters`.
- That optional migration failure was coupled to physical-domain activation, so login was reported as `账号物理数据域打开失败` even though an exact-owner local database remained usable.
- Dirty-state, recovery checkpoints and canonical/hashed migration paths had additional fail-open or reverse-copy edges that could block saving or revive stale rows.

## Compatibility contract

1. Authentication and exact-owner local persistence remain available when optional migration, cloud registration or lifecycle metadata fails.
2. Local business rows commit only with durable dirty intent in the same RDB transaction; otherwise the write rolls back truthfully.
3. Canonical recovery never reverse-imports stale canonical data into the authoritative hashed fallback.
4. Account-scoped migration preserves clear/delete semantics by replacing only the proven owner's table snapshot before copying.
5. Higher schemas, cross-account ownership, ambiguous crypto ownership, malformed VNC/Moonlight rows and device-local trust/secret data remain hard integrity boundaries.

## Implemented recovery

- Fall back to the same account's hashed local store and keep login/local CRUD available when canonical migration fails.
- Quarantine unrecoverable download checkpoints before reopening local writes; share one durable admission gate across startup and retry.
- Carry RDB and compatibility dirty markers through account-store migration, including empty-table clears, and prevent stale cloud-first overwrite.
- Validate VNC/Moonlight exact schemas and public-cloud payload boundaries; stop safely on newer source schemas.
- Degrade cloud coordination to local-only when lifecycle state cannot be persisted instead of blocking the data store.

## Verification and acceptance

- Mandatory ArkTS test compile and signed HAP assembly must pass after the final code change.
- Independent review must report no remaining P0/P1/P2.
- Device acceptance must cover login after the historical `401`, local CRUD/restart/offline behavior, exact-owner hashed visibility, canonical recovery and native/cloud directions without data resurrection.
