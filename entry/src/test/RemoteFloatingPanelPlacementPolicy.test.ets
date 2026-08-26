import { describe, it, expect } from '@ohos/hypium';
import {
  anchorFloatingPanelToHandle,
  clampFloatingPanel,
  floatingPanelAvailableHeight,
  floatingPanelOrientationSuffix,
  placeFloatingCompanion,
  remoteModifierPanelWidth
} from '../main/ets/services/RemoteFloatingPanelPlacementPolicy';

export default function remoteFloatingPanelPlacementPolicyTest(): void {
  describe('RemoteFloatingPanelPlacementPolicy', (): void => {
    it('anchors_and_clamps_measured_panel', 0, (): void => {
      const viewport = { width: 360, height: 640, topMargin: 48, bottomMargin: 24, sideMargin: 8 };
      const panel = anchorFloatingPanelToHandle('right', 620, 260, 180, viewport);
      expect(panel.x).assertEqual(92);
      expect(panel.y).assertEqual(436);
      const clamped = clampFloatingPanel(-20, -10, 260, 180, viewport);
      expect(clamped.x).assertEqual(8);
      expect(clamped.y).assertEqual(48);
    });

    it('limits_panel_height_to_safe_and_ime_adjusted_viewport', 0, (): void => {
      expect(floatingPanelAvailableHeight({
        width: 760, height: 360, topMargin: 48, bottomMargin: 24, sideMargin: 8
      })).assertEqual(288);
      expect(floatingPanelAvailableHeight({
        width: 760, height: 360, topMargin: 48, bottomMargin: 180, sideMargin: 8
      })).assertEqual(132);
    });

    it('uses_moonlight_sized_panel_for_phone_rails_without_overflow', 0, (): void => {
      expect(remoteModifierPanelWidth('sm', 780, true)).assertEqual(320);
      expect(remoteModifierPanelWidth('sm', 300, true)).assertEqual(284);
      expect(remoteModifierPanelWidth('sm', 780, false)).assertEqual(260);
      expect(remoteModifierPanelWidth('lg', 780, false)).assertEqual(300);
    });

    it('places_shortcut_without_overlapping_primary_when_space_exists', 0, (): void => {
      const viewport = { width: 900, height: 600, topMargin: 48, bottomMargin: 24, sideMargin: 8 };
      const shortcut = placeFloatingCompanion(100, 90, 280, 150, 280, 240, viewport);
      expect(shortcut.x).assertEqual(392);
      expect(shortcut.y).assertEqual(90);
    });

    it('places_shortcut_below_primary_on_a_narrow_portrait_viewport', 0, (): void => {
      const viewport = { width: 360, height: 700, topMargin: 48, bottomMargin: 24, sideMargin: 8 };
      const shortcut = placeFloatingCompanion(92, 100, 260, 136, 260, 238, viewport);
      expect(shortcut.x).assertEqual(92);
      expect(shortcut.y).assertEqual(248);
    });

    it('minimizes_overlap_when_keyboard_leaves_no_nonoverlapping_position', 0, (): void => {
      const viewport = { width: 373, height: 843, topMargin: 48, bottomMargin: 336, sideMargin: 8 };
      const shortcut = placeFloatingCompanion(46, 100, 280, 300, 280, 300, viewport);
      const overlapWidth: number = Math.max(0,
        Math.min(326, shortcut.x + 280) - Math.max(46, shortcut.x));
      const overlapHeight: number = Math.max(0,
        Math.min(400, shortcut.y + 300) - Math.max(100, shortcut.y));
      expect(shortcut.x >= 8).assertTrue();
      expect(shortcut.x + 280 <= 365).assertTrue();
      expect(shortcut.y >= 48).assertTrue();
      expect(shortcut.y + 300 <= 507).assertTrue();
      expect(overlapWidth * overlapHeight < 280 * 300).assertTrue();
    });

    it('uses_orientation_specific_suffix', 0, (): void => {
      expect(floatingPanelOrientationSuffix(800, 500)).assertEqual('Landscape');
      expect(floatingPanelOrientationSuffix(360, 720)).assertEqual('Portrait');
    });
  });
}
