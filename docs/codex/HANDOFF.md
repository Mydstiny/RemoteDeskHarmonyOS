# Current Handoff

Updated: 2026-07-23 Asia/Shanghai

## Source

- Base: `main` at `c502221e3` restored from the migration bundle
- Active task branch: `codex/mac-migration-bootstrap` at `2a05f2d`
- Last published runtime checkpoint: 1.0.8 stabilization

## Completed

- Public source and submodule history are available from GitHub.
- The shared state files, cross-platform sync entry points and migration package generator are merged on `main`.
- This Mac workspace restored the root history from `RemoteDeskHarmonyOS-main.bundle` and freerdp history/source at `dae8276ac` from the migration package.
- Git hooks are configured through `.githooks`; the sync script and pre-push hook retain executable mode in the active task commit.

## Verification

- Runtime checkpoint gates are recorded in the relevant `docs/test-results/` files and public PR history.
- `sync_workspace.sh status` and `doctor` passed on the restored main checkout.
- GitHub fetch/push/PR checks are pending because this environment cannot establish a connection to `github.com`.
- PowerShell 7 is not installed/on PATH; Rustup is present but `cargo` and `rustc` are not exposed on PATH.

## Next owner action

1. On a networked Mac, push `codex/mac-migration-bootstrap`, create its PR, and wait for `open-source-compliance`.
2. Merge with a merge commit, then fast-forward local `main` and remove the merged branch.
3. Install/configure local SDKs and private files through secure channels; do not copy Windows Codex memory.
4. Run the platform-specific `sync` and `start` commands in `docs/CROSS_DEVICE_GITHUB_WORKFLOW.md`.
5. Update this handoff with the resulting merge commit, verification and remaining device blockers.
