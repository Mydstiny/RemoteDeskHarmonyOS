# Pro purchase foundation demo

## Authorized scope
Settings bottom Pro entry, native bindSheet, theme-aware responsive presentation and restrained entrance/press animation. One-time purchase, launch CNY 19.99 / regular CNY 28.88. No existing functionality becomes paid.

## Architecture
- Feature catalog: stable IDs, availability separate from free/Pro entitlement; planned features always unavailable.
- Entitlement service: trusted-verifier boundary, account/environment/generation binding, immutable snapshots and subscriptions; never unlock from raw IAP callbacks or editable preferences.
- Huawei billing adapter: sandbox-only preflight, configured product ID, store price, purchase and paginated current/unfinished queries. No automatic purchase on appearance.
- Coordinator: process-wide single-flight transaction admission across sheet reopen, lifecycle invalidation, safe errors; raw tokens never logged. Verification unavailable keeps result pending, never acknowledges delivery.
- Sheet: scrollable benefits and pinned footer; planned features visibly labeled; purchase call only from footer click; restore action remains non-purchasing.

## External dependencies and rollout
No real product ID or server signing/verification credentials supplied. Demo accepts an explicit sandbox product ID in a disclosed test panel; isSandboxActivated must succeed again immediately before checkout. Production disabled. No local mock grants. Persistent signed offline grants, refund notifications, full restore and production selling require backend integration and separate acceptance.

## Tests and acceptance
Policy tests cover free features, unknown/planned denial, sandbox-production separation, owner mismatch, revocation and expiry. Compile default@OhosTestCompileArkTS and assembleHap; diff check and Light compliance. Independent review before merge. Device acceptance: small screen/PC, light/dark, cancel, double tap, dismiss/reopen during purchase, sandbox account, unfinished orders. Do not claim device or backend acceptance without evidence.

## Adding a future paid feature
1. Add a stable ID to proFeatures(), leaving availability planned until the feature ships. Existing features retain free policy.
2. Mark the delivered feature available only with its actual implementation and acceptance checks. The purchase copy is sourced from this catalog.
3. Implement a trusted ProOrderVerifier against the selected backend; enforce issuer/signature, app, product allowlist, environment, identity, order state and freshness on the trusted side. Never return grants from raw parsed client JSON.
4. Own one ProEntitlementService at the application account lifecycle. bindAccount must run on every verified identity transition. UI components subscribe and unsubscribe; business operations check access(featureId) immediately before execution. Do not bind it to RustDesk Pro server credentials.
5. Add durable, verified offline entitlement caching and refund notification reconciliation before production. validUntil is verification freshness, not expiry of the one-time license. A transient verifier failure must not be treated as a refund.
6. Replace the demo-only checkout/query endpoint with verified fulfillment: validate, persist idempotently, publish entitlement, then finishPurchase. Complete all pages of current and unfinished purchases. Account changes fence completion; retries must not double-grant.
7. Enable a production SKU only after real benefits, legal/product descriptions, server verification and restore/refund acceptance are complete. No production toggle exists in this demo.

## Current validation boundary
The local entitlement service is an integration seam and is deliberately not connected to a fake verifier. No confirmed backend, production SKU or real device is available. The demo does not acknowledge delivery, restore paid access or persist raw purchase records. Sandbox checkout and query APIs are real calls, requiring user-provided AGC configuration.
