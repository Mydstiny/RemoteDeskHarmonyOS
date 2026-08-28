import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from
  '../main/ets/services/FocusedTestRegistrationAudit';
import {
  effectiveRustDeskDesktopFlipMode,
  normalizeRustDeskDesktopFlipMode,
  reprojectRustDeskDesktopFlipPan,
  rustDeskDesktopFlipRotations
} from '../main/ets/services/RustDeskDesktopFlipPolicy';
import {
  remotePointToSurface,
  RemoteSurfaceTransform,
  surfaceDeltaToRemote,
  surfacePointToRemote
} from '../main/ets/services/RemoteSurfaceTransformPolicy';

function transform(rotation: number): RemoteSurfaceTransform {
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
    rotation
  };
}

export default function rustDeskDesktopFlipPolicyTest(): void {
  describe('RustDeskDesktopFlipPolicy', (): void => {
    it('normalizes_the_persisted_three_state_contract', 0, (): void => {
      expect(normalizeRustDeskDesktopFlipMode('image_only')).assertEqual('image_only');
      expect(normalizeRustDeskDesktopFlipMode('image_and_controls'))
        .assertEqual('image_and_controls');
      expect(normalizeRustDeskDesktopFlipMode('unknown')).assertEqual('reset');
      expect(normalizeRustDeskDesktopFlipMode(undefined)).assertEqual('reset');
    });

    it('scopes_the_override_to_desktop_computer_peers', 0, (): void => {
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rustdesk', true, 'computer')).assertEqual('image_only');
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rustdesk', false, 'computer')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rustdesk', true, 'phone')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rustdesk', true, 'computer', 'android')).assertEqual('reset');
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rustdesk', true, 'phone', 'windows')).assertEqual('image_only');
      expect(effectiveRustDeskDesktopFlipMode(
        'image_only', 'rdp', true, 'computer')).assertEqual('reset');
    });

    it('separates_visual_and_input_rotation_for_each_mode', 0, (): void => {
      const reset = rustDeskDesktopFlipRotations('reset');
      const imageOnly = rustDeskDesktopFlipRotations('image_only');
      const imageAndControls = rustDeskDesktopFlipRotations('image_and_controls');
      expect(reset.visualQuarterTurns).assertEqual(0);
      expect(reset.inputQuarterTurns).assertEqual(0);
      expect(imageOnly.visualQuarterTurns).assertEqual(2);
      expect(imageOnly.inputQuarterTurns).assertEqual(0);
      expect(imageAndControls.visualQuarterTurns).assertEqual(2);
      expect(imageAndControls.inputQuarterTurns).assertEqual(2);
    });

    it('keeps_image_only_input_and_control_cursor_forward', 0, (): void => {
      const rotations = rustDeskDesktopFlipRotations('image_only');
      const input = surfacePointToRemote(transform(rotations.inputQuarterTurns), 25, 20);
      const cursor = remotePointToSurface(transform(rotations.inputQuarterTurns), 25, 20);
      expect(Math.abs(input.x - 25) < 0.01).assertTrue();
      expect(Math.abs(input.y - 20) < 0.01).assertTrue();
      expect(Math.abs(cursor.x - 25) < 0.01).assertTrue();
      expect(Math.abs(cursor.y - 20) < 0.01).assertTrue();
    });

    it('rotates_absolute_and_relative_input_when_controls_are_included', 0, (): void => {
      const rotations = rustDeskDesktopFlipRotations('image_and_controls');
      const input = surfacePointToRemote(transform(rotations.inputQuarterTurns), 25, 20);
      const delta = surfaceDeltaToRemote(transform(rotations.inputQuarterTurns), 10, 5);
      expect(Math.abs(input.x - 75) < 0.01).assertTrue();
      expect(Math.abs(input.y - 80) < 0.01).assertTrue();
      expect(Math.abs(delta.x + 10) < 0.01).assertTrue();
      expect(Math.abs(delta.y + 5) < 0.01).assertTrue();
    });

    it('reprojects_manual_pan_when_the_visual_layer_turns_180_degrees', 0, (): void => {
      const flipped = reprojectRustDeskDesktopFlipPan(0, 2, 18, -9);
      expect(flipped.panX).assertEqual(-18);
      expect(flipped.panY).assertEqual(9);
      const unchanged = reprojectRustDeskDesktopFlipPan(2, 2, -18, 9);
      expect(unchanged.panX).assertEqual(-18);
      expect(unchanged.panY).assertEqual(9);
    });
  });
}
