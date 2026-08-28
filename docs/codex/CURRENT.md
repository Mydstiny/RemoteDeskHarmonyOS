# Shared Current State

## Active task

- Task: `rustdesk-mobile-display-input-and-settings-accordion-fix`
- Branch: `codex/system-clipboard-activation-fix`; user authorized the current worktree.
- Increment: `6e2fece58..0bc68d030`.
- Phase: implemented, locally verified and independently reviewed; Android device acceptance pending.
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
- Recheck authenticated phone identity at delayed right-click boundaries and drain all queued/held input when the control mode changes.

## Verification

- `default@OhosTestCompileArkTS`: PASS after review fixes (`BUILD SUCCESSFUL in 8 s 753 ms`).
- `assembleHap`: PASS, signed after review fixes (`BUILD SUCCESSFUL in 16 s 771 ms`).
- Signed HAP SHA-256: `4dbd6cdcf5f2561f00d3b35bfb67a2c5782deadad5499a4dd1947d2e0ccfe68a`.
- Settings accordion policy tests cover Data Security growth and `sm`/`md`/`lg`/`xl` RDP heights; ArkTS test compile passed.
- New native policy tests: PASS. Full native suite: 799 passed; 16 known VNC TLS fixture startup failures.
- Light open-source compliance and `git diff --check`: PASS.
- Independent review: PASS after fixing two P2 input-transition findings; final P0-P3 are zero.

## Next / blockers

1. Validate an Android phone in portrait and landscape: orientation, Fit, manual zoom/pan, tap, swipe, long-press, two-finger canvas gesture and interrupted release.
2. Visually verify the Data Security and Windows RDP expanded-card bottom spacing on the target device.
3. HDC currently reports `Connect server failed`; no device acceptance was claimed.
4. The prior app-clone increment remains queued for release-provisioned phone/tablet acceptance.
