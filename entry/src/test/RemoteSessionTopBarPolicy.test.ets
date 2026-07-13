import { describe, it, expect } from '@ohos/hypium';
import {
  protocolPreferenceOwner,
  remoteTopBarDeviceClass,
  remoteTopBarLayout,
  rustDeskTopBarAutoCollapseDelayMs,
  rustDeskActionAvailability,
  shouldShowRustDeskTopBar
} from '../main/ets/services/RemoteSessionTopBarPolicy';

export default function remoteSessionTopBarPolicyTest(): void {
  describe('RemoteSessionTopBarPolicy_visibility', (): void => {
    it('pc_rustdesk_should_show_on_small_window', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'md', 0)).assertTrue();
    });

    it('pc_rustdesk_should_show_on_full_window', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'xl', 0)).assertTrue();
    });

    it('phone_rustdesk_should_show_only_in_keyboard_mouse_mode', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 2)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 0)).assertFalse();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 1)).assertFalse();
    });

    it('pad_rustdesk_should_show_only_in_keyboard_mouse_mode', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 2)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 0)).assertFalse();
    });

    it('rdp_should_not_show_rustdesk_topbar', 0, (): void => {
      expect(shouldShowRustDeskTopBar('rdp', true, 'xl', 2)).assertFalse();
      expect(shouldShowRustDeskTopBar('rdp', false, 'sm', 2)).assertFalse();
    });
  });

  describe('RemoteSessionTopBarPolicy_layout', (): void => {
    it('device_class_should_prefer_desktop_device_over_breakpoint', 0, (): void => {
      expect(remoteTopBarDeviceClass(true, 'sm')).assertEqual('pc');
      expect(remoteTopBarDeviceClass(false, 'lg')).assertEqual('pad');
      expect(remoteTopBarDeviceClass(false, 'sm')).assertEqual('phone');
    });

    it('pc_small_window_layout_should_be_compact_but_not_mobile', 0, (): void => {
      const layout = remoteTopBarLayout(true, 'md');
      expect(layout.deviceClass).assertEqual('pc');
      expect(layout.iconSize).assertEqual(44);
      expect(layout.maxVisibleButtons).assertEqual(7);
    });

    it('phone_layout_should_limit_visible_buttons', 0, (): void => {
      const layout = remoteTopBarLayout(false, 'sm');
      expect(layout.deviceClass).assertEqual('phone');
      expect(layout.iconSize).assertEqual(40);
      expect(layout.maxVisibleButtons).assertEqual(5);
    });
  });

  describe('RemoteSessionTopBarPolicy_actions', (): void => {
    it('existing_actions_should_be_enabled', 0, (): void => {
      expect(rustDeskActionAvailability('disconnect').enabled).assertTrue();
      expect(rustDeskActionAvailability('refreshFrame').enabled).assertTrue();
      expect(rustDeskActionAvailability('fileTransfer').enabled).assertTrue();
      expect(rustDeskActionAvailability('ctrlAltDel').enabled).assertTrue();
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
}
