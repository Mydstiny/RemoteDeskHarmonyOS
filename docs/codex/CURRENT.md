# Shared Current State

## Active task

- Task: `rustdesk-orientation-diagnostics`
- Branch/base: `codex/rustdesk-orientation-diagnostics` from merged `main@5bac9ffc2`
- Phase: implementation; worktree was clean at task start.
- Plan: `docs/codex/plans/2026-08-27-rustdesk-orientation-and-diagnostics.md`

## Confirmed diagnosis

- RustDesk currently selects a producer-supplied native-image transform only when the peer platform string contains Windows, while macOS/Linux use identity presentation.
- Historical project evidence shows RustDesk desktop frames are already upright in the app's canonical top-left texture space. Applying the producer matrix can rotate an upright Windows desktop by 180 degrees; the later Windows-only switch reintroduced that risk.
- The two supplied `RemoteDesktop-log-20260827-*.jsonl` files show successful request/state/disconnect events but contain neither build identity nor peer platform, decoder backend, presentation mode, surface role or transform classification. They therefore cannot distinguish an old package from the intended fix or explain a rendering mismatch.

## Implementation target

- Remove peer-OS-dependent RustDesk presentation and keep every RustDesk peer on one canonical identity path. Producer transform metadata remains observable for diagnostics, not authoritative for remote desktop orientation.
- Upgrade diagnostic exports so a support log identifies the exact diagnostic build and records bounded, privacy-safe runtime facts for RDP, RustDesk, VNC, Moonlight and SSH/SFTP.
- Add focused native/ArkTS coverage, then run native tests, exact ArkTS test compile, signed HAP assembly, diff check and Light compliance before independent review.

## Completed prerequisite

- VNC host-FAB adaptive layout passed independent review and both exact Hvigor gates, was pushed as PR #45, passed `open-source-compliance` and merged into `main@5bac9ffc2`.
- 474 untracked duplicate files were moved without deletion to `/Users/mydestiny/Desktop/RemoteDesktop/untracked-duplicate-backup-20260827-1730`; the repository is clean.

## Blockers and acceptance boundary

- Real Windows and macOS RustDesk visual acceptance requires installing the new signed HAP after implementation. No runtime PASS is claimed yet.
- Existing 1.1.2 logs cannot prove installed source revision because their manifest only contains the marketing version.
- Device Hypium remains unavailable because task `00306054` is unregistered; compile coverage is required but will not be reported as a device-test PASS.
