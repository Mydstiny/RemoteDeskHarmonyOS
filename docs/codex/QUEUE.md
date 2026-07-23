# Shared Queue

Updated: 2026-07-23 Asia/Shanghai

## Now

- No active migration task. The Mac `hdc` PATH fix and sanitized Windows
  development handoff are merged through the normal PR flow; the next device
  starts from synchronized `main`.

## Next

- On Windows, install/confirm PowerShell 7 as `pwsh`, then run the shared-state,
  submodule and history gates from a clean clone.
- Configure private signing and optional AGConnect files only on the machine that
  needs signed or cloud-enabled builds.
- Complete real-device acceptance for RDP, RustDesk, SSH/SFTP, VNC, PIP/live-view
  and cloud-sync checkpoints.

## Later

- Extend remote file-transfer coverage and complete the deferred release matrix.

## Queue rules

- Only one task may be active in `Now` on the shared branch state.
- A new device must sync and read this queue before creating a branch.
- Finished items are removed or summarized in `CURRENT.md`; do not append an
  unbounded session transcript.
