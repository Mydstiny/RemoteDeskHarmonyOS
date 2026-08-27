# Shared Current State

## Active task

- Task: `rustdesk-orientation-resize-remediation`
- Branch/base: `codex/rustdesk-orientation-diagnostics-closeout` from synchronized `main@3b9e2b59c` (PR #46 merge).
- Phase: implementation checkpoint `0c69433e2` verified locally; simulator online acceptance and independent re-review remain.
- Plan: `docs/codex/plans/2026-08-27-rustdesk-orientation-and-diagnostics.md`

## Confirmed diagnosis

- A fresh Windows RustDesk session on the PC simulator used H.264 hardware decoding and reported `NativeImage producer transform class=flip_y`, but the merged build forced identity presentation.
- The observed image was vertically inverted, not a true 180-degree rotation: the taskbar moved to the top and text was upside down while left/right placement and mouse mapping stayed correct.
- The macOS control session used VP9 software/raw rendering and was unaffected by the NativeImage-only mismatch.
- Window resizing emitted several intermediate surface sizes. On a quiet desktop, the old renderer could display the window-manager-stretched prior swap for four to five seconds because viewport changes did not request a retained-frame redraw.

## Implemented remediation

- RustDesk now uses the local producer matrix on every peer OS only when it classifies as identity, flip-X, flip-Y or rotate-180; malformed/read-failed matrices retain the last valid transform. Peer OS remains telemetry only.
- Surface geometry is published to input mapping immediately, while native renderer and canvas updates are coalesced to one per 16 ms display interval.
- Overlay restoration, VNC refresh, pointer ownership and independent-window readiness are deferred to a 120 ms settle phase.
- `GLRenderer::Resize` deduplicates unchanged sizes and requests a retained-frame redraw after publishing the new viewport.

## Verification so far

- Native host suite: `810/810` PASS outside the sandbox.
- Exact `default@OhosTestCompileArkTS`: PASS on the current working tree.
- Exact signed `assembleHap`: PASS on the current working tree.
- Light open-source compliance and `git diff --check`: PASS.
- The signed working-tree HAP installed successfully on the local PC simulator while preserving app data.

## Acceptance boundary and blockers

- The simulator's saved Windows peer currently has no actual device password value and the remote approval request is waiting for the Windows side. Final upright-image and resize visual evidence is pending that approval.
- Independent review must be repeated because the prior PASS receipt covered the now-regressed identity policy, not this remediation.
- Device Hypium remains unavailable because task `00306054` is unregistered; compile coverage is required but is not reported as a device-test PASS.
