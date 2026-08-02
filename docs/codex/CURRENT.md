# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` (active branch retained; current scope is VNC V3 only)
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `0d12ca1aa`, based on `main@34946adbc`; branch is ahead by 27 and not behind.
- Phase: VNC V3 stage C second segment fixes checkpointed; awaiting the existing independent incremental review.
- Worktree: clean. Do not stage unrelated changes.

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
  `0d12ca1aa`.
- The existing reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d` receives one
  unique read-only incremental review request for `0d12ca1aa`; do not dispatch
  another message for this segment.
- Keep every VNC caller fail-closed when the probe, Sheet lifecycle, owner
  binding, or expected-pin handoff is missing or stale.

## Verification

- `rdp_native_tests`: 249 passed, 0 failed with host socket permission on
  2026-08-02. The sandbox-only run reached 235/249 because 14 loopback TLS
  fixtures could not bind; it is not used as final evidence.
- `default@OhosTestCompileArkTS`: passed after `0d12ca1aa` on 2026-08-02.
- `assembleHap`: passed after `0d12ca1aa` on 2026-08-02.
- `git diff --check`: passed after `0d12ca1aa` on 2026-08-02.
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
  endpoint runtime evidence is claimed. Gateway trust persistence has host
  policy/build coverage but no live CloudStore/device evidence.

## Review Protocol

- Machine state: `docs/codex/STATE.json`.
- Receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` should report `RESUME_REVIEW` for
  checkpoint `0d12ca1aa` until the existing reviewer returns PASS or
  CHANGES_REQUIRED.
- Reuse the existing independent review session and do not redispatch duplicate
  messages for the same segment.
