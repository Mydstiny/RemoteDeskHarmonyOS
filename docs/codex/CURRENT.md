# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` (active branch retained; current scope is VNC V3 only)
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `590a5639c`, based on `main@34946adbc`; branch is ahead by 48 and not behind.
- Phase: VNC V3 stage E settings consistency; modern VNC add flow applies default transport/Gateway and deletion/disable clears default references, awaiting review.
- Worktree: clean after the code checkpoint. Do not stage unrelated changes.

## Stage A Result

- Frozen VNC endpoint/trust owner, certificate preflight, probe lifecycle,
  host defaults, shared-wheel authority, and one-shot pin policies.
- Stage A review: `PASS` at `73334a260` by independent review session
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Review scope is limited to the 12 VNC policy/test files declared in
  `STATE.json`; no RDP, RustDesk, SSH, renderer, or video-performance files.

## Stage B Result

- Review: `PASS` at code checkpoint `3167f610a` by independent task
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Verified async DNS, unified DNS/TCP/TLS deadline, TLS cancellation/error
  codes, bounded certificate metadata, worker-only teardown, N-API cleanup
  fencing, resolver exception boundaries, and trickle-handshake regression.
- Remaining evidence gaps are OHOS NAPI runtime teardown, `ohosTest`, `hdc`,
  real direct/Repeater endpoints, and later Sheet/TrustService integration.

## Next

- Stage C first segment: pure certificate Sheet action/lifecycle policy and
  registered Hypium suites are implemented and independently PASS at
  `36a8cbe57` (receipt `vnc-v3-stage-c-sheet-policy-pass-36a8cbe5`).
- Stage C second segment: `RemoteDesktop` now wires the resolver, async probe,
  three generations, five-state certificate Sheet, password ordering, owner/
  endpoint-bound trust, and one-shot pin handoff. The prior review findings for
  Gateway trust persistence, Sheet close/routing, account generation binding,
  sensitive cleanup, and legacy trust writes are fixed at checkpoint
  `0d12ca1aa`. The follow-up endpoint hardening at `0e662e94a` binds TLS mode
  into the endpoint fingerprint, rejects trust rows from another physical
  store, and registers the resolver suite in both test runners. The latest
  `7d26f3716` checkpoint downgrades stale-store list views and makes legacy
  trust queries endpoint-bound, with Repeater TLS binding coverage.
- The existing reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d` passed the
  `fc9daa13f` manager endpoint/migration segment; reuse it for the next VNC-only
  segment and do not duplicate
  the task or start FreeRDP evaluation before VNC V3 closes.
- Stage D checkpoint `fc9daa13f` passed independent review with endpoint-bound manager lookup/status,
  multi-target recheck routing, v1 candidate migration cleanup/read-back and
  before-image rollback on failed writes. The next segment covers backup/cloud
  wording and endpoint deletion/rotation invalidation; the code remains VNC-only.
- Stage D follow-up checkpoint `8f45bbf37` invalidates device-local VNC confirmation
  markers after committed host/Gateway endpoint changes or deletion, keeps old
  trust rows as unconfirmed candidates, and makes backup/cloud manifests explicit
  that VNC candidates may be carried only in full mode while local markers never
  cross the device boundary. New policy tests are registered in both suites.
- Checkpoint `bb2352fcc` closes the follow-up review findings: Preferences marker
  writes now return explicit outcomes, invalidation uses a journal/marker/journal-
  clear commit contract, stale journals fail closed on restart, store-bound marker
  removal is explicit, and full-backup restore tests keep local markers device-local.
- Checkpoint `1a21488a7` preserves the recovery sentinel until marker clearing is
  confirmed, and adds adapter-backed marker-write, journal-remove, retry, and
  restart fail-closed tests.
- Checkpoint `f16b673e2` continues marker clearing when the recovery journal's
  first write fails, then derives health from the durable marker/journal end
  state and tests clean restart recovery.
- Checkpoint `590a5639c` applies the shared default resolver to modern VNC
  creation and clears default Gateway references when a Gateway is removed or
  disabled; invalid references still fail closed to direct TCP.
- Keep every VNC caller fail-closed when the probe, Sheet lifecycle, owner
  binding, or expected-pin handoff is missing or stale.

## Verification

- `rdp_native_tests`: 249 passed, 0 failed with host socket permission on
  `590a5639c`, 2026-08-03.
- `default@OhosTestCompileArkTS`: passed after `590a5639c` on 2026-08-03.
- `assembleHap`: passed after `590a5639c` on 2026-08-03.
- `git diff --check`: passed after `590a5639c` on 2026-08-03.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`). New ArkTS tests therefore have compile/build evidence only.

## Blockers

- `hdc list targets`/`hdc shell` still return `Connect server failed`; no
  current hilog or real-device/endpoint evidence is available.
- Stage B native probe is covered by host fixtures for self-signed, trusted
  root, name mismatch, expiry, rotation, no certificate, TLS 1.0/1.1 rejection,
  IPv4/IPv6/SNI, timeout/cancel, DNS bound, pin match/mismatch, no RFB
  handoff, and the final transport deadline. NAPI runtime, Promise/environment teardown, Sheet lifecycle,
  TrustService migration, real Repeater, cloud, and device matrices remain
  unverified and are not release evidence.
- Stage C RemoteDesktop probe/Sheet/password integration is static/build-tested
  only until `ohosTest` is registered and a real device is available; no UI or
  endpoint runtime evidence is claimed. Stage D trust migration, manager,
  invalidation and backup policy have host/build coverage but no live
  CloudStore/device evidence; stage E still lacks live
  `ohosTest`/device/Preferences restart evidence.

## Review Protocol

- Machine state: `docs/codex/STATE.json`.
- Receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` should report RESUME_REVIEW for the
  `590a5639c` Stage E increment until the existing reviewer returns a receipt.
- Reuse the existing independent review session and do not redispatch duplicate
  messages for the same segment.
