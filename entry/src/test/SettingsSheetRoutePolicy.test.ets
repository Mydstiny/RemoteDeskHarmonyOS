import { describe, it, expect } from '@ohos/hypium';
import {
  SETTINGS_SHEET_ACCOUNT,
  SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS,
  SETTINGS_SHEET_VNC_CLIPBOARD,
  SETTINGS_SHEET_VNC_CONNECTION,
  SETTINGS_SHEET_VNC_DISPLAY,
  SETTINGS_SHEET_VNC_GATEWAY,
  SETTINGS_SHEET_VNC_HOSTS,
  SETTINGS_SHEET_VNC_INPUT,
  SETTINGS_SHEET_VNC_PERFORMANCE,
  SETTINGS_SHEET_VNC_SECURITY,
  SETTINGS_SHEET_VNC_TIMEOUT,
  SETTINGS_SHEET_VNC_TRUST,
  settingsLeafSheetUsesSystemCloseButton,
  shouldDelaySettingsLeafOpenForPanel,
  settingsLeafOpenDelayMs,
  vncSettingsLeafSheetHeight
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

    it('sizes_vnc_settings_leaves_to_their_content_density', 0, (): void => {
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_DISPLAY)).assertEqual(700);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_INPUT)).assertEqual(560);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_TIMEOUT)).assertEqual(470);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_PERFORMANCE)).assertEqual(470);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_CONNECTION)).assertEqual(420);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_SECURITY)).assertEqual(340);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_CLIPBOARD)).assertEqual(320);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_TRUST)).assertEqual(280);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_HOSTS)).assertEqual(260);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_GATEWAY)).assertEqual(260);
      expect(vncSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
    });
  });
}
