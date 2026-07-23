# Shared Queue

Updated: 2026-07-23 Asia/Shanghai

## Now

- Finish `codex/mac-final-verification`: API 23 checks and Light compliance are
  complete; commit the scoped shared-state update, push the branch and create its
  PR.
- Wait for `open-source-compliance`; merge with a merge commit, then synchronize
  local `main` and remove the merged task branch.

## Next

- On a networked Mac, verify fetch, push and PR operations against GitHub.
- On a clean Windows clone, run the same shared-state, submodule and history gates.
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
