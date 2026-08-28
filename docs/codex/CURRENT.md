# Shared Current State

## Active task

- Task: `rustdesk-mobile-display-input-optimization`
- Branch: `codex/system-clipboard-activation-fix`; user authorized the current worktree.
- Increment: `6e2fece58..0b2435496`.
- Phase: implemented and locally verified; Android device acceptance and independent review pending.
- Plan: `docs/codex/plans/2026-08-28-rustdesk-mobile-display-input-quick-optimization.md`

## Implemented

- Accept all eight safe axis-aligned NativeImage orientation transforms.
- Recreate the fixed decoder/NativeImage pipeline when the first or a later keyframe changes geometry.
- Preserve manual zoom multiplier and focus across window and remote-source rotation; Fit remains centred.
- Use authenticated Android/iOS peer platform for phone touch semantics, remove local long-press-to-right-click, and suppress phone two-finger right-click.
- Release held input before browse/permission/mode/geometry gates and block new input when the remote control permission is disabled.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 9 s 150 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 16 s 211 ms`).
- Signed HAP SHA-256: `0b7ff612b47a5577eb28972283988acd69280a8cebaf9bda12f2cbea972448ab`.
- New native policy tests: PASS. Full native suite: 799 passed; 16 known VNC TLS fixture startup failures.
- Light open-source compliance and `git diff --check`: PASS.

## Next / blockers

1. Validate an Android phone in portrait and landscape: orientation, Fit, manual zoom/pan, tap, swipe, long-press, two-finger canvas gesture and interrupted release.
2. Run independent review for `6e2fece58..0b2435496` before merge.
3. HDC currently reports `Connect server failed`; no device acceptance was claimed.
4. The prior app-clone increment remains queued for release-provisioned phone/tablet acceptance.
