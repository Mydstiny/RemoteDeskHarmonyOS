# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`
- Branch: `codex/moonlight-complete-upgrade`
- Phase: G0, D1-D3 local/dormant lifecycle and N1-01～N1-05 are checkpointed;
  AGC registration and runtime-backed HUKS, pairing and lifecycle remain blocked.

## Context

- Complete Moonlight/Sunshine without regressing RDP, RustDesk, SSH/SFTP, VNC,
  cloud synchronization, backup or account isolation.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`.
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`.
- The existing disabled Moonlight FAB entry remains the only user-visible state
  until host-control, streaming, data, lifecycle and release gates all pass.
- Independent review is limited to at most two reviewer agents, both using
  `sol low`; do not redispatch the same review after context compaction.

## Verification

- Baseline: clean `main@aeb0cdac5`, equal to `origin/main`, 2026-08-09.
- Official upstream pins, license hashes, API 23 dual-ABI static probe and an
  ARM64 API 24 virtual-device service inventory are recorded in the ledger.
- D1 contains bounded DTOs, exact 19/20-column envelopes, canonical/quarantine/
  conflict policy, four-layer settings, fail-closed feature truth and session state.
- D2 creates exact `moonlightrecordv1`, `moonlightlocalrecords` and
  `moonlightappcache` schemas without changing the eight-table distributed
  registration set. Lease-fenced repository/cache operations reject cross-owner
  data and cloud I/O; the adapter rejects malformed/local-only rows. `3bbdc61`.
- D2 row-sensitive transfer rejects malformed/plain identity rows, the five
  owner-scoped logical scopes default to `[]`, and selection replacement follows
  stage → RDB projection → Preferences with rollback; dormant materialization is
  lease-fenced and always reports `cloudAttempted=false`. `5d9c2ff`.
- API 24 ARM64 emulator receipt: owner-store `user_version=5`; table shapes are
  exactly 19/20/16 columns; one owner-bound migration receipt remains after a
  process restart (`tables=3`, `receipts=1`).
- D3 account transitions now invoke an ordered Moonlight barrier before store
  quiescence, drains mutation/launch→session→pairing→identity→cloud/journal→secret,
  then binds the new lease; failure stays closed. `05e96d3`.
- D3 portable backup keeps format V3 and adds optional exact Moonlight cloud and
  local sections. Redacted mode carries settings/host/profile; full mode may add
  trust candidates; identity/secret/cache/journal/markers are excluded. Restore
  writes only local-only overlay, quarantines ambiguity and requires re-pairing.
  Old V3 remains readable. `b27a58a`.
- D3 deletion commands now derive an owner-scoped preview from live records,
  cache, journal/quarantine/restore state and secure-identity inventory, then
  recompute before execution. Local deletion is transactional; unavailable cloud/
  Host ports fail closed; identity cleanup precedes metadata. `ea32ffa`.
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
- N1-04 checkpoint `fd2d7ec92` adds a transport-injected pure-native Host API:
  official requests, one deadline, exact cancel/stale fences, read-only fallback,
  mutation no-replay/unknown, cancel verification, bounded XML and redacted
  diagnostics, without a NAPI caller, identity, pairing, media, input or UI.
- N1-05 checkpoint `599882ada` adds a hidden pure-native secure-identity core:
  owner+installation-scoped opaque aliases, official-compatible RSA-2048 client
  certificates, validated move-only signing/TLS leases, explicit cleanse/page-lock
  evidence, exact mutation/cancel/drain/inventory/delete semantics and a fail-closed
  API 23 HUKS/Asset capability boundary. The product backend remains unavailable
  until an in-HAP AppSpawn probe proves either direct HUKS TLS signing or HUKS
  AES-GCM wrapping plus atomic encrypted-blob persistence; no plaintext fallback
  exists.
- Current gates: both Hvigor tasks, 138-test ArkTS registration, signed HAP,
  native and ASan/UBSan 384/384, API 23 dual-ABI probe/build, source-archive,
  Git-tree, receipt, TOTP, Light and isolation all passed. Both ABI symbol/NAPI
  inventories and 423 HAP paths remain exact; each ABI keeps 48 `rdpnapi` plus
  one private Host API and two private secure-identity compile commands with zero
  upstream include leaks. HDC still says `Connect server failed`, so no new
  Hypium or HUKS runtime execution is claimed. One of two
  `sol low` reviews was used for N1-01; all four findings were fixed and
  machine-verified without redispatching a review loop.

## Next

1. Execute only N1-06 as an injected/dormant native pairing state machine. Reuse
   N1-04 for every HTTP/XML operation and N1-05 for the exact identity lease;
   implement the locked official salt/PIN, server-certificate candidate,
   challenge, signed-secret, final challenge and best-effort rollback sequence
   with exact request/generation/owner cancellation and full secret zeroization.
   Do not add a second transport/identity store, production NAPI/UI, trust/cloud
   persistence, catalog/media/input or any feature truth. Because the product
   identity backend is not runtime-proven, N1-06 may pass only through injected
   test seams and must remain unreachable in the signed HAP.
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
- HAP/AppSpawn access to HUKS-backed RSA TLS signing, or to HUKS AES-GCM wrapping
  plus an atomic app-private encrypted-blob backend, has not been runtime-proven;
  the N1-05 product identity backend therefore intentionally returns unavailable.
- HAP/AppSpawn runtime probes, two real Sunshine hosts, AGC schema receipts and
  final ARM64 physical-device acceptance remain external release blockers.
