# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`
- Branch: `codex/moonlight-complete-upgrade`
- Phase: G0, D1-D3 local/dormant lifecycle and N1-01～N1-08 are checkpointed;
  N2-01 dormant stream-config/offer contract is next; AGC and product runtime remain blocked.

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
- N1-01 checkpoint `0013ba034` vendors 117 unchanged common-c/ENet/nanors files,
  reconstructs all three Git trees offline, records compliance/source/dual-ABI
  receipts and remains absent from product NAPI/HAP symbols.
- N1-02 checkpoint `99edc58` adds the single CMake target boundary and privately
  links common-c/ENet to both ABIs while preserving symbol and 423-path HAP
  inventories with no upstream include in product commands.
- N1-03 checkpoint `18cdd39aa` adds the hidden pure-native process-wide owner,
  exact session/generation/token admission, interrupt fence, move-only leases
  and fail-closed drain without NAPI or UI.
- N1-04 checkpoint `fd2d7ec92` adds a transport-injected pure-native Host API:
  official requests, one deadline, exact cancel/stale fences, read-only fallback,
  mutation no-replay/unknown, cancel verification, bounded XML and redacted
  diagnostics, without a NAPI caller, identity, pairing, media, input or UI.
- N1-05 checkpoint `599882ada` adds owner+installation-scoped opaque identity,
  RSA-2048 certificate and move-only signing/TLS leases with cleanse, exact
  lifecycle and a fail-closed HUKS/Asset boundary. Product stays unavailable until
  an in-HAP probe proves direct signing or HUKS-wrapped atomic encrypted storage;
  no plaintext fallback exists.
- N1-06 checkpoint `6f7094038` adds a hidden injected pairing state machine:
  official four-step HTTP plus final pinned HTTPS transcript, SHA-256/default-
  blocked SHA-1, canonical certificate/trust candidate, exact lane/cancel/deadline,
  no replay, one-shot unpair, atomic commit/rollback/repair and full secret cleanse.
  It reuses N1-04/N1-05 and remains unreachable from NAPI/HAP runtime.
- N1-07 checkpoint `019ed98b4` adds a hidden injected Host Control: authenticated
  catalog/asset, launch/resume/explicit quit, preflight/action/postcondition truth,
  exact generation/cancel/deadline, global single mutation, no replay and secret/
  RTSP cleanse. It only reuses N1-04 and remains unreachable from NAPI/HAP runtime.
- N1-08 checkpoint `aecd2ea4e` adds a NAPI-free exact bridge, five independent
  `moonlight*` NAPI properties and lease/cache-fenced `MoonlightHostService`.
  Product runtime remains packet-free `runtime_proof_required`; no UI/cloud/media/
  input truth changed. Sanitizer also exposed and checkpointed the pre-existing
  deferred-owner thread-before-state initialization fix as `aa3b947`.
- Current gates: both Hvigor tasks, 151-test ArkTS registration in 20 describe
  groups, signed HAP, native 440/440 and three consecutive ASan/UBSan 440/440,
  strict/four analyzer passes, API 23 dual-ABI probe/build,
  source/Git-tree, TOTP, Light and isolation passed. ABI inventories remain
  arm64 16103/705/716 and x86_64 15634/703/711; the only undefined additions are
  seven exact NAPI imports, and HAP remains 423 paths. Each ABI has 88 commands,
  keeps 48 `rdpnapi`, and puts bridge/NAPI in a private `--exclude-libs` archive
  with no upstream include leak. HDC still says
  `Connect server failed`; no new Hypium/HUKS/Sunshine runtime claim exists. One of two `sol low` reviews was
  used for N1-01; the remaining one stays reserved for final integration.

## Next

1. Execute only N2-01 as a project-owned deterministic stream-config/offer
   contract. Add pure requested/effective/capability/adjustment value types,
   same-source launch projection and focused native tests; do not include the
   common-c wire struct, expand NAPI, start RTSP, touch renderer/audio/input/UI,
   or change any release truth. `offer_ready` is not `negotiated`.
2. Keep D3-01 online wiring, D3-05 cloud promotion, D3-06 cloud terminal and
   D3-08 multi-device matrix blocked until development/test/production AGC receipts
   permit D2-07 registration.
3. Do not implement D2-07 registration until development/test/production AGC
   schema, authorization and index receipts complete D2-05/D2-06.

## Blockers

- `ohosTest@OhosTestCompileArkTS` remains unregistered (`00306054`), so the 151
  focused Moonlight tests are compile-registered but no on-device Hypium pass is claimed.
- AGC development/test/production `moonlightrecordv1` schema, authorization and
  index receipts are absent; the table is therefore not in `CloudSyncPolicy.TABLES`.
- The configured HDC virtual device is currently unreachable (`Connect server
  failed`); this does not invalidate earlier RDB receipts but blocks new runtime checks.
- HAP/AppSpawn access to HUKS-backed RSA TLS signing, or to HUKS AES-GCM wrapping
  plus an atomic app-private encrypted-blob backend, has not been runtime-proven;
  the N1-05 product identity backend therefore intentionally returns unavailable.
- HAP/AppSpawn runtime probes, two real Sunshine hosts, AGC schema receipts and
  final ARM64 physical-device acceptance remain external release blockers.
