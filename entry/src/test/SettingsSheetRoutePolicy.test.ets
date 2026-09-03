import { describe, it, expect } from '@ohos/hypium';
import {
  SETTINGS_SHEET_ACCOUNT,
  SETTINGS_SHEET_DIAGNOSTIC_LOG,
  SETTINGS_SHEET_SECRET_VISIBILITY,
  SETTINGS_SHEET_REMOTE_WHEEL_DIRECTION,
  SETTINGS_SHEET_REMOTE_PINCH_ZOOM,
  SETTINGS_SHEET_SESSION_CONTROL_BAR,
  SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_BEHAVIOR,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_FUNCTIONS,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_SHORTCUTS,
  SETTINGS_SHEET_MOONLIGHT_AUDIO,
  SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS,
  SETTINGS_SHEET_MOONLIGHT_INPUT,
  SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY,
  SETTINGS_SHEET_MOONLIGHT_VIDEO,
  SETTINGS_SHEET_MOONLIGHT_TRUST,
  SETTINGS_SHEET_MOONLIGHT_DATA,
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
  diagnosticLogSettingsLeafSheetHeight,
  secretVisibilitySettingsLeafSheetHeight,
  remoteWheelDirectionSettingsLeafSheetHeight,
  remotePinchZoomSettingsLeafSheetHeight,
  sessionControlBarSettingsLeafSheetHeight,
  isVirtualKeyboardSettingsMode,
  moonlightSettingsLeafSheetHeight,
  moonlightSettingsRouteSpec,
  moonlightSettingsRouteSpecs,
  virtualKeyboardSettingsContentLayout,
  virtualKeyboardSettingsLeafSheetHeight,
  virtualKeyboardSettingsLeafUsesBottomSheet,
  virtualKeyboardSettingsRouteSpec,
  virtualKeyboardSettingsRouteSpecs,
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

    it('allocates_one_independent_global_diagnostic_log_leaf', 0, (): void => {
      expect(SETTINGS_SHEET_DIAGNOSTIC_LOG).assertEqual(31);
      expect(diagnosticLogSettingsLeafSheetHeight(SETTINGS_SHEET_DIAGNOSTIC_LOG))
        .assertEqual(740);
      expect(diagnosticLogSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_DIAGNOSTIC_LOG)).assertNull();
    });

    it('allocates_one_device_local_secret_visibility_leaf', 0, (): void => {
      expect(SETTINGS_SHEET_SECRET_VISIBILITY).assertEqual(37);
      expect(secretVisibilitySettingsLeafSheetHeight(SETTINGS_SHEET_SECRET_VISIBILITY))
        .assertEqual(760);
      expect(secretVisibilitySettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_SECRET_VISIBILITY)).assertNull();
    });

    it('allocates_one_per_protocol_remote_wheel_editor_leaf', 0, (): void => {
      expect(SETTINGS_SHEET_REMOTE_WHEEL_DIRECTION).assertEqual(38);
      expect(remoteWheelDirectionSettingsLeafSheetHeight(
        SETTINGS_SHEET_REMOTE_WHEEL_DIRECTION)).assertEqual(680);
      expect(remoteWheelDirectionSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_REMOTE_WHEEL_DIRECTION)).assertNull();
    });

    it('allocates_one_per_protocol_pinch_zoom_editor_leaf', 0, (): void => {
      expect(SETTINGS_SHEET_REMOTE_PINCH_ZOOM).assertEqual(39);
      expect(remotePinchZoomSettingsLeafSheetHeight(
        SETTINGS_SHEET_REMOTE_PINCH_ZOOM)).assertEqual(700);
      expect(remotePinchZoomSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_REMOTE_PINCH_ZOOM)).assertNull();
    });

    it('allocates_one_per_protocol_session_control_bar_editor_leaf', 0, (): void => {
      expect(SETTINGS_SHEET_SESSION_CONTROL_BAR).assertEqual(40);
      expect(sessionControlBarSettingsLeafSheetHeight(
        SETTINGS_SHEET_SESSION_CONTROL_BAR)).assertEqual(620);
      expect(sessionControlBarSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_SESSION_CONTROL_BAR)).assertNull();
    });

    it('allocates_six_independent_keyboard_leaves', 0, (): void => {
      expect(SETTINGS_SHEET_VIRTUAL_KEYBOARD).assertEqual(32);
      expect(SETTINGS_SHEET_VIRTUAL_KEYBOARD_BEHAVIOR).assertEqual(33);
      expect(SETTINGS_SHEET_VIRTUAL_KEYBOARD_SHORTCUTS).assertEqual(34);
      expect(SETTINGS_SHEET_VIRTUAL_KEYBOARD_FUNCTIONS).assertEqual(35);
      expect(SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM).assertEqual(36);
      const specs = virtualKeyboardSettingsRouteSpecs();
      expect(SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING).assertEqual(41);
      expect(specs.length).assertEqual(6);
      expect(specs[0].section).assertEqual('system');
      expect(specs[1].section).assertEqual('behavior');
      expect(specs[2].section).assertEqual('shortcuts');
      expect(specs[3].section).assertEqual('functions');
      expect(specs[4].section).assertEqual('custom');
      expect(specs[5].section).assertEqual('harmonyShortcuts');
      for (let i = 0; i < specs.length; i++) {
        if (i < 5) { expect(specs[i].mode).assertEqual(32 + i); }
        expect(specs[i].height > 0).assertTrue();
        expect(specs[i].title.length > 0).assertTrue();
        expect(isVirtualKeyboardSettingsMode(specs[i].mode)).assertTrue();
        expect(virtualKeyboardSettingsLeafSheetHeight(specs[i].mode)).assertEqual(specs[i].height);
      }
      expect(virtualKeyboardSettingsRouteSpec(SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM)?.title)
        .assertEqual('自定义组合键');
      expect(virtualKeyboardSettingsRouteSpec(SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING)?.title)
        .assertEqual('屏蔽鸿蒙快捷键');
      expect(virtualKeyboardSettingsLeafSheetHeight(SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING))
        .assertEqual(820);
      expect(virtualKeyboardSettingsRouteSpec(SETTINGS_SHEET_ACCOUNT)).assertNull();
      expect(isVirtualKeyboardSettingsMode(SETTINGS_SHEET_ACCOUNT)).assertFalse();
      expect(virtualKeyboardSettingsLeafSheetHeight(SETTINGS_SHEET_ACCOUNT)).assertEqual(0);
    });

    it('adapts_all_virtual_keyboard_leaves_to_live_window_bounds', 0, (): void => {
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD, 720)).assertEqual(620);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_BEHAVIOR, 720)).assertEqual(560);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_SHORTCUTS, 360)).assertEqual(348);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_FUNCTIONS, 300)).assertEqual(288);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 900)).assertEqual(520);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 900, true)).assertEqual(820);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 720, true)).assertEqual(680);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING, 900)).assertEqual(820);
      expect(virtualKeyboardSettingsLeafSheetHeight(
        SETTINGS_SHEET_HARMONY_SHORTCUT_BLOCKING, 720)).assertEqual(680);
      expect(virtualKeyboardSettingsLeafUsesBottomSheet(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 800, 'sm')).assertTrue();
      expect(virtualKeyboardSettingsLeafUsesBottomSheet(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 360, 'md')).assertTrue();
      expect(virtualKeyboardSettingsLeafUsesBottomSheet(
        SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM, 720, 'md')).assertFalse();
      expect(virtualKeyboardSettingsLeafUsesBottomSheet(
        SETTINGS_SHEET_ACCOUNT, 360, 'sm')).assertFalse();
    });

    it('adapts_virtual_keyboard_content_density_to_measured_sheet_size', 0, (): void => {
      const narrowLandscape = virtualKeyboardSettingsContentLayout(320, 360);
      expect(narrowLandscape.headerHorizontalPadding).assertEqual(12);
      expect(narrowLandscape.contentHorizontalPadding).assertEqual(12);
      expect(narrowLandscape.titleFontSize).assertEqual(18);
      expect(narrowLandscape.heroIconSize).assertEqual(42);
      expect(narrowLandscape.cornerRadius).assertEqual(18);
      expect(narrowLandscape.stackPrimaryActions).assertTrue();

      const splitPad = virtualKeyboardSettingsContentLayout(500, 640);
      expect(splitPad.headerHorizontalPadding).assertEqual(16);
      expect(splitPad.contentHorizontalPadding).assertEqual(16);
      expect(splitPad.titleFontSize).assertEqual(20);
      expect(splitPad.stackPrimaryActions).assertFalse();

      const desktop = virtualKeyboardSettingsContentLayout(900, 820);
      expect(desktop.maxContentWidth).assertEqual(720);
      expect(desktop.headerHorizontalPadding).assertEqual(22);
      expect(desktop.contentHorizontalPadding).assertEqual(22);
      expect(desktop.titleFontSize).assertEqual(22);
      expect(desktop.cornerRadius).assertEqual(28);
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

    it('allocates_contiguous_owned_moonlight_routes_after_existing_modes', 0, (): void => {
      const specs = moonlightSettingsRouteSpecs();
      expect(specs.length).assertEqual(7);
      expect(specs[0].mode).assertEqual(SETTINGS_SHEET_MOONLIGHT_VIDEO);
      for (let i = 0; i < specs.length; i++) {
        expect(specs[i].mode).assertEqual(24 + i);
        expect(specs[i].owner).assertEqual('moonlight');
        expect(specs[i].height > 0).assertTrue();
        expect(specs[i].title.length > 0).assertTrue();
      }
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_VIDEO)?.section).assertEqual('video');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_VIDEO)?.title).assertEqual('画面');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_VIDEO)).assertEqual(820);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_AUDIO)?.section).assertEqual('audio');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_AUDIO)?.title).assertEqual('音频');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_AUDIO)).assertEqual(620);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_INPUT)?.section).assertEqual('input');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_INPUT)?.title).assertEqual('控制与手柄');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_INPUT)).assertEqual(680);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY)?.section)
        .assertEqual('networkSecurity');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY)?.title)
        .assertEqual('网络与安全');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY))
        .assertEqual(820);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS)?.section)
        .assertEqual('diagnostics');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS)?.title).assertEqual('诊断');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS)).assertEqual(560);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_TRUST)?.section).assertEqual('trust');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_TRUST)?.title).assertEqual('配对与信任');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_TRUST)).assertEqual(520);
      expect(SETTINGS_SHEET_MOONLIGHT_TRUST).assertEqual(29);
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_DATA)?.section)
        .assertEqual('data');
      expect(moonlightSettingsRouteSpec(SETTINGS_SHEET_MOONLIGHT_DATA)?.title)
        .assertEqual('数据管理');
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_MOONLIGHT_DATA))
        .assertEqual(720);
      expect(moonlightSettingsLeafSheetHeight(SETTINGS_SHEET_VNC_CONNECTION)).assertEqual(0);
      expect(moonlightSettingsRouteSpec(23)).assertNull();
      expect(moonlightSettingsRouteSpec(31)).assertNull();
    });
  });
}
