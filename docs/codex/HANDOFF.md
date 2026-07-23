# Current Handoff

Updated: 2026-07-23 Asia/Shanghai

## Source

- Base: `main` at `c502221e3` restored from the migration bundle
- Active task branch: `codex/mac-migration-bootstrap` at `aca6c1e`
- Last published runtime checkpoint: 1.0.8 stabilization

## Completed

- Public source and submodule history are available from GitHub.
- The shared state files, cross-platform sync entry points and migration package generator are merged on `main`.
- This Mac workspace restored the root history from `RemoteDeskHarmonyOS-main.bundle` and freerdp history/source at `dae8276ac` from the migration package.
- Git hooks are configured through `.githooks`; the sync script and pre-push hook retain executable mode in the active task commit.
- Mac build helpers now auto-discover the DevEco SDK and native tools; `source scripts/macos_env.sh` also exposes rustup cargo/rustc and the ignored local `pwsh` fallback.

## Verification

- Runtime checkpoint gates are recorded in the relevant `docs/test-results/` files and public PR history.
- `sync_workspace.sh status` and `doctor` passed on the restored main checkout.
- Mac workflow policy, pre-push history, FreeRDP provenance and Light compliance tests pass.
- GitHub fetch/push/PR checks are pending because this environment cannot establish a connection to `github.com`.
- The detected SDK is API 24 rather than the project's API 23 baseline; stable system PowerShell and OHOS cross targets remain local setup items.

## Next owner action

1. On a networked Mac, push `codex/mac-migration-bootstrap`, create its PR, and wait for `open-source-compliance`.
2. Merge with a merge commit, then fast-forward local `main` and remove the merged branch.
3. Install/configure API 23 and OHOS cross-build SDK inputs plus private files through secure channels; do not copy Windows Codex memory.
4. Run the platform-specific `sync` and `start` commands in `docs/CROSS_DEVICE_GITHUB_WORKFLOW.md`.
5. Update this handoff with the resulting merge commit, verification and remaining device blockers.
