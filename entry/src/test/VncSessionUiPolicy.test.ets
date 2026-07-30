import { describe, it, expect } from '@ohos/hypium';
import {
  nextVncControlMode,
  nextVncDisplayScaleMode,
  shouldShowVncSessionToolbar,
  vncToolbarAutoCollapseDelayMs
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
  });
}
