# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` on `codex/rustdesk-complete-repair`.
- Checkpoint: current `HEAD`; base `main@34946adbc`; branch is ahead by 91
  and not behind.
- Phase: RustDesk continuity/video-pipeline repair plus existing mobile rail and
  VNC lifecycle work. Unrelated TOTP, CloudStore, and PIP edits remain in the
  worktree and must be preserved.

## Progress

- VNC Stages A-F cover endpoint-bound trust, bounded probe/deep-check lifecycle,
  fail-closed Gateway handling, and native loopback policy tests. Details and
  review receipts remain in `STATE.json` and `docs/codex/archive/`.
- RustDesk checkpoints `fa886f37d`, `763dc35d1`, `28f8608f6`, `d29e754db`,
  and `6a4b35d1f` cover first-frame recovery, transport continuity, PIP,
  TOTP surfaces, and the mobile control rail.
- Current repair: continuity reconnect preserves the live owner, rebinds a
  surviving decoder to the current renderer, and requests a frame refresh;
  destroyed renderers are not resurrected. No startup/authentication flow was
  changed.
- Reuse reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d`; do not expand
  scope into FreeRDP while VNC V3 remains open.

## Verification

- `rdp_native_tests`: 236 passed, 16 VNC TLS fixture-start failures in the
  local host environment; RustDesk continuity/decoder tests passed.
- `default@OhosTestCompileArkTS`: passed on 2026-08-03 after the type-only PIP
  surface import fix; warnings only.
- `assembleHap`: passed on 2026-08-03 (`BUILD SUCCESSFUL`).
- Native x86_64 and arm64-v8a builds passed before this checkpoint.
- `git diff --check`: passed.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered
  (`00306054`).

## Blockers

- Persistent hdc rule: initialize and access hdc only outside the sandbox, use
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`,
  and run `list targets`, `shell`, `hilog`, and `hidumper` through the approved
  elevated path. Do not retry hdc inside the sandbox or ask for approval again.
- Device `5KLBB25928203528` is reachable; recent RustDesk logs were captured
  for app PID `32755`. Real-device repair validation remains pending.
- NAPI teardown, Sheet/TrustService integration, real endpoints, CloudStore,
  device matrices, and RustDesk/VNC background/PIP runtime evidence remain
  unverified.

## Review Protocol

- Machine state: `docs/codex/STATE.json`; receipts:
  `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` records RESUME_REVIEW for the existing
  task owner; do not dispatch a duplicate audit.
