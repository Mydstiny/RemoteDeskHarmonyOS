# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` plus the user-authorized RDP P0 quick fix on
  `codex/rustdesk-complete-repair`.
- Checkpoint: `d48c12471`; base `main@34946adbc`; branch is ahead by 103
  and not behind.
- Phase: RustDesk 1.0.8 PIP continuity repair plus existing mobile rail and VNC
  lifecycle work. Unrelated TOTP, CloudStore, and compliance edits remain in
  the worktree and must be preserved.

## Progress

- VNC Stages A-F cover endpoint-bound trust, bounded probe/deep-check lifecycle,
  fail-closed Gateway handling, and native loopback policy tests. Details and
  review receipts remain in `STATE.json` and `docs/codex/archive/`.
- RustDesk checkpoints `fa886f37d`, `763dc35d1`, `28f8608f6`, `d29e754db`,
  and `6a4b35d1f` cover first-frame recovery, transport continuity, PIP,
  TOTP surfaces, and the mobile control rail.
- Current repair `410a6a0`: prepares the VIDEO_PLAY controller in the visible
  foreground, arms system auto-start, waits for a real PIP SurfaceId/SurfaceRect,
  transfers the renderer only after a presented frame, and fences PIP teardown
  before foreground renderer rebind and first-frame refresh. RustDesk protocol
  sessions remain connected during Home/background transitions.
- RDP P0 `d48c12471`: reads complete TPKT negotiation PDUs, classifies selected
  security before TLS, reports Standard RDP/RDP_NEG_FAILURE/unsupported PDU
  distinctly, and adds stable TLS diagnostics. RustDesk/VNC production logic
  was not changed by this checkpoint.
- Reuse reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d` for its existing
  VNC/RustDesk scope. RDP P0 has a separate read-only review; defer RDP
  P1/P2/P3 until endpoint evidence is available.

## Verification

- `rdp_native_tests`: 242 passed, 16 pre-existing VNC TLS fixture-start failures
  in the local host environment; all six new RDP parser tests passed.
- `default@OhosTestCompileArkTS`: passed on 2026-08-03 after `d48c12471`; warnings
  only.
- `assembleHap`: passed on 2026-08-03 after `d48c12471` (`BUILD SUCCESSFUL`).
- `build_rustdesk_ffi_ohos.sh all`: passed on 2026-08-03; arm64 and x86_64
  archives plus required exports verified.
- `git diff --check`: passed after `d48c12471`.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`).

## Blockers

- No HDC device is currently listed by
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`;
  real-device PIP/background/foreground evidence remains pending.
- NAPI teardown, Sheet/TrustService integration, real endpoints, CloudStore,
  device matrices, and RustDesk/VNC background/PIP runtime evidence remain
  unverified.
- RDP endpoint type, selected protocol, TLS error stack, and FreeRDP runtime
  behavior remain unverified without a bastion endpoint and HDC.

## Review Protocol

- Machine state: `docs/codex/STATE.json`; receipts:
  `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` records RESUME_REVIEW for the existing
  task owner; do not dispatch a duplicate audit.
