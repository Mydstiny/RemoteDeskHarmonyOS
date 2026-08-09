# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`
- Branch: `codex/moonlight-complete-upgrade`
- Phase: G0, D1, D2 local storage/dormant cloud policies, D3 account lifecycle,
  deletion/status policies, portable backup/local restore and N1-01 exact
  upstream vendoring, N1-02 private product linkage and N1-03 native session
  ownership are checkpointed; AGC deployment/registration and runtime-backed
  lifecycle remain blocked.

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
- D3 account transitions now invoke an ordered Moonlight barrier before store
  quiescence and bind the resulting account lease after store activation. The
  dormant port closes mutation/launch first, then drains session, pairing,
  identity restore and cloud/journal work before clearing runtime secrets;
  failure keeps the transition fail closed. Checkpoint: `05e96d3`.
- D3 portable backup keeps format V3 and adds optional exact Moonlight cloud and
  local sections. Redacted mode carries settings/host/profile; full mode may add
  trust candidates; both always omit client identity, secret material, app
  cache, journal and recovery markers. Restore resolves both sections into only
  `moonlightlocalrecords` with `localonly=1`, quarantines ambiguity/orphans and
  requires re-pairing. Old V3 files remain readable. Checkpoint: `b27a58a`.
- D3 deletion commands now derive an owner-scoped preview from live records,
  cache, journal/quarantine/restore state and secure-identity inventory, then
  recompute it before execution. Local delete/forget/profile mutations are one
  CloudStore transaction; cloud tombstones and Host Control unpair fail closed
  without real ports. Secure identity cleanup precedes metadata deletion and
  reports partial terminal state honestly. Checkpoint: `ea32ffa`.
- N1-01 vendors the exact official common-c/ENet/nanors trees as 117 unchanged
  files, reconstructs all three Git trees offline (including common-c gitlinks),
  records SPDX/NOTICE/source-offer data and deterministic API 23 dual-ABI static
  receipts, and remains absent from product NAPI/HAP symbols. Checkpoint:
  `0013ba034`.
- N1-02 adds one project-owned CMake target boundary, reuses it from the
  standalone receipt build and privately links common-c/ENet to both product
  ABIs. Exported/undefined/NAPI-related symbols and the 423-path signed-HAP
  inventory are byte-identical to the pre-link baseline; no upstream include
  reaches 47 product compile commands. Checkpoint: `99edc58`.
- N1-03 checkpoint `18cdd39aa` adds the hidden pure-native process-wide owner,
  exact session/generation/token admission, interrupt fence, move-only leases
  and fail-closed drain without NAPI or UI.
- Current gates: `default@OhosTestCompileArkTS` passed with 138 focused Moonlight
  tests in 19 describe groups compile-registered; signed `assembleHap` passed;
  host native tests passed 355/355, including 13 deterministic owner cases;
  API 23 probe and isolated common-c builds passed both ABIs; source-archive,
  Git-tree, receipt, TOTP, Light and HAP-isolation gates passed. Both ABI
  defined/undefined/NAPI-init-register inventories remain exact, the signed HAP
  remains the same 423 paths, and all 48 product compile commands per ABI have
  zero upstream include leaks. HDC currently reports `Connect server failed`,
  so no new virtual-device Hypium execution is claimed. One of at most two
  `sol low` reviews was used for N1-01; all four findings were fixed and
  machine-verified without redispatching a review loop.

## Next

1. Execute only N1-04: add the pure-native `MoonlightHostApi` protocol core and
   focused host tests. Implement bounded request/response models, strict XML,
   official NvHTTP URL/endpoint compatibility, exact request generation,
   cancellation/deadline/address-attempt policy and redacted diagnostics behind
   an injected transport. Do not add NAPI, production credentials/pairing,
   media/input, UI or feature truth.
2. Keep D3-01 online coordinator wiring, D3-05 cloud-first promotion, D3-06
   cloud tombstone terminal execution and D3-08
   multi-device matrix blocked until development/test/production AGC receipts
   permit D2-07 registration.
3. Do not implement D2-07 registration until development/test/production AGC
   schema, authorization and index receipts complete D2-05/D2-06.

## Blockers

- `ohosTest@OhosTestCompileArkTS` remains unregistered (`00306054`), so the 138
  focused D1-D3 tests are compile-registered but no on-device Hypium pass is claimed.
- AGC development/test/production `moonlightrecordv1` schema, authorization and
  index receipts are absent; the table is therefore not in `CloudSyncPolicy.TABLES`.
- The configured HDC virtual device is currently unreachable (`Connect server
  failed`); this does not invalidate earlier RDB receipts but blocks new runtime checks.
- HAP/AppSpawn runtime probes, two real Sunshine hosts, AGC schema receipts and
  final ARM64 physical-device acceptance remain external release blockers.
