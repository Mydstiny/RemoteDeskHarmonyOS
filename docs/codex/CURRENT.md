# Shared Current State

## Active task

- Task: `cloud-sync-compatibility-first-recovery`
- Branch: `codex/system-clipboard-activation-fix`; user authorized work on the current branch.
- Increment: `54f9d25df..a4d0aebb1`.
- Phase: implemented, locally verified and independently reviewed; fixed HAP device acceptance is pending.
- Plan: `docs/codex/plans/2026-08-28-cloud-sync-compatibility-first-recovery.md`

## Root cause and result

- Device logs at `192.168.3.235:38451` showed Account Kit login and RDB creation succeeded, then optional historical account-store migration failed with `401 invalid parameters`; that optional failure was incorrectly surfaced as `账号物理数据域打开失败`.
- Canonical failure now falls back to the exact same account's hashed local store. Login and local CRUD remain available while cloud recovery is deferred; stale canonical data is never reverse-imported into that authoritative fallback.
- Local rows commit only when dirty intent is durable in the same RDB transaction. Broken checkpoints are quarantined before writes reopen, and startup/retry share the same durable cloud-admission state.
- Account migration preserves clear/delete and empty-table semantics. VNC/Moonlight exact schema and public-data rules, higher source schemas, account ownership and crypto ownership remain integrity boundaries rather than arbitrary availability policies.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 6 s 201 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 50 s 090 ms`).
- Signed HAP SHA-256: `b6bad805365e0af421336fbe796a25cb5baaa28d651a8e1e14e356df733a8ca3`.
- `git diff --check` and Light open-source compliance: PASS.
- `ohosTest@OhosTestCompileArkTS`: unavailable (`00306054`, task is not registered); focused policies compile through the mandatory test target.
- Independent review `/root/cloud_sync_fix_review`: PASS; no remaining P0/P1/P2. Non-blocking P3 is deeper real-RDB fault-injection coverage.

## Device acceptance / blockers

- The fixed HAP has not been installed. Acceptance on `192.168.3.235:38451` must verify login remains usable after the historical migration `401`, exact-owner local data visibility, local save/restart/offline behavior, canonical recovery and no stale-row resurrection.
- Prior remote keyboard/sidebar acceptance on `.235` remains queued. `.236:40123` still requires a release-provisioned HAP or explicit destructive-uninstall authorization; its existing data remains preserved.
