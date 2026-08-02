# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` (active branch retained; current scope is VNC V3 only)
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `73334a260`, based on `main@34946adbc`; branch is ahead by 10 and not behind.
- Phase: VNC V3 stage A reviewed and passed; stage B is next.
- Worktree: clean. Do not stage unrelated changes.

## Stage A Result

- Frozen VNC endpoint/trust owner, certificate preflight, probe lifecycle,
  host defaults, shared-wheel authority, and one-shot pin policies.
- Stage A review: `PASS` at `73334a260` by independent review session
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Review scope is limited to the 12 VNC policy/test files declared in
  `STATE.json`; no RDP, RustDesk, SSH, renderer, or video-performance files.

## Next

- Stage B: native structured VNC TLS certificate probe with bounded metadata,
  cancellation/timeout, IPv4/IPv6/SNI, stable error codes, and pin checks.
- Keep all VNC callers fail-closed until the probe and expected-pin handoff are
  wired through the later Sheet/state-machine stages.

## Verification

- `default@OhosTestCompileArkTS`: passed after `73334a260` on 2026-08-02.
- `assembleHap`: passed after `73334a260` on 2026-08-02.
- `git diff --check`: passed.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`). New ArkTS tests therefore have compile/build evidence only.

## Blockers

- `hdc list targets`/`hdc shell` still return `Connect server failed`; no
  current hilog or real-device/endpoint evidence is available.
- Stage A is policy/test scaffolding; native probe, Sheet lifecycle,
  TrustService migration, real Repeater, cloud, and device matrices remain
  unverified and are not release evidence.

## Review Protocol

- Machine state: `docs/codex/STATE.json`.
- Receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` must report `SKIP_FULL_REVIEW` for the
  unchanged stage A scope; later stages declare their own VNC-only scope.
- Independent review session and monitor session are already active; do not
  redispatch duplicate messages for the same stage.
