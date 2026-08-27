# Shared Current State

## Active task

- Task: `rustdesk-orientation-diagnostics`
- Branch/base: `codex/rustdesk-orientation-diagnostics` from merged `main@5bac9ffc2`
- Phase: delivery after independent PASS; implementation checkpoints are `469327ed3`, `b68e1128a` and `26a874786`.
- Plan: `docs/codex/plans/2026-08-27-rustdesk-orientation-and-diagnostics.md`

## Confirmed diagnosis

- RustDesk currently selects a producer-supplied native-image transform only when the peer platform string contains Windows, while macOS/Linux use identity presentation.
- Historical project evidence shows RustDesk desktop frames are already upright in the app's canonical top-left texture space. Applying the producer matrix can rotate an upright Windows desktop by 180 degrees; the later Windows-only switch reintroduced that risk.
- The two supplied `RemoteDesktop-log-20260827-*.jsonl` files show successful request/state/disconnect events but contain neither build identity nor peer platform, decoder backend, presentation mode, surface role or transform classification. They therefore cannot distinguish an old package from the intended fix or explain a rendering mismatch.

## Implemented

- RustDesk now keeps Windows, macOS, Linux and unknown peers on one canonical identity presentation. Producer transforms are sampled and classified only as telemetry.
- Diagnostic JSONL schema v2 records the numeric app version, exact native build ID and fixed validated runtime facts for RDP, RustDesk, VNC, Moonlight and SSH/SFTP. Tracked live sessions now drive capture-aware sampling every five seconds even when the HUD is closed; semantic state changes still record immediately.
- Diagnostic sampling ownership is cleared on session transfer, bulk disconnect and Moonlight terminal/reconnect paths, so stale sessions cannot retain timers or suppress later observations.
- Build identity generation now runs at native build time, so an incremental Hvigor cache cannot stamp a newly signed HAP with the preceding commit SHA.

## Verification

- Native host suite: `808/808` PASS outside the sandbox; the sandbox-only VNC loopback bind failures were rerun successfully with network permission.
- Exact `default@OhosTestCompileArkTS`: PASS on `26a874786`.
- Exact signed `assembleHap`: PASS on `26a874786`; arm64 native binary contains `26a874786b90` after an incremental, no-clean HEAD change.
- Diagnostic scheduler test compiles with the test target; `scripts/tests/test_build_identity.sh`, `git diff --check` and open-source Light compliance: PASS.
- Current signed HAP SHA-256 before review-only documentation closeout: `91dc9616474cadee7cb31f070c33e364cc94bef4ef8e81efec127d6c383aaaa5`.

## Independent review

- The first review reported no P0/P1, one P2 (the five-second gate lacked a HUD-independent driver) and two P3 items (incomplete observation cleanup and missing integration/build-identity regression coverage).
- `26a874786` adds the continuous capture-aware driver, completes cleanup, adds scheduler coverage and adds a no-clean build-identity regression test.
- The same reviewer rechecked `main..b01f2d6e8` and returned PASS with P0/P1/P2/P3 all zero; receipt `rustdesk-orientation-diagnostics-b01f2d6e-2026-08-27` authorizes delivery.

## Completed prerequisite

- VNC host-FAB adaptive layout passed independent review and both exact Hvigor gates, was pushed as PR #45, passed `open-source-compliance` and merged into `main@5bac9ffc2`.
- 474 untracked duplicate files were moved without deletion to `/Users/mydestiny/Desktop/RemoteDesktop/untracked-duplicate-backup-20260827-1730`; the repository is clean.

## Blockers and acceptance boundary

- Real Windows and macOS RustDesk visual acceptance requires installing the final signed HAP after merge. No runtime PASS is claimed yet.
- Existing 1.1.2 logs cannot prove installed source revision because their manifest only contains the marketing version.
- Device Hypium remains unavailable because task `00306054` is unregistered; compile coverage is required but will not be reported as a device-test PASS.
