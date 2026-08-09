# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`
- Branch: `codex/moonlight-complete-upgrade`
- Phase: G0, D1, D2 local storage and D2 dormant cloud policies are checkpointed;
  AGC deployment/registration remains blocked and D3 lifecycle work is next.

## Context

- Implement the complete Moonlight/Sunshine upgrade plan without regressing RDP,
  RustDesk, SSH/SFTP, VNC, cloud synchronization, backup or account isolation.
- Authoritative plan:
  `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`.
- Live evidence ledger:
  `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`.
- The existing disabled Moonlight FAB entry remains the only user-visible state
  until host-control, streaming, data, lifecycle and release gates all pass.
- UI debugging may use the connected HDC virtual device; final acceptance remains
  on the user's physical device.
- Independent review is limited to at most two reviewer agents, both using
  `sol low`; do not redispatch the same review after context compaction.

## Scope

- G0 upstream/security/license locks and HarmonyOS API 23 probes.
- D1-D3 Moonlight models, one `moonlightrecordv1` cloud table, local overlay,
  account/cloud/backup lifecycle and tests.
- N1-N3 official common-c control/media/input integration.
- U1-S1 unified add/settings/catalog/session UI and lifecycle.
- Required common policies only where Moonlight cannot be integrated safely
  without them; existing protocol behavior must remain unchanged.

## Verification

- Baseline: clean `main@aeb0cdac5`, equal to `origin/main`, 2026-08-09.
- Official upstream pins, license hashes, API 23 dual-ABI static probe and an
  ARM64 API 24 virtual-device service inventory are recorded in the ledger.
- D1 contains bounded DTOs, the exact 19/20-column record envelopes,
  canonical/hash/quarantine policy, deterministic conflict handling, four-layer
  settings resolution, capability/feature truth and a generation-fenced session
  state machine. All release flags remain false.
- D2 creates exact `moonlightrecordv1`, `moonlightlocalrecords` and
  `moonlightappcache` schemas without changing the eight-table distributed
  registration set. Repository/cache operations require the complete account
  lease, recheck generation before/after local transactions, journal user rows,
  reject cross-owner data and never invoke cloud I/O. The cloud adapter rejects
  missing/unknown columns and `localonly=1`.
- D2 local-first code/test checkpoint: `3bbdc61`.
- D2 row-sensitive transfer rejects malformed/plain identity rows, the five
  owner-scoped logical scopes default to `[]`, and selection replacement follows
  stage → RDB projection → Preferences persist with rollback. The dormant
  materializer validates/quarantines/downloads/promotes through a lease-fenced
  port and always reports `cloudAttempted=false`. Code/test checkpoint: `5d9c2ff`.
- API 24 ARM64 emulator receipt: owner-store `user_version=5`; table shapes are
  exactly 19/20/16 columns; one owner-bound migration receipt remains after a
  process restart (`tables=3`, `receipts=1`).
- Current gates: `default@OhosTestCompileArkTS` passed with 92 focused Moonlight
  tests compile-registered; signed `assembleHap` passed in 7.710s; host native
  tests passed 342/342 outside the socket-
  restricted sandbox; Moonlight API 23 probe passed arm64-v8a and x86_64;
  Light compliance passed.

## Next

1. Implement D3 account lease/barrier and local backup/restore inventory without
   enabling Moonlight cloud transfer or changing existing protocol behavior.
2. Do not implement D2-07 registration until development/test/production AGC
   schema, authorization and index receipts complete D2-05/D2-06.
3. Continue D3 backup/account lifecycle integration without enabling cloud,
   identity, host-control, streaming or protocol availability truth.

## Blockers

- `ohosTest@OhosTestCompileArkTS` remains unregistered (`00306054`), so the 92
  focused D1/D2 tests are compile-registered but no on-device Hypium pass is claimed.
- AGC development/test/production `moonlightrecordv1` schema, authorization and
  index receipts are absent; the table is therefore not in `CloudSyncPolicy.TABLES`.
- HAP/AppSpawn runtime probes, two real Sunshine hosts, AGC schema receipts and
  final ARM64 physical-device acceptance remain external release blockers.
