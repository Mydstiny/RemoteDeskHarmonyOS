# Shared Current State

## Active task

- Task: `cloud-sync-permission-race-recovery`
- Branch: `codex/system-clipboard-activation-fix`; user authorized work on the current branch.
- Increment: `7ad612f55..7be69ad42`.
- Phase: implemented, locally verified and independently reviewed; reinstall/login device acceptance pending.
- Plan: `docs/codex/plans/2026-08-28-cloud-sync-permission-race-recovery.md`

## Root cause and fix

- API 23 returned permission state 3 / reason 4 without showing a dialog immediately after login. The app treated it as final denial, opened a hashed local-only store, then retried distributed-table registration on the wrong physical store.
- Foreground recovery now re-proves the same Huawei identity and performs a coordinator-owned hashed-to-canonical rebind; explicit denial remains denied and repeated no-dialog responses hard-stop.
- Journal-v1 baseline/receipts reject changed migration sources. Exact-owner VNC and Moonlight local overlays, tombstones and `localonly` are copied through strict schema/payload validation.
- A remote-session transition lease blocks new native/window sessions across the destructive rebind and preserves activity evidence when disconnect submission fails.
- Authoritative cloud-first data no longer rolls back for auxiliary selection-metadata failure. Barriers remain fail-closed and retry idempotently; optional Moonlight failure still finalizes committed core tables.
- Page/Ability recovery is single-flight, and a throwing startup finalizer clears its exact promise, rolls back safely when possible, and can retry.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 20 s 47 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 27 s 641 ms`).
- Policy/wiring coverage compiles for permission classification, recovery state, receipt/source-change checks, VNC/Moonlight local overlay admission, remote transition leases, partial optional-table success, metadata finalization and finalizer retry.
- `git diff --check`: PASS.
- Light open-source compliance: PASS.
- Independent review `/root/cloud_sync_fix_review`: PASS; no remaining P0/P1/P2. P3 is limited to deeper real-RDB/window/NAPI integration coverage and does not block delivery.

## Next / blockers

1. On an explicitly authorized test device, reproduce uninstall/reinstall → login → permission no-dialog/grant flows and verify all selected cloud tables recover without data disappearing.
2. Exercise a VNC/Moonlight local edit before permission recovery and confirm it remains visible after canonical rebind.
3. No HAP installation or destructive reinstall was performed in this session; real-device acceptance is not claimed.
