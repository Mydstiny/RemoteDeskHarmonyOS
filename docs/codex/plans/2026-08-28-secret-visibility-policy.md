# Secret Visibility Policy Plan

## Goal

Add a device-local Data Security control that lets users choose which editable
password classes are write-only in editors: an existing secret is represented
only by presence, an empty draft preserves it, a non-empty draft replaces it,
and deletion remains an explicit action. Bring the existing VNC behavior under
the same policy without changing connection, encryption, backup or cloud-sync
semantics.

## Invariants

1. A hidden existing secret never enters page/component edit state, preview
   text, accessibility text, logs or clipboard paths.
2. Editing non-secret metadata with an empty hidden draft preserves the exact
   existing secret; only an explicit non-empty replacement or explicit delete
   may mutate it.
3. Application-crypto lock and always-hidden credential classes override the
   local presentation preference.
4. The presentation policy is device-global, persisted only in Preferences,
   excluded from cloud user settings and portable backup.
5. RDP blank-password authentication remains distinct from an empty hidden
   draft, and all protocol validation/connection behavior remains unchanged.
6. VNC host passwords use the shared policy/mutation contract while retaining
   the current separate-secret storage, consent and rollback guarantees.

## Steps

1. Add a strict, versioned secret-presentation policy and explicit
   keep/replace/clear mutation helpers with focused unit tests.
2. Add a Data Security leaf Sheet with per-secret-class toggles, select-all and
   defaults, backed by local Preferences/AppStorage only.
3. Update classic host and RDP credential editing to expose secret presence,
   keep hidden drafts empty, preserve existing secrets on metadata updates and
   overwrite only when the user enters a replacement.
4. Route VNC host password editing through the same presentation policy while
   preserving the existing secret service and connection preflight behavior.
5. Cover preference parsing, local-only classification, edit projection and
   keep/replace behavior; run focused tests, exact Hvigor test compilation,
   signed HAP assembly, diff checks and Light compliance.
6. Commit the implementation, obtain independent sub-agent review, remediate
   every finding and rerun the required gates before PR/main closure.
