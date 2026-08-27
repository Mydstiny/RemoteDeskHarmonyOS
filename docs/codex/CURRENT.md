# Shared Current State

## Active task

- Task: `rustdesk-orientation-diagnostics`
- Branch/base: `codex/rustdesk-orientation-diagnostics` from merged `main@5bac9ffc2`
- Phase: independent review; implementation checkpoints are `469327ed3` and `b68e1128a`.
- Plan: `docs/codex/plans/2026-08-27-rustdesk-orientation-and-diagnostics.md`

## Confirmed diagnosis

- RustDesk currently selects a producer-supplied native-image transform only when the peer platform string contains Windows, while macOS/Linux use identity presentation.
- Historical project evidence shows RustDesk desktop frames are already upright in the app's canonical top-left texture space. Applying the producer matrix can rotate an upright Windows desktop by 180 degrees; the later Windows-only switch reintroduced that risk.
- The two supplied `RemoteDesktop-log-20260827-*.jsonl` files show successful request/state/disconnect events but contain neither build identity nor peer platform, decoder backend, presentation mode, surface role or transform classification. They therefore cannot distinguish an old package from the intended fix or explain a rendering mismatch.

## Implemented

- RustDesk now keeps Windows, macOS, Linux and unknown peers on one canonical identity presentation. Producer transforms are sampled and classified only as telemetry.
- Diagnostic JSONL schema v2 records the numeric app version, exact native build ID and fixed validated runtime facts for RDP, RustDesk, VNC, Moonlight and SSH/SFTP. High-frequency counters are sampled at most every five seconds unless semantic state changes.
- Build identity generation now runs at native build time, so an incremental Hvigor cache cannot stamp a newly signed HAP with the preceding commit SHA.

## Verification

- Native host suite: `808/808` PASS outside the sandbox; the sandbox-only VNC loopback bind failures were rerun successfully with network permission.
- Exact `default@OhosTestCompileArkTS`: PASS on `b68e1128a`.
- Exact signed `assembleHap`: PASS on `b68e1128a`; arm64 native binary contains `b68e1128a059` after an incremental, no-clean HEAD change.
- `git diff --check` and open-source Light compliance: PASS.
- Current signed HAP SHA-256 before review-only documentation closeout: `aec61f27f9550ac4a8c4434518155d6268dd5056eb8eb4d6b91335ce937b2c91`.

## Completed prerequisite

- VNC host-FAB adaptive layout passed independent review and both exact Hvigor gates, was pushed as PR #45, passed `open-source-compliance` and merged into `main@5bac9ffc2`.
- 474 untracked duplicate files were moved without deletion to `/Users/mydestiny/Desktop/RemoteDesktop/untracked-duplicate-backup-20260827-1730`; the repository is clean.

## Blockers and acceptance boundary

- Real Windows and macOS RustDesk visual acceptance requires installing the final signed HAP after merge. No runtime PASS is claimed yet.
- Existing 1.1.2 logs cannot prove installed source revision because their manifest only contains the marketing version.
- Device Hypium remains unavailable because task `00306054` is unregistered; compile coverage is required but will not be reported as a device-test PASS.
