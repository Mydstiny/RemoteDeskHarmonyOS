import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY,
  REMOTE_SESSION_QUICK_EXIT_DISABLED_KEY,
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  REMOTE_SESSION_COLLAPSED_TOP_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_WIDTH,
  protocolPreferenceOwner,
  RemoteSessionBooleanPreferencePort,
  applyRemoteSessionControlBarPreferenceUpdate,
  commitRemoteSessionQuickExitPreference,
  protectRemoteSessionControlBarVisibility,
  remoteKeyboardSidebarAction,
  remoteKeyboardSurfaceOpen,
  remoteSessionControlBarHidden,
  remoteSessionControlBarSelectionSummary,
  remoteSessionInteractiveDismissAllowed,
  remoteSessionShortcutExitAllowed,
  resolveRemoteSessionQuickExitRestore,
  remoteSessionPrimaryActionIds,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse,
  rustDeskTopBarSubMenuForItem,
  reduceRustDeskTopBarSubMenuState,
  rustDeskTouchpadSpeedOptions,
  shouldOpenRustDeskTopBarSubMenu,
  shouldConsumeRemoteSessionBack,
  resolveRemoteSessionControlBarVisibility,
  remoteTopBarDeviceClass,
  remoteTopBarLayout,
  shouldShowRemoteSessionTopBar,
  shouldDismissRemoteSessionControlSheet,
  shouldUseRemoteSessionEdgeRail,
  rustDeskTopBarAutoCollapseDelayMs,
  rustDeskActionAvailability,
  shouldShowRustDeskTopBar,
  shouldUseRustDeskEdgeRail
} from '../main/ets/services/RemoteSessionTopBarPolicy';

class QuickExitPreferencePortFake implements RemoteSessionBooleanPreferencePort {
  private values: Map<string, boolean> = new Map<string, boolean>();
  private failPutKey: string = '';
  private failPutConsumed: boolean = false;
  private failFlushOnce: boolean = false;

  has(key: string): boolean { return this.values.has(key); }

  read(key: string, fallback: boolean): boolean {
    const value: boolean | undefined = this.values.get(key);
    return value === undefined ? fallback : value;
  }

  put(key: string, value: boolean): void {
    if (!this.failPutConsumed && this.failPutKey === key) {
      this.failPutConsumed = true;
      throw new Error('injected put failure');
    }
    this.values.set(key, value);
  }

  remove(key: string): void { this.values.delete(key); }

  flush(): void {
    if (this.failFlushOnce) {
      this.failFlushOnce = false;
      throw new Error('injected flush failure');
    }
  }

