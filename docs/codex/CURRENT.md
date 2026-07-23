# Shared Current State

Updated: 2026-07-23 Asia/Shanghai

## Repository

- Repository: `Mydstiny/RemoteDeskHarmonyOS`
- Public branch: `main`
- Public main commit at last sync: `a3f1ad3d8` (`fix: stabilize remote sessions and 1.0.8 runtime`)
- Canonical development model: one local workspace, one active `codex/<task>` branch, protected PR merge.

## Current phase

- Cross-device collaboration bootstrap is active on `codex/cross-device-workflow` so Windows and macOS can share source, sanitized task state and the same start-of-task synchronization gate.
- The 1.0.8 runtime, cloud-sync protection, onboarding and PIP/RDP lifecycle changes are in public history; device acceptance remains a separate validation item.

## Completed verification recorded in public history

- Native and RustDesk FFI test suites passed for the published runtime checkpoints.
- `default@OhosTestCompileArkTS`, production HAP build, `git diff --check` and Light open-source compliance passed for the published runtime checkpoints.

## Next

- Land and verify the cross-device workflow files.
- On an unlocked HarmonyOS target, complete the remaining PIP, live-view, cloud-sync and first-install acceptance matrix.
- Keep all raw device evidence and private build inputs local-only.

## Local-only state

SDKs, signing profiles, AGConnect configuration, local properties, build caches, logs, screenshots, device databases and Codex's private machine memory are intentionally not represented here.
