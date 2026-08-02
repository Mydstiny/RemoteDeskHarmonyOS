# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` (active branch retained; current scope is VNC V3 only)
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `74e52759c`, based on `main@34946adbc`; branch is ahead by 13 and not behind.
- Phase: VNC V3 stage B implementation checkpoint; independent review required.
- Worktree: clean. Do not stage unrelated changes.

## Stage A Result

- Frozen VNC endpoint/trust owner, certificate preflight, probe lifecycle,
  host defaults, shared-wheel authority, and one-shot pin policies.
- Stage A review: `PASS` at `73334a260` by independent review session
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Review scope is limited to the 12 VNC policy/test files declared in
  `STATE.json`; no RDP, RustDesk, SSH, renderer, or video-performance files.

## Next

- Request one read-only review of stage B checkpoint `74e52759c` using the
  existing reviewer task; do not redispatch duplicate review messages.
- Stage C follows only after stage B review passes: VNC certificate Sheet and
  connection state machine.
- Keep all VNC callers fail-closed until the probe and expected-pin handoff are
  wired through the later Sheet/state-machine stages.

## Verification

- `rdp_native_tests`: 244 passed, 0 failed; loopback TLS fixture run required
  host socket permission on 2026-08-02.
- `default@OhosTestCompileArkTS`: passed after `74e52759c` on 2026-08-02.
- `assembleHap`: passed after `74e52759c` on 2026-08-02.
- `git diff --check`: passed before checkpoint commit.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`). New ArkTS tests therefore have compile/build evidence only.

## Blockers

- `hdc list targets`/`hdc shell` still return `Connect server failed`; no
  current hilog or real-device/endpoint evidence is available.
- Stage B native probe is covered by host fixtures for self-signed, trusted
  root, name mismatch, expiry, rotation, no certificate, IPv4/IPv6/SNI,
  timeout/cancel, DNS bound, pin match/mismatch, and no RFB handoff. NAPI
  runtime, Sheet lifecycle, TrustService migration, real Repeater, cloud, and
  device matrices remain unverified and are not release evidence.

## Review Protocol

- Machine state: `docs/codex/STATE.json`.
- Receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` must report `REVIEW_REQUIRED` for the
  stage B scope until the existing reviewer records a PASS receipt.
- Independent review session and monitor session are already active; do not
  redispatch duplicate messages for the same stage.