  seed(key: string, value: boolean): void { this.values.set(key, value); }
  failPutAt(key: string): void { this.failPutKey = key; }
  failNextFlush(): void { this.failFlushOnce = true; }
}

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

    it('session_control_bar_editor_merges_only_touched_protocols', 0, (): void => {
      const current = {
        rdpHidden: false, rustDeskHidden: true, vncHidden: false, moonlightHidden: true
      };
      const merged = applyRemoteSessionControlBarPreferenceUpdate(current, {
        values: {
          rdpHidden: true, rustDeskHidden: false, vncHidden: true, moonlightHidden: false
        },
        touched: {
          rdpHidden: true, rustDeskHidden: false, vncHidden: true, moonlightHidden: false
        }
      });
      expect(merged.rdpHidden).assertTrue();
      expect(merged.rustDeskHidden).assertTrue();
      expect(merged.vncHidden).assertTrue();
      expect(merged.moonlightHidden).assertTrue();
    });

    it('quick_exit_protection_forces_all_graphical_controls_visible_without_mutation', 0,
      (): void => {
        const stored = {
          rdpHidden: true, rustDeskHidden: false, vncHidden: true, moonlightHidden: true
        };
        const unprotected = protectRemoteSessionControlBarVisibility(stored, false);
        expect(unprotected.rdpHidden).assertTrue();
        expect(unprotected.rustDeskHidden).assertFalse();
        expect(unprotected.vncHidden).assertTrue();
        expect(unprotected.moonlightHidden).assertTrue();
        const protectedVisibility = protectRemoteSessionControlBarVisibility(stored, true);
        expect(protectedVisibility.rdpHidden).assertFalse();
        expect(protectedVisibility.rustDeskHidden).assertFalse();
        expect(protectedVisibility.vncHidden).assertFalse();
        expect(protectedVisibility.moonlightHidden).assertFalse();
        expect(stored.rdpHidden).assertTrue();
        expect(stored.vncHidden).assertTrue();
        expect(remoteSessionControlBarSelectionSummary(stored, true))
          .assertEqual('快捷退出已关闭 · 全部显示');
      });

    it('quick_exit_protection_consumes_back_only_for_an_active_session', 0, (): void => {
      expect(shouldConsumeRemoteSessionBack(true, true)).assertTrue();
      expect(shouldConsumeRemoteSessionBack(true, false)).assertFalse();
      expect(shouldConsumeRemoteSessionBack(false, true, true)).assertTrue();
      expect(shouldConsumeRemoteSessionBack(false, true, false)).assertFalse();
      expect(shouldConsumeRemoteSessionBack(false, false, true)).assertFalse();
    });

    it('quick_exit_protection_blocks_only_active_session_shortcuts', 0, (): void => {
      expect(remoteSessionShortcutExitAllowed(true, true)).assertFalse();
      expect(remoteSessionShortcutExitAllowed(true, false)).assertTrue();
      expect(remoteSessionShortcutExitAllowed(false, true)).assertTrue();
    });

    it('quick_exit_protection_blocks_native_sheet_gestures_but_not_explicit_actions', 0,
      (): void => {
        // RustDesk auth, RustDesk 2FA and VNC certificate Sheets all use this
        // policy because ArkUI routes interactive dismissal before page Back.
        expect(remoteSessionInteractiveDismissAllowed(true, true, false)).assertFalse();
        expect(remoteSessionInteractiveDismissAllowed(true, true, true)).assertTrue();
        expect(remoteSessionInteractiveDismissAllowed(true, false, false)).assertTrue();
        expect(remoteSessionInteractiveDismissAllowed(false, true, false)).assertTrue();
      });

    it('quick_exit_transaction_rolls_back_values_and_key_presence_after_put_failure', 0,
      (): void => {
        const port: QuickExitPreferencePortFake = new QuickExitPreferencePortFake();
        port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, true);
        port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, false);
        port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY, true);
        port.failPutAt(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY);

        expect(commitRemoteSessionQuickExitPreference(port, true)).assertFalse();
        expect(port.has(REMOTE_SESSION_QUICK_EXIT_DISABLED_KEY)).assertFalse();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, false)).assertTrue();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, true)).assertFalse();
        expect(port.has(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY)).assertFalse();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY, false)).assertTrue();
      });

    it('quick_exit_transaction_rolls_back_after_flush_failure', 0, (): void => {
      const port: QuickExitPreferencePortFake = new QuickExitPreferencePortFake();
      port.seed(REMOTE_SESSION_QUICK_EXIT_DISABLED_KEY, false);
      port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, true);
      port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, false);
      port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY, true);
      port.failNextFlush();

      expect(commitRemoteSessionQuickExitPreference(port, true)).assertFalse();
      expect(port.read(REMOTE_SESSION_QUICK_EXIT_DISABLED_KEY, true)).assertFalse();
      expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, false)).assertTrue();
      expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, true)).assertFalse();
      expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY, false)).assertTrue();
      expect(port.has(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY)).assertFalse();
    });

    it('quick_exit_transaction_commits_protection_and_all_visibility_invariants', 0,
      (): void => {
        const port: QuickExitPreferencePortFake = new QuickExitPreferencePortFake();
        port.seed(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, true);
        expect(commitRemoteSessionQuickExitPreference(port, true)).assertTrue();
        expect(port.read(REMOTE_SESSION_QUICK_EXIT_DISABLED_KEY, false)).assertTrue();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, true)).assertFalse();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, true)).assertFalse();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY, true)).assertFalse();
        expect(port.read(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY, true)).assertFalse();
      });

    it('direct_route_restore_uses_disk_when_readable_and_app_storage_when_not', 0,
      (): void => {
        const hidden = {
          rdpHidden: true, rustDeskHidden: true, vncHidden: true, moonlightHidden: true
        };
        const readable = resolveRemoteSessionQuickExitRestore(hidden, true, false, true);
        expect(readable.quickExitDisabled).assertFalse();
        expect(readable.visibility.rdpHidden).assertTrue();
        expect(readable.visibility.moonlightHidden).assertTrue();
        const failedRead = resolveRemoteSessionQuickExitRestore(hidden, false, false, true);
        expect(failedRead.quickExitDisabled).assertTrue();
        expect(failedRead.visibility.rdpHidden).assertFalse();
        expect(failedRead.visibility.rustDeskHidden).assertFalse();
        expect(failedRead.visibility.vncHidden).assertFalse();
        expect(failedRead.visibility.moonlightHidden).assertFalse();
      });

    it('hidden_control_bar_should_dismiss_only_an_open_control_sheet', 0, (): void => {
      expect(shouldDismissRemoteSessionControlSheet(true, true, 'control')).assertTrue();
      expect(shouldDismissRemoteSessionControlSheet(false, true, 'control')).assertFalse();
      expect(shouldDismissRemoteSessionControlSheet(true, false, 'control')).assertFalse();
      expect(shouldDismissRemoteSessionControlSheet(true, true, 'connect')).assertFalse();
      expect(shouldDismissRemoteSessionControlSheet(true, true, 'stop')).assertFalse();
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
      expect(layout.maxVisibleButtons).assertEqual(9);
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
      expect(remoteSessionRailDragOffset(90)).assertEqual(28);
      expect(remoteSessionRailShouldCollapse(24, 0)).assertTrue();
      expect(remoteSessionRailShouldCollapse(4, 800)).assertTrue();
      expect(remoteSessionRailShouldCollapse(12, 200)).assertFalse();
      expect(remoteSessionRailShouldCollapse(24, 0, 48)).assertFalse();
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
    it('every_multi_choice_toolbar_row_should_have_a_secondary_menu', 0, (): void => {
      expect(rustDeskTopBarSubMenuForItem('viewScale')).assertEqual('viewScale');
      expect(rustDeskTopBarSubMenuForItem('remoteDisplay')).assertEqual('remoteDisplay');
      expect(rustDeskTopBarSubMenuForItem('resolution')).assertEqual('resolution');
      expect(rustDeskTopBarSubMenuForItem('imageQuality')).assertEqual('imageQuality');
      expect(rustDeskTopBarSubMenuForItem('codec')).assertEqual('codec');
      expect(rustDeskTopBarSubMenuForItem('touchpadSpeed')).assertEqual('touchpadSpeed');
      expect(rustDeskTopBarSubMenuForItem('togglePrivacyMode')).assertEqual('');
      expect(rustDeskTopBarSubMenuForItem('refreshFrame')).assertEqual('');
    });

    it('secondary_choices_should_open_on_hover_or_click', 0, (): void => {
      expect(shouldOpenRustDeskTopBarSubMenu('codec', true, false)).assertTrue();
      expect(shouldOpenRustDeskTopBarSubMenu('codec', false, true)).assertTrue();
      expect(shouldOpenRustDeskTopBarSubMenu('codec', false, false)).assertFalse();
      expect(shouldOpenRustDeskTopBarSubMenu('', true, true)).assertFalse();
    });

    it('secondary_menu_state_should_separate_hover_preview_and_click_pin', 0, (): void => {
      let state = reduceRustDeskTopBarSubMenuState(
        { active: '', pinned: false }, 'codec', 'hover-enter');
      expect(state.active).assertEqual('codec');
      expect(state.pinned).assertFalse();
      state = reduceRustDeskTopBarSubMenuState(state, '', 'menu-leave');
      expect(state.active).assertEqual('');

      state = reduceRustDeskTopBarSubMenuState(state, 'codec', 'hover-enter');
      state = reduceRustDeskTopBarSubMenuState(state, 'codec', 'click');
      expect(state.active).assertEqual('codec');
      expect(state.pinned).assertTrue();
      const pinnedAfterLeave = reduceRustDeskTopBarSubMenuState(state, '', 'menu-leave');
      expect(pinnedAfterLeave.active).assertEqual('codec');
      state = reduceRustDeskTopBarSubMenuState(pinnedAfterLeave, 'codec', 'click');
      expect(state.active).assertEqual('');
      expect(state.pinned).assertFalse();
    });

    it('secondary_menu_state_should_switch_on_click_and_reset_at_boundaries', 0, (): void => {
      let state = reduceRustDeskTopBarSubMenuState(
        { active: 'codec', pinned: true }, 'imageQuality', 'click');
      expect(state.active).assertEqual('imageQuality');
      expect(state.pinned).assertTrue();
      state = reduceRustDeskTopBarSubMenuState(state, '', 'reset');
      expect(state.active).assertEqual('');
      expect(state.pinned).assertFalse();
    });

    it('touchpad_secondary_menu_should_cover_the_persisted_range', 0, (): void => {
      const speeds: number[] = rustDeskTouchpadSpeedOptions();
      expect(speeds.length).assertEqual(10);
      expect(speeds[0]).assertEqual(0.4);
      expect(speeds[3]).assertEqual(1.0);
      expect(speeds[9]).assertEqual(2.2);
      for (let index: number = 1; index < speeds.length; index++) {
        expect(Math.abs(speeds[index] - speeds[index - 1] - 0.2) < 0.001).assertTrue();
      }
    });

    it('keyboard_affordance_should_close_every_active_keyboard_surface', 0, (): void => {
      expect(remoteKeyboardSurfaceOpen(false, false, false)).assertFalse();
      expect(remoteKeyboardSurfaceOpen(true, false, false)).assertTrue();
      expect(remoteKeyboardSurfaceOpen(false, true, false)).assertTrue();
      expect(remoteKeyboardSurfaceOpen(false, false, true)).assertTrue();
      expect(remoteKeyboardSidebarAction(false, false, false)).assertEqual('choose');
      expect(remoteKeyboardSidebarAction(true, false, false)).assertEqual('close');
      expect(remoteKeyboardSidebarAction(false, true, false)).assertEqual('close');
      expect(remoteKeyboardSidebarAction(false, false, true)).assertEqual('close');
      expect(remoteKeyboardSidebarAction(true, true, true)).assertEqual('close');
    });

    it('pc_top_bar_adds_flip_without_changing_mobile_or_phone_target_rails', 0, (): void => {
      const pcActions = remoteSessionPrimaryActionIds('rustdesk', 'pc', false);
      expect(pcActions.length).assertEqual(9);
      expect(pcActions.join(',')).assertEqual(
        'pin,control,display,desktopFlip,keyboardMouse,keyboard,fileTransfer,diagnostics,disconnect');
      const mobileActions = remoteSessionPrimaryActionIds('rustdesk', 'phone', false);
      expect(mobileActions.length).assertEqual(8);
      expect(mobileActions.join(',')).assertEqual(
        'pin,control,display,keyboardMouse,keyboard,fileTransfer,diagnostics,disconnect');
      expect(remoteSessionPrimaryActionIds('rustdesk', 'pad', false).length).assertEqual(8);
      expect(remoteSessionPrimaryActionIds('rustdesk', 'pc', true).length).assertEqual(8);
      expect(remoteSessionPrimaryActionIds('rdp').length).assertEqual(0);
    });

    it('existing_actions_should_be_enabled', 0, (): void => {
      expect(rustDeskActionAvailability('disconnect').enabled).assertTrue();
      expect(rustDeskActionAvailability('refreshFrame').enabled).assertTrue();
      expect(rustDeskActionAvailability('fileTransfer').enabled).assertTrue();
      expect(rustDeskActionAvailability('ctrlAltDel').enabled).assertTrue();
      expect(rustDeskActionAvailability('rotateDisplay').enabled).assertTrue();
      expect(rustDeskActionAvailability('desktopFlip').enabled).assertTrue();
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
