# Shared Current State

## Active task

- Task: `rustdesk-mobile-display-input-and-settings-accordion-fix`
- Branch: `codex/system-clipboard-activation-fix`; user authorized the current worktree.
- Increment: `6e2fece58..78d4ce868`.
- Phase: implemented and locally verified; Android device acceptance and independent review pending.
- Plan: `docs/codex/plans/2026-08-28-rustdesk-mobile-display-input-quick-optimization.md`
- Follow-up plan: `docs/codex/plans/2026-08-28-settings-accordion-layout-fix.md`

## Implemented

- Accept all eight safe axis-aligned NativeImage orientation transforms.
- Recreate the fixed decoder/NativeImage pipeline when the first or a later keyframe changes geometry.
- Preserve manual zoom multiplier and focus across window and remote-source rotation; Fit remains centred.
- Use authenticated Android/iOS peer platform for phone touch semantics, remove local long-press-to-right-click, and suppress phone two-finger right-click.
- Release held input before browse/permission/mode/geometry gates and block new input when the remote control permission is disabled.
- Size the Data Security accordion for its new secret-visibility row and retained bottom spacing.
- Size Windows RDP by breakpoint so its stacked phone selectors, final credential row and bottom spacing are not clipped.

## Verification

- `default@OhosTestCompileArkTS`: PASS after the layout fix (`BUILD SUCCESSFUL in 6 s 938 ms`).
- `assembleHap`: PASS, signed after the layout fix (`BUILD SUCCESSFUL in 14 s 541 ms`).
- Signed HAP SHA-256: `9908b30007d4e63d763cbc4676b83a4a74a1af3fd869c04e9ff6d850b84743e6`.
- Settings accordion policy tests cover Data Security growth and `sm`/`md`/`lg`/`xl` RDP heights; ArkTS test compile passed.
- New native policy tests: PASS. Full native suite: 799 passed; 16 known VNC TLS fixture startup failures.
- Light open-source compliance and `git diff --check`: PASS.

## Next / blockers

1. Validate an Android phone in portrait and landscape: orientation, Fit, manual zoom/pan, tap, swipe, long-press, two-finger canvas gesture and interrupted release.
2. Run independent review for `6e2fece58..78d4ce868` before merge.
3. HDC currently reports `Connect server failed`; no device acceptance was claimed.
4. The prior app-clone increment remains queued for release-provisioned phone/tablet acceptance.
