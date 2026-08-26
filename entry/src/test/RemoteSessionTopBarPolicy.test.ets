import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  REMOTE_SESSION_COLLAPSED_TOP_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_WIDTH,
  protocolPreferenceOwner,
  remoteSessionControlBarHidden,
  remoteSessionControlBarSelectionSummary,
  remoteSessionPrimaryActionIds,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse,
  resolveRemoteSessionControlBarVisibility,
  remoteTopBarDeviceClass,
  remoteTopBarLayout,
  shouldShowRemoteSessionTopBar,
  shouldUseRemoteSessionEdgeRail,
  rustDeskTopBarAutoCollapseDelayMs,
  rustDeskActionAvailability,
  shouldShowRustDeskTopBar,
  shouldUseRustDeskEdgeRail
} from '../main/ets/services/RemoteSessionTopBarPolicy';

export default function remoteSessionTopBarPolicyTest(): void {
  // Keep one exact class boundary around this multi-domain policy suite.  The
  // on-device focused runner selects the outer class; without it Hypium sees
  // only the five nested describe names and a request for the exact suite
  // name incorrectly reports 0/0.
  describe('RemoteSessionTopBarPolicy', (): void => {
  describe('RemoteSessionTopBarPolicy_visibility', (): void => {
    it('pc_rustdesk_should_show_on_small_window', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'md', 0, false, false)).assertTrue();
    });

    it('pc_rustdesk_should_show_on_full_window', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'xl', 0, false, false)).assertTrue();
    });

    it('pc_rustdesk_should_keep_a_recoverable_toolbar_when_legacy_hidden_is_set', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'xl', 0, false, false, true)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 0, false, true, true)).assertTrue();
    });

    it('phone_rustdesk_should_show_in_every_control_mode', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 2, true, false)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 2, false, false)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 0, true, false)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 1, true, false)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'md', 0, true, false)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'md', 2, true, false)).assertTrue();
    });

    it('pad_rustdesk_should_keep_layout_choice_discoverable_in_all_modes', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 2, false, true)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 0, false, true)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 1, false, true)).assertTrue();
    });

    it('rdp_should_not_show_rustdesk_topbar', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rdp', true, 'xl', 2, true, false)).assertFalse();
      expect(shouldShowRustDeskTopBar('rdp', false, 'sm', 2, true, false)).assertFalse();
    });

    it('rdp_should_use_its_own_sidebar_instead_of_the_rustdesk_shell', 0, (): void => {
      expect(shouldShowRemoteSessionTopBar('rdp')).assertFalse();
      expect(shouldShowRemoteSessionTopBar('rustdesk')).assertTrue();
      expect(shouldShowRemoteSessionTopBar('vnc')).assertFalse();
      const visibility = {
        rdpHidden: true, rustDeskHidden: false, vncHidden: true, moonlightHidden: false
      };
      expect(remoteSessionControlBarHidden('rdp', visibility)).assertTrue();
      expect(remoteSessionControlBarHidden('rustdesk', visibility)).assertFalse();
      expect(remoteSessionControlBarHidden('vnc', visibility)).assertTrue();
      expect(remoteSessionControlBarHidden('moonlight', visibility)).assertFalse();
      expect(remoteSessionControlBarHidden('ssh', visibility)).assertFalse();
      expect(remoteSessionControlBarSelectionSummary(visibility)).assertEqual('已隐藏：RDP、VNC');
      expect(remoteSessionControlBarSelectionSummary({
        rdpHidden: false, rustDeskHidden: false, vncHidden: false, moonlightHidden: false
      })).assertEqual('全部显示');
      const migrated = resolveRemoteSessionControlBarVisibility({
        rdpHidden: false, rustDeskHidden: false, vncHidden: false, moonlightHidden: false
      }, { rustDeskPresent: false, vncPresent: false }, true);
      expect(migrated.rustDeskHidden).assertTrue();
      expect(migrated.vncHidden).assertTrue();
      const explicit = resolveRemoteSessionControlBarVisibility({
        rdpHidden: true, rustDeskHidden: false, vncHidden: false, moonlightHidden: true
      }, { rustDeskPresent: true, vncPresent: true }, true);
      expect(explicit.rdpHidden).assertTrue();
      expect(explicit.rustDeskHidden).assertFalse();
      expect(explicit.vncHidden).assertFalse();
      expect(explicit.moonlightHidden).assertTrue();
    });
  });

  describe('RemoteSessionTopBarPolicy_layout', (): void => {
    it('device_class_should_prefer_desktop_device_over_breakpoint', 0, (): void => {
      expect(remoteTopBarDeviceClass(true, 'sm', false)).assertEqual('pc');
      expect(remoteTopBarDeviceClass(false, 'lg', true)).assertEqual('pad');
      expect(remoteTopBarDeviceClass(false, 'md', false)).assertEqual('phone');
      expect(remoteTopBarDeviceClass(false, 'sm', false)).assertEqual('phone');
    });

    it('pc_small_window_layout_should_be_compact_but_not_mobile', 0, (): void => {
      const layout = remoteTopBarLayout(true, 'md', false);
      expect(layout.deviceClass).assertEqual('pc');
      expect(layout.iconSize).assertEqual(36);
      expect(layout.maxVisibleButtons).assertEqual(8);
      expect(layout.maxVisibleButtons * layout.iconSize +
        (layout.maxVisibleButtons + 1) * layout.itemGap <= 360).assertTrue();
      expect(layout.topOffset).assertEqual(0);
      expect(remoteTopBarLayout(true, 'xl', false).iconSize).assertEqual(44);
      expect(remoteTopBarLayout(true, 'xl', false).topOffset).assertEqual(0);
    });

    it('phone_layout_should_limit_visible_buttons', 0, (): void => {
      const layout = remoteTopBarLayout(false, 'sm', false);
      expect(layout.deviceClass).assertEqual('phone');
      expect(layout.iconSize).assertEqual(40);
      expect(layout.maxVisibleButtons).assertEqual(8);
    });
  });

  describe('RemoteSessionTopBarPolicy_edgeRail', (): void => {
    it('keeps_a_narrow_visual_handle_with_an_accessible_touch_target', 0, (): void => {
      expect(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH).assertEqual(22);
      expect(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT).assertEqual(72);
      expect(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH >= 40).assertTrue();
      expect(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH >
        REMOTE_SESSION_COLLAPSED_RAIL_WIDTH).assertTrue();
      expect(REMOTE_SESSION_COLLAPSED_TOP_WIDTH).assertEqual(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT);
      expect(REMOTE_SESSION_COLLAPSED_TOP_HEIGHT).assertEqual(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH);
      expect(REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT)
        .assertEqual(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH);
    });

    it('collapses_only_for_an_intentional_right_swipe', 0, (): void => {
      expect(remoteSessionRailDragOffset(-12)).assertEqual(0);
      expect(remoteSessionRailDragOffset(18)).assertEqual(18);
      expect(remoteSessionRailDragOffset(90)).assertEqual(72);
      expect(remoteSessionRailShouldCollapse(24, 0)).assertTrue();
      expect(remoteSessionRailShouldCollapse(4, 800)).assertTrue();
      expect(remoteSessionRailShouldCollapse(12, 200)).assertFalse();
    });

    it('phone_and_pad_keyboard_mouse_sessions_should_use_edge_rail', 0, (): void => {
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'sm', 2, false)).assertTrue();
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'lg', 2, true)).assertTrue();
    });

    it('pad_virtual_touchpad_should_share_the_keyboard_mouse_edge_rail', 0, (): void => {
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'lg', 0, true)).assertTrue();
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'md', 0, true)).assertTrue();
    });

    it('phone_and_pad_should_keep_the_right_rail_in_every_control_mode', 0, (): void => {
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'sm', 0, false)).assertTrue();
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'sm', 1, false)).assertTrue();
      expect(shouldUseRustDeskEdgeRail('rustdesk', false, 'lg', 1, true)).assertTrue();
      expect(shouldUseRustDeskEdgeRail('rustdesk', true, 'xl', 2, false)).assertFalse();
      expect(shouldUseRustDeskEdgeRail('rdp', false, 'sm', 2, false)).assertFalse();
      expect(shouldUseRemoteSessionEdgeRail('rdp', false)).assertFalse();
      expect(shouldUseRemoteSessionEdgeRail('rustdesk', false)).assertTrue();
      expect(shouldUseRemoteSessionEdgeRail('rdp', true)).assertFalse();
    });
  });

  describe('RemoteSessionTopBarPolicy_actions', (): void => {
    it('pc_top_bar_and_mobile_rail_share_one_ordered_action_contract', 0, (): void => {
      const actions = remoteSessionPrimaryActionIds('rustdesk');
      expect(actions.length).assertEqual(8);
      expect(actions.join(',')).assertEqual(
        'pin,control,display,keyboardMouse,keyboard,fileTransfer,diagnostics,disconnect');
      expect(remoteSessionPrimaryActionIds('rdp').length).assertEqual(0);
    });

    it('existing_actions_should_be_enabled', 0, (): void => {
      expect(rustDeskActionAvailability('disconnect').enabled).assertTrue();
      expect(rustDeskActionAvailability('refreshFrame').enabled).assertTrue();
      expect(rustDeskActionAvailability('fileTransfer').enabled).assertTrue();
      expect(rustDeskActionAvailability('ctrlAltDel').enabled).assertTrue();
      expect(rustDeskActionAvailability('rotateDisplay').enabled).assertTrue();
      expect(rustDeskActionAvailability('diagnostics').enabled).assertTrue();
    });

    it('unwired_official_actions_should_be_disabled_with_reason', 0, (): void => {
      const chat = rustDeskActionAvailability('textChat');
      expect(chat.enabled).assertFalse();
      expect(chat.reason.length > 0).assertTrue();
      const record = rustDeskActionAvailability('recordSession');
      expect(record.enabled).assertFalse();
      expect(record.reason.length > 0).assertTrue();
    });

    it('visible_unwired_actions_should_not_be_clickable_noops', 0, (): void => {
      const screenshot = rustDeskActionAvailability('screenshot');
      expect(screenshot.enabled).assertFalse();
      expect(screenshot.reason.length > 0).assertTrue();
      expect(rustDeskActionAvailability('resolutionSettings').enabled).assertFalse();
      expect(rustDeskActionAvailability('virtualDisplay').enabled).assertFalse();
      expect(rustDeskActionAvailability('lockRemote').enabled).assertFalse();
    });

    it('browse_mode_should_be_enabled_as_local_input_guard', 0, (): void => {
      expect(rustDeskActionAvailability('browseMode').enabled).assertTrue();
    });
  });

  describe('RemoteSessionTopBarPolicy_autoCollapse', (): void => {
    it('unpinned_toolbar_should_auto_collapse_when_no_menu_open', 0, (): void => {
      expect(rustDeskTopBarAutoCollapseDelayMs(false, false)).assertEqual(5000);
    });

    it('pinned_toolbar_or_open_menu_should_not_auto_collapse', 0, (): void => {
      expect(rustDeskTopBarAutoCollapseDelayMs(true, false)).assertEqual(0);
      expect(rustDeskTopBarAutoCollapseDelayMs(false, true)).assertEqual(0);
      expect(rustDeskTopBarAutoCollapseDelayMs(true, true)).assertEqual(0);
    });
  });

  describe('RemoteSessionTopBarPolicy_preferences', (): void => {
    it('rustdesk_keys_should_not_be_owned_by_rdp', 0, (): void => {
      expect(protocolPreferenceOwner('rustdeskImageQuality')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskCodec')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskControlMode')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskClipboardEnabled')).assertEqual('rustdesk');
    });

    it('new_runtime_rustdesk_keys_should_be_rustdesk_owned', 0, (): void => {
      expect(protocolPreferenceOwner('rustdeskFilePasteEnabled')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskClipboardEnabled')).assertEqual('rustdesk');
    });

    it('keyboard_mouse_runtime_keys_should_be_rustdesk_owned', 0, (): void => {
      expect(protocolPreferenceOwner('rustdeskViewScaleMode')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskShowLocalCursor')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskBrowseMode')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskRelativeMouseMode')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskReverseWheel')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskSwapMouseButtons')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskTouchpadSpeed')).assertEqual('rustdesk');
    });

    it('rdp_keys_should_not_be_owned_by_rustdesk', 0, (): void => {
      expect(protocolPreferenceOwner('rdpDesktopPreset')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpColorDepth')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpControlMode')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpClipboardEnabled')).assertEqual('rdp');
    });

    it('shared_visual_keys_should_be_shared', 0, (): void => {
      expect(protocolPreferenceOwner('currentTheme')).assertEqual('shared');
      expect(protocolPreferenceOwner('accentColor')).assertEqual('shared');
    });
  });
  });
}
