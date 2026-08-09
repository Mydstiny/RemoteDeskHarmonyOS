# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`
- Branch: `codex/moonlight-complete-upgrade`
- Phase: G0 static baseline and D1 domain-policy checkpoint complete; D2 local
  storage/adapter work is next.

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
- D1 now contains bounded DTOs, the exact 19/20-column record envelopes,
  canonical/hash/quarantine policy, deterministic conflict handling, four-layer
  settings resolution, capability/feature truth and a generation-fenced session
  state machine. All release flags remain false.
- Current gates: `default@OhosTestCompileArkTS` passed; signed `assembleHap`
  passed in 2m04.692s; host native tests passed 342/342 outside the socket-
  restricted sandbox; Moonlight API 23 probe passed arm64-v8a and x86_64;
  Light compliance passed.

## Next

1. Implement D2-01 local RDB migrations for `moonlightrecordv1`,
   `moonlightlocalrecords` and `moonlightappcache` without registering a cloud table.
2. Add the owner/generation-fenced repository, cache and exact cloud row adapter.
3. Keep cloud schema, identity, host-control and streaming truth disabled until
   their external/runtime gates pass.

## Blockers

- `ohosTest@OhosTestCompileArkTS` remains unregistered (`00306054`), so the 43
  focused D1 tests are compile-registered but no on-device Hypium pass is claimed.
- HAP/AppSpawn runtime probes, two real Sunshine hosts, AGC schema receipts and
  final ARM64 physical-device acceptance remain external release blockers.
