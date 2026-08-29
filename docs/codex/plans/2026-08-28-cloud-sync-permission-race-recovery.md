# Cloud sync permission-race recovery

## Root cause

- Immediately after Account Kit login, API 23 may return permission state 3 / reason 4 without showing a dialog. Treating that as a final denial opens the hashed local-only store; retrying distributed-table registration on that physical store can never bind the canonical cloud store.
- A successful cloud-first data transaction was previously rolled back when auxiliary selection metadata finalization failed, so downloaded rows could appear and then disappear.

## Safety contract

- Only the permission-dialog race is automatically retried; explicit denial remains denied.
- Re-prove the same Account Kit/Auth/platform identity before any hashed-to-canonical rebind.
- Block new remote sessions, prove all existing sessions idle, drain sensitive services, and retain the exact transition lease through rebind.
- Never hide post-migration local mutations: compare the durable journal baseline and hard-stop on change.
- Copy exact-owner VNC and Moonlight local overlays, including tombstones and `localonly`, through strict schema and payload validation.
- Commit authoritative cloud data independently from retryable selection metadata; keep upload barriers closed until metadata finalization succeeds.
- Keep RustDesk Pro Asset Store credentials, unrelated protocol data, and app-clone local-only behavior unchanged.

## Implementation

1. Classify platform permission responses into granted, denied, dialog-blocked, and temporarily unavailable states.
2. Let `AccountSessionCoordinator` own foreground recovery and same-account physical-store rebind.
3. Add journal-v1 migration receipts, recovery baselines, exact local-overlay migration, and source-change refusal.
4. Add a process-local remote-session transition gate across native, registry, and window admission.
5. Split startup data commit from selection finalization and retry the latter idempotently on foreground.
6. Coalesce page recovery, retain successful core-table finalization after optional Moonlight failure, and make startup-finalizer exceptions retryable.

## Verification

- Mandatory ArkTS test compile and signed HAP build.
- Policy/wiring coverage for permission classification, recovery state, receipt/source-change decisions, local-overlay admission, transition leases, optional-table partial success, metadata finalization, and finalizer retry.
- `git diff --check`, Light open-source compliance, and independent P0-P3 review.
- Real-device reinstall/login acceptance remains a separate explicit deployment step.
