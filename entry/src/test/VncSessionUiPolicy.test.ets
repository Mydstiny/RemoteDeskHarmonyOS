import { describe, it, expect } from '@ohos/hypium';
import {
  nextVncControlMode,
  nextVncDisplayScaleMode,
  shouldShowVncSessionToolbar,
  vncToolbarAutoCollapseDelayMs,
  vncToolbarDefaultSide,
  vncToolbarPositionPreferenceKey,
  vncToolbarRailHeight,
  vncToolbarRailWidth
} from '../main/ets/services/VncSessionUiPolicy';

export default function vncSessionUiPolicyTest(): void {
  describe('VncSessionUiPolicy', (): void => {
    it('shows_toolbar_only_for_connected_vnc_session', 0, (): void => {
      expect(shouldShowVncSessionToolbar('vnc', true, 4)).assertTrue();
      expect(shouldShowVncSessionToolbar('vnc', false, 4)).assertFalse();
      expect(shouldShowVncSessionToolbar('rdp', true, 4)).assertFalse();
    });

    it('cycles_control_modes_without_bypassing_view_only', 0, (): void => {
      expect(nextVncControlMode(0, false)).assertEqual(1);
      expect(nextVncControlMode(1, false)).assertEqual(2);
      expect(nextVncControlMode(2, false)).assertEqual(0);
      expect(nextVncControlMode(1, true)).assertEqual(1);
    });

    it('cycles_supported_live_scale_modes', 0, (): void => {
      expect(nextVncDisplayScaleMode('fit')).assertEqual('100');
      expect(nextVncDisplayScaleMode('100')).assertEqual('integer');
      expect(nextVncDisplayScaleMode('integer')).assertEqual('fit');
      expect(nextVncDisplayScaleMode('custom')).assertEqual('fit');
    });

    it('collapses_expanded_live_toolbar_after_twenty_seconds', 0, (): void => {
      expect(vncToolbarAutoCollapseDelayMs(true, false)).assertEqual(20000);
      expect(vncToolbarAutoCollapseDelayMs(true, true)).assertEqual(0);
      expect(vncToolbarAutoCollapseDelayMs(false, false)).assertEqual(0);
    });

    it('keeps_pc_on_legacy_toolbar_geometry', 0, (): void => {
      expect(vncToolbarRailWidth('pc', false)).assertEqual(0);
      expect(vncToolbarRailWidth('pc', true)).assertEqual(0);
      expect(vncToolbarRailHeight('pc', false, false)).assertEqual(0);
      expect(vncToolbarDefaultSide('pc')).assertEqual('right');
    });

    it('uses_edge_rail_dimensions_for_phone_and_pad', 0, (): void => {
      expect(vncToolbarRailWidth('phone', false)).assertEqual(76);
      expect(vncToolbarRailWidth('phone', true)).assertEqual(44);
      expect(vncToolbarRailHeight('phone', false, false)).assertEqual(252);
      expect(vncToolbarRailHeight('phone', false, true)).assertEqual(44);
      expect(vncToolbarRailWidth('pad', false)).assertEqual(76);
      expect(vncToolbarRailHeight('pad', false, false)).assertEqual(301);
      expect(vncToolbarRailHeight('pad', true, false)).assertEqual(330);
      expect(vncToolbarRailHeight('pad', true, true)).assertEqual(44);
    });

    it('isolates_vnc_position_preferences_by_device_and_orientation', 0, (): void => {
      expect(vncToolbarPositionPreferenceKey('phone', 'portrait', 'side'))
        .assertEqual('vncSessionToolbar:phone:portrait:side');
      expect(vncToolbarPositionPreferenceKey('pad', 'landscape', 'yRatio'))
        .assertEqual('vncSessionToolbar:pad:landscape:yRatio');
      expect(vncToolbarPositionPreferenceKey('pc', 'portrait', 'side'))
        .assertEqual('vncSessionToolbar:pc:portrait:side');
    });
  });
}
