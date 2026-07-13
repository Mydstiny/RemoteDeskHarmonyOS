import { describe, it, expect } from '@ohos/hypium';
import {
  SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS,
  settingsLeafSheetUsesSystemCloseButton,
  shouldDelaySettingsLeafOpenForPanel,
  settingsLeafOpenDelayMs
} from '../main/ets/services/SettingsSheetRoutePolicy';

export default function settingsSheetRoutePolicyTest() {
  describe('SettingsSheetRoutePolicy', (): void => {
    it('opens_settings_leaf_immediately_from_settings_tab', 0, (): void => {
      expect(shouldDelaySettingsLeafOpenForPanel(false)).assertFalse();
      expect(settingsLeafOpenDelayMs(false)).assertEqual(0);
    });

    it('delays_settings_leaf_when_replacing_pc_settings_panel', 0, (): void => {
      expect(shouldDelaySettingsLeafOpenForPanel(true)).assertTrue();
      expect(settingsLeafOpenDelayMs(true)).assertEqual(SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS);
    });

    it('settings_leaf_uses_content_controls_instead_of_system_close_button', 0, (): void => {
      expect(settingsLeafSheetUsesSystemCloseButton()).assertFalse();
    });
  });
}
