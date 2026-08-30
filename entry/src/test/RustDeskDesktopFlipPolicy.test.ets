import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from
  '../main/ets/services/FocusedTestRegistrationAudit';
import {
  effectiveRustDeskDesktopFlipMode,
  normalizeRustDeskDesktopFlipMode,
  reprojectRustDeskDesktopFlipPan,
  rustDeskDesktopFlipState,
  toggleRustDeskDesktopFlipAxis,
  stableRustDeskDesktopFlipPeerPlatform
} from '../main/ets/services/RustDeskDesktopFlipPolicy';
import {
  remotePointToSurface,
  RemoteSurfaceTransform,
  surfaceDeltaToRemote,
  surfacePointToRemote
} from '../main/ets/services/RemoteSurfaceTransformPolicy';

function transform(flipX: boolean = false, flipY: boolean = false): RemoteSurfaceTransform {
  return {
    remoteWidth: 100,
    remoteHeight: 100,
    viewportX: 0,
    viewportY: 0,
    viewportW: 100,
    viewportH: 100,
    surfaceWidthPx: 100,
    surfaceHeightPx: 100,
    surfaceWidthVp: 100,
    surfaceHeightVp: 100,
    rotation: 0,
    flipX,
    flipY
  };
}

export default function rustDeskDesktopFlipPolicyTest(): void {
  describe('RustDeskDesktopFlipPolicy', (): void => {
    it('normalizes_axis_masks_and_migrates_the_released_three_state_contract', 0, (): void => {
      expect(normalizeRustDeskDesktopFlipMode('image_only')).assertEqual('axes_3');
      expect(normalizeRustDeskDesktopFlipMode('image_and_controls'))
        .assertEqual('axes_15');
      expect(normalizeRustDeskDesktopFlipMode('axes_1')).assertEqual('axes_1');
      expect(normalizeRustDeskDesktopFlipMode('axes_0')).assertEqual('reset');
      expect(normalizeRustDeskDesktopFlipMode('axes_16')).assertEqual('reset');
      expect(normalizeRustDeskDesktopFlipMode('unknown')).assertEqual('reset');
      expect(normalizeRustDeskDesktopFlipMode(undefined)).assertEqual('reset');
    });

    it('scopes_the_override_to_desktop_computer_peers', 0, (): void => {
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rustdesk', true, 'computer')).assertEqual('axes_2');
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rustdesk', false, 'computer')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rustdesk', true, 'phone')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rustdesk', true, 'computer', 'android')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rustdesk', true, 'phone', 'windows')).assertEqual('axes_2');
      expect(effectiveRustDeskDesktopFlipMode(
        'axes_2', 'rdp', true, 'computer')).assertEqual('reset');
    });

    it('keeps_authenticated_mobile_scope_across_transient_unknown_reconnects', 0, (): void => {
      const authenticated: string = stableRustDeskDesktopFlipPeerPlatform('unknown', 'android');
      const reconnecting: string = stableRustDeskDesktopFlipPeerPlatform(authenticated, 'unknown');
      const reauthenticated: string = stableRustDeskDesktopFlipPeerPlatform(reconnecting, 'android');
      expect(authenticated).assertEqual('android');
      expect(reconnecting).assertEqual('android');
      expect(reauthenticated).assertEqual('android');
      expect(stableRustDeskDesktopFlipPeerPlatform('unknown', 'windows')).assertEqual('windows');
    });

    it('toggles_each_visual_and_control_axis_independently', 0, (): void => {
      let mode: string = toggleRustDeskDesktopFlipAxis('reset', 'visual_y');
      expect(mode).assertEqual('axes_1');
      mode = toggleRustDeskDesktopFlipAxis(mode, 'visual_x');
      expect(mode).assertEqual('axes_3');
      mode = toggleRustDeskDesktopFlipAxis(mode, 'control_y');
      expect(mode).assertEqual('axes_7');
      mode = toggleRustDeskDesktopFlipAxis(mode, 'control_x');
      expect(mode).assertEqual('axes_15');
      mode = toggleRustDeskDesktopFlipAxis(mode, 'visual_y');
      const state = rustDeskDesktopFlipState(mode);
      expect(mode).assertEqual('axes_14');
      expect(state.visualFlipY).assertFalse();
      expect(state.visualFlipX).assertTrue();
      expect(state.controlFlipY).assertTrue();
      expect(state.controlFlipX).assertTrue();
    });

    it('keeps_control_mapping_forward_when_only_the_visual_axes_are_enabled', 0, (): void => {
      const state = rustDeskDesktopFlipState('axes_3');
      const input = surfacePointToRemote(transform(state.controlFlipX, state.controlFlipY), 25, 20);
      const cursor = remotePointToSurface(transform(state.controlFlipX, state.controlFlipY), 25, 20);
      expect(Math.abs(input.x - 25) < 0.01).assertTrue();
      expect(Math.abs(input.y - 20) < 0.01).assertTrue();
      expect(Math.abs(cursor.x - 25) < 0.01).assertTrue();
      expect(Math.abs(cursor.y - 20) < 0.01).assertTrue();
    });

    it('mirrors_absolute_and_relative_input_on_both_control_axes', 0, (): void => {
      const state = rustDeskDesktopFlipState('axes_12');
      const input = surfacePointToRemote(transform(state.controlFlipX, state.controlFlipY), 25, 20);
      const delta = surfaceDeltaToRemote(transform(state.controlFlipX, state.controlFlipY), 10, 5);
      expect(Math.abs(input.x - 75) < 0.01).assertTrue();
      expect(Math.abs(input.y - 80) < 0.01).assertTrue();
      expect(Math.abs(delta.x + 10) < 0.01).assertTrue();
      expect(Math.abs(delta.y + 5) < 0.01).assertTrue();
    });

    it('reprojects_only_the_pan_axis_whose_visual_mirror_changes', 0, (): void => {
      const flipped = reprojectRustDeskDesktopFlipPan('reset', 'axes_1', 18, -9);
      expect(flipped.panX).assertEqual(18);
      expect(flipped.panY).assertEqual(9);
      const both = reprojectRustDeskDesktopFlipPan('axes_1', 'axes_2', 18, 9);
      expect(both.panX).assertEqual(-18);
      expect(both.panY).assertEqual(-9);
      const unchanged = reprojectRustDeskDesktopFlipPan('axes_2', 'axes_10', -18, 9);
      expect(unchanged.panX).assertEqual(-18);
      expect(unchanged.panY).assertEqual(9);
    });
  });
}
