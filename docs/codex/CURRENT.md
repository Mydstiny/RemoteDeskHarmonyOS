# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` on `codex/rustdesk-complete-repair`.
- Checkpoint: `410a6a0`; base `main@34946adbc`; branch is ahead by 96
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
- Reuse reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d`; do not expand
  scope into FreeRDP while VNC V3 remains open.

## Verification

- `rdp_native_tests`: 236 passed, 16 VNC TLS fixture-start failures in the
  local host environment; RustDesk continuity/decoder tests passed.
- `default@OhosTestCompileArkTS`: passed on 2026-08-03 after `410a6a0`; warnings
  only.
- `assembleHap`: passed on 2026-08-03 after `410a6a0` (`BUILD SUCCESSFUL`).
- `build_rustdesk_ffi_ohos.sh all`: passed on 2026-08-03; arm64 and x86_64
  archives plus required exports verified.
- `git diff --check`: passed.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`).

## Blockers

- No HDC device is currently listed by
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`;
  real-device PIP/background/foreground evidence remains pending.
- NAPI teardown, Sheet/TrustService integration, real endpoints, CloudStore,
  device matrices, and RustDesk/VNC background/PIP runtime evidence remain
  unverified.

## Review Protocol

- Machine state: `docs/codex/STATE.json`; receipts:
  `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` records RESUME_REVIEW for the existing
  task owner; do not dispatch a duplicate audit.
