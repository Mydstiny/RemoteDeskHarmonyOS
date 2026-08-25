import { describe, it, expect } from '@ohos/hypium';
import { MoonlightAppCacheEntry, moonlightAppCacheIdentity } from '../main/ets/model/MoonlightAppCache';
import { MoonlightProfile } from '../main/ets/model/MoonlightModels';
import {
  MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS,
  MOONLIGHT_CONNECT_DURATION_DELAY_MS,
  MOONLIGHT_CONNECT_STAGE_DELAY_MS,
  createMoonlightCatalogOperationKey,
  filterMoonlightCatalogItems,
  moonlightCatalogHostReachable,
  moonlightAppRouteParams,
  moonlightCatalogItems,
  moonlightCatalogOperationIsCurrent,
  moonlightCatalogPresentation,
  moonlightCatalogSheetHeight,
  moonlightCatalogGridColumnCount,
  moonlightConnectStagePresentation,
  moonlightConnectSheetMountReady,
  moonlightAdaptiveControlModeForSource,
  moonlightInitialAdaptiveControlMode,
  moonlightPhysicalKeyboardCaptureEnabled,
  moonlightResolvedControlMode,
  moonlightSystemKeyReserved,
  moonlightHostRouteParams,
  moonlightLaunchPreflight,
  moonlightMetric,
  moonlightMetricPairUs,
  moonlightOverlayRequiresInputFlush,
  moonlightRecoverySheetDismissAllowed,
  moonlightRouteIdentity,
  moonlightTouchCancelPlan,
  moonlightSettingsSections,
  moonlightControlCenterLayout,
  moonlightToolbarAutoHideDelayMs,
  moonlightToolbarDeviceClass,
  moonlightToolbarLayout,
  moonlightToolbarItems,
  moonlightUsesEntryAbilityImmersiveBars,
  shouldDeferMoonlightDisappear
} from '../main/ets/services/MoonlightUiPolicy';

function entry(appId: string, title: string, available: boolean = true,
  expiresAt: number = 1000): MoonlightAppCacheEntry {
  const value = new MoonlightAppCacheEntry();
  value.userId = 'owner-1';
  value.hostId = 'host-1';
  value.appId = appId;
  value.id = moonlightAppCacheIdentity(value.userId, value.hostId, appId);
  value.title = title;
  value.available = available;
  value.expiresAt = expiresAt;
  value.lastCatalogAt = 100;
  value.lastAccessedAt = 100;
  value.sizeBytes = 0;
  return value;
}

function profile(appId: string, favorite: boolean): MoonlightProfile {
  return {
    id: 'profile-' + appId, hostId: 'host-1', appId: appId,
    titleSnapshot: appId, streamOverrides: {}, inputOverrides: {},
    favorite: favorite, userOrder: favorite ? 0 : 10, lastUsedAt: 0
  };
}

export default function moonlightUiPolicyTest(): void {
  describe('MoonlightUiPolicy', (): void => {
    it('routes_only_stable_ids_without_snapshots_or_secrets', 0, (): void => {
      const host = moonlightHostRouteParams(' host-1 ');
      expect(host !== null).assertTrue();
      expect(Object.keys(host as Record<string, Object>).length).assertEqual(1);
      expect(moonlightRouteIdentity(host, false).valid).assertTrue();
      const app = moonlightAppRouteParams('host-1', 'app-1');
      expect(app !== null).assertTrue();
      expect(Object.keys(app as Record<string, Object>).length).assertEqual(2);
      expect(moonlightRouteIdentity(app, true).valid).assertTrue();
      expect(moonlightHostRouteParams('')).assertNull();
      expect(moonlightAppRouteParams('host-1', '')).assertNull();
    });

    it('fences_catalog_callbacks_by_owner_host_and_generation', 0, (): void => {
      const current = createMoonlightCatalogOperationKey('owner-1', 'host-1', 2);
      expect(moonlightCatalogOperationIsCurrent(current,
        createMoonlightCatalogOperationKey('owner-1', 'host-1', 2))).assertTrue();
      expect(moonlightCatalogOperationIsCurrent(current,
        createMoonlightCatalogOperationKey('owner-2', 'host-1', 2))).assertFalse();
      expect(moonlightCatalogOperationIsCurrent(current,
        createMoonlightCatalogOperationKey('owner-1', 'host-1', 3))).assertFalse();
    });

    it('projects_favorites_first_and_preserves_unavailable_and_stale_apps', 0, (): void => {
      const items = moonlightCatalogItems([
        entry('a', 'Desktop', true, 50), entry('b', 'Steam', false, 1000),
        entry('c', 'Game', true, 1000)
      ], [profile('c', true), profile('b', false)], 100);
      expect(items.length).assertEqual(3);
      expect(items[0].appId).assertEqual('c');
      expect(items[1].stale || !items[1].available).assertTrue();
      expect(filterMoonlightCatalogItems(items, 'des', 'all').length).assertEqual(1);
      expect(filterMoonlightCatalogItems(items, '', 'unavailable').length).assertEqual(2);
    });

    it('keeps_previous_catalog_for_offline_partial_busy_and_read_failure', 0, (): void => {
      expect(moonlightCatalogPresentation(3, 0, 0, false, false, false, false, false)
        .preservesPreviousCatalog).assertTrue();
      expect(moonlightCatalogPresentation(3, 0, 1, true, false, false, false, true)
        .status).assertEqual('partial');
      expect(moonlightCatalogPresentation(3, 0, 0, true, false, true, false, false)
        .status).assertEqual('host_busy');
      expect(moonlightCatalogPresentation(3, 0, 0, true, false, false, true, false)
        .status).assertEqual('stale');
      expect(moonlightCatalogPresentation(0, 0, 0, true, false, false, true, false)
        .status).assertEqual('error');
    });

    it('sizes_catalog_sheet_to_visible_rows_and_caps_large_catalogs', 0, (): void => {
      expect(moonlightCatalogSheetHeight(0, 2, 65)).assertEqual(474);
      expect(moonlightCatalogSheetHeight(2, 2, 65)).assertEqual(608);
      expect(moonlightCatalogSheetHeight(3, 2, 65)).assertEqual(780);
      expect(moonlightCatalogSheetHeight(40, 2, 65)).assertEqual(780);
      expect(moonlightCatalogSheetHeight(3, 3, 0)).assertEqual(543);
    });

    it('keeps embedded Pad catalogs within the native Sheet width', 0, (): void => {
      expect(moonlightCatalogGridColumnCount('lg', true, 2)).assertEqual(2);
      expect(moonlightCatalogGridColumnCount('xl', true, 1)).assertEqual(1);
      expect(moonlightCatalogGridColumnCount('lg', true, 8)).assertEqual(2);
      expect(moonlightCatalogGridColumnCount('lg', false, 2)).assertEqual(4);
    });

    it('keeps_host_online_when_catalog_reached_sunshine_but_cache_or_payload_failed', 0,
      (): void => {
        expect(moonlightCatalogHostReachable(
          'cache_failed', 'catalog', 'confirmed', 0)).assertTrue();
        expect(moonlightCatalogHostReachable(
          'invalid_catalog', 'catalog', 'confirmed', 1)).assertTrue();
        expect(moonlightCatalogHostReachable(
          'invalid_catalog', 'catalog', 'confirmed', 0)).assertFalse();
        expect(moonlightCatalogHostReachable(
          'host_busy', 'catalog', 'confirmed', 0)).assertFalse();
        expect(moonlightCatalogHostReachable(
          'transport_failure', 'catalog', 'confirmed', 0)).assertFalse();
        expect(moonlightCatalogHostReachable(
          'deadline_exceeded', 'catalog', 'confirmed', 0)).assertFalse();
        expect(moonlightCatalogHostReachable(
          'ok', 'catalog', 'failed', 0)).assertFalse();
        expect(moonlightCatalogHostReachable(
          'ok', 'launch', 'confirmed', 0)).assertFalse();
        expect(moonlightCatalogPresentation(2, 0, 0,
          moonlightCatalogHostReachable(
            'invalid_catalog', 'catalog', 'confirmed', 1),
          false, false, false, true).status).assertEqual('partial');
      });

    it('fails_closed_before_runtime_and_prioritizes_security_blockers', 0, (): void => {
      const blocked = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: true, certificateChanged: false,
        identityAvailable: true, appAvailable: true, meteredNetwork: false,
        meteredAllowed: true, hostBusy: false, activeSession: false,
        runtimeAvailable: false, adjustmentCount: 0
      });
      expect(blocked.allowed).assertFalse();
      expect(blocked.blocker).assertEqual('runtime_unavailable');
      const changed = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: true, certificateChanged: true,
        identityAvailable: false, appAvailable: true, meteredNetwork: false,
        meteredAllowed: true, hostBusy: false, activeSession: false,
        runtimeAvailable: true, adjustmentCount: 0
      });
      expect(changed.blocker).assertEqual('certificate_changed');
      const offline = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: false, certificateChanged: false,
        identityAvailable: true, appAvailable: true, meteredNetwork: true,
        meteredAllowed: false, hostBusy: false, activeSession: false,
        runtimeAvailable: true, adjustmentCount: 0
      });
      expect(offline.blocker).assertEqual('host_unavailable');
      expect(offline.detail).assertEqual('主机当前不可用，请刷新目录后重试。');
      expect(offline.canRetry).assertTrue();
    });

    it('blocks_metered_launch_until_the_saved_policy_or_one_time_approval_allows_it', 0, (): void => {
      const denied = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: true, certificateChanged: false,
        identityAvailable: true, appAvailable: true, meteredNetwork: true,
        meteredAllowed: false, hostBusy: false, activeSession: false,
        runtimeAvailable: true, adjustmentCount: 0
      });
      expect(denied.allowed).assertFalse();
      expect(denied.blocker).assertEqual('metered_denied');
      const approved = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: true, certificateChanged: false,
        identityAvailable: true, appAvailable: true, meteredNetwork: true,
        meteredAllowed: true, hostBusy: false, activeSession: false,
        runtimeAvailable: true, adjustmentCount: 0
      });
      expect(approved.allowed).assertTrue();
      expect(approved.blocker).assertEqual('none');
    });

    it('blocks_launch_while_sunshine_reports_an_active_host_session', 0, (): void => {
      const busy = moonlightLaunchPreflight({
        routeValid: true, hostAvailable: true, certificateChanged: false,
        identityAvailable: true, appAvailable: true, meteredNetwork: false,
        meteredAllowed: true, hostBusy: true, activeSession: false,
        runtimeAvailable: true, adjustmentCount: 0
      });
      expect(busy.allowed).assertFalse();
      expect(busy.blocker).assertEqual('host_busy');
    });

    it('uses_400ms_3s_10s_connect_stage_thresholds_and_never_preclaims_connected', 0, (): void => {
      expect(moonlightConnectStagePresentation('negotiating',
        MOONLIGHT_CONNECT_STAGE_DELAY_MS - 1, false).visible).assertFalse();
      expect(moonlightConnectStagePresentation('negotiating',
        MOONLIGHT_CONNECT_STAGE_DELAY_MS, false).visible).assertTrue();
      expect(moonlightConnectStagePresentation('video',
        MOONLIGHT_CONNECT_DURATION_DELAY_MS, false).showElapsed).assertTrue();
      expect(moonlightConnectStagePresentation('video',
        MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS, false).showDiagnostics).assertTrue();
      expect(moonlightConnectStagePresentation('streaming', 12000, true).visible).assertFalse();
      const disconnected = moonlightConnectStagePresentation('disconnected', 0, false);
      expect(disconnected.visible).assertTrue();
      expect(disconnected.title).assertEqual('连接已结束');
      expect(disconnected.detail).assertEqual('连接已停止，可返回应用目录。');
    });

    it('keeps_disconnect_dangerous_and_physical_controller_management_reachable', 0,
      (): void => {
      const phone = moonlightToolbarItems('sm', true, false, true);
      expect(phone.length).assertEqual(8);
      expect(phone[1].action).assertEqual('keyboard');
      expect(phone[1].enabled).assertFalse();
      expect(phone[2].action).assertEqual('modifiers');
      expect(phone[2].enabled).assertTrue();
      expect(phone[3].action).assertEqual('controller');
      expect(phone[3].enabled).assertTrue();
      expect(phone[3].disabledReason).assertEqual('');
      expect(phone[4].action).assertEqual('display');
      expect(phone[5].action).assertEqual('diagnostics');
      expect(phone[5].label).assertEqual('性能');
      expect(phone[7].action).assertEqual('disconnect');
      expect(phone[7].label).assertEqual('退出');
      expect(phone[7].dangerous).assertTrue();
      const adaptive = moonlightToolbarItems(
        'sm', true, true, true, 7, true, '自适应·键鼠');
      expect(adaptive[0].label).assertEqual('自适应·键鼠');
      const keyboardMouse = moonlightToolbarItems('sm', true, true, true, 7, true, '键鼠');
      expect(keyboardMouse[0].label).assertEqual('键鼠');
      const touchpad = moonlightToolbarItems('sm', true, true, true, 7, true, '触控板');
      expect(touchpad[0].label).assertEqual('触控板');
      const keyboardReady = moonlightToolbarItems('sm', true, false, true, 7, true);
      expect(keyboardReady[1].action).assertEqual('keyboard');
      expect(keyboardReady[1].enabled).assertTrue();
      expect(keyboardReady[1].disabledReason).assertEqual('');
      expect(moonlightToolbarItems('xl', true, true, true).length).assertEqual(9);
    });

    it('defers_connected_page_disappear_until_background_signal_is_classified', 0, (): void => {
      expect(shouldDeferMoonlightDisappear(false, true, false)).assertTrue();
      expect(shouldDeferMoonlightDisappear(true, true, false)).assertFalse();
      expect(shouldDeferMoonlightDisappear(false, false, false)).assertFalse();
      expect(shouldDeferMoonlightDisappear(false, true, true)).assertFalse();
    });

    it('mounts_connect_sheet_only_after_the_final_surface_layout_is_ready', 0,
      (): void => {
        expect(moonlightConnectSheetMountReady(true, false)).assertFalse();
        expect(moonlightConnectSheetMountReady(true, true)).assertTrue();
        expect(moonlightConnectSheetMountReady(false, true)).assertFalse();
      });

    it('keeps_pad_and_pc_physical_keyboard_enabled_and_separates_immersive_owners', 0,
      (): void => {
        expect(moonlightPhysicalKeyboardCaptureEnabled(false, false, false, '')).assertFalse();
        expect(moonlightPhysicalKeyboardCaptureEnabled(
          false, false, false, '', 'adaptive')).assertTrue();
        expect(moonlightPhysicalKeyboardCaptureEnabled(
          false, false, false, '', 'keyboardMouse')).assertTrue();
        expect(moonlightPhysicalKeyboardCaptureEnabled(
          false, false, false, '', 'trackpad')).assertFalse();
        expect(moonlightPhysicalKeyboardCaptureEnabled(true, false, false, '')).assertTrue();
        expect(moonlightPhysicalKeyboardCaptureEnabled(false, true, false, '')).assertTrue();
        expect(moonlightPhysicalKeyboardCaptureEnabled(false, false, true, '')).assertTrue();
        expect(moonlightPhysicalKeyboardCaptureEnabled(
          false, false, false, 'moonlight-window')).assertTrue();
        expect(moonlightUsesEntryAbilityImmersiveBars(false, '')).assertTrue();
        expect(moonlightUsesEntryAbilityImmersiveBars(true, '')).assertFalse();
        expect(moonlightUsesEntryAbilityImmersiveBars(
          false, 'moonlight-window')).assertFalse();
      });

    it('resolves_adaptive_input_from_device_class_and_latest_real_source', 0,
      (): void => {
        expect(moonlightInitialAdaptiveControlMode(false, false, '')).assertEqual('trackpad');
        expect(moonlightInitialAdaptiveControlMode(true, false, '')).assertEqual('keyboardMouse');
        expect(moonlightInitialAdaptiveControlMode(false, true, '')).assertEqual('keyboardMouse');
        expect(moonlightInitialAdaptiveControlMode(
          false, false, 'moonlight-window')).assertEqual('keyboardMouse');

        expect(moonlightAdaptiveControlModeForSource(
          'adaptive', 'keyboardMouse', 'touch')).assertEqual('trackpad');
        expect(moonlightAdaptiveControlModeForSource(
          'adaptive', 'trackpad', 'mouse')).assertEqual('keyboardMouse');
        expect(moonlightAdaptiveControlModeForSource(
          'adaptive', 'trackpad', 'touchpad')).assertEqual('keyboardMouse');
        expect(moonlightAdaptiveControlModeForSource(
          'adaptive', 'trackpad', 'keyboard')).assertEqual('keyboardMouse');
        expect(moonlightAdaptiveControlModeForSource(
          'adaptive', 'trackpad', 'unknown')).assertEqual('trackpad');
        expect(moonlightAdaptiveControlModeForSource(
          'keyboardMouse', 'trackpad', 'touch')).assertEqual('keyboardMouse');
        expect(moonlightAdaptiveControlModeForSource(
          'trackpad', 'keyboardMouse', 'mouse')).assertEqual('trackpad');
        expect(moonlightResolvedControlMode('adaptive', 'trackpad')).assertEqual('trackpad');
        expect(moonlightResolvedControlMode(
          'keyboardMouse', 'trackpad')).assertEqual('keyboardMouse');
      });

    it('keeps_back_lifecycle_and_disabled_system_shortcuts_local', 0, (): void => {
      expect(moonlightSystemKeyReserved(2)).assertTrue();
      expect(moonlightSystemKeyReserved(1)).assertTrue();
      expect(moonlightSystemKeyReserved(18)).assertTrue();
      expect(moonlightSystemKeyReserved(16)).assertTrue();
      expect(moonlightSystemKeyReserved(2049, true)).assertTrue();
      expect(moonlightSystemKeyReserved(2093, true)).assertTrue();
      expect(moonlightSystemKeyReserved(2070, false, true)).assertTrue();
      expect(moonlightSystemKeyReserved(2024)).assertFalse();
      expect(moonlightSystemKeyReserved(
        16, false, false, false, true)).assertFalse();
      // Local session lifecycle keys remain reserved even if a future build
      // enables forwarding of ordinary system shortcuts.
      expect(moonlightSystemKeyReserved(
        2, false, false, false, true)).assertTrue();
    });

    it('resolves_responsive_toolbar_and_control_center_contract', 0, (): void => {
      expect(moonlightToolbarDeviceClass(false, false)).assertEqual('phone');
      const phone = moonlightToolbarLayout(false, 'sm', false);
      expect(phone.edgeRail).assertTrue();
      expect(phone.maxVisibleItems).assertEqual(7);
      expect(phone.autoHideMs).assertEqual(0);
      expect(phone.maxHeight).assertEqual(420);

      const phoneLandscape = moonlightToolbarLayout(false, 'xl', false);
      expect(phoneLandscape.edgeRail).assertTrue();
      expect(phoneLandscape.maxVisibleItems).assertEqual(7);

      const padMd = moonlightToolbarLayout(false, 'md', true);
      expect(padMd.deviceClass).assertEqual('pad');
      expect(padMd.edgeRail).assertTrue();
      expect(padMd.maxHeight).assertEqual(420);
      expect(moonlightToolbarLayout(false, 'xl', true).edgeRail).assertTrue();

      const desktopMd = moonlightToolbarLayout(true, 'md', false);
      expect(desktopMd.deviceClass).assertEqual('pc');
      expect(desktopMd.edgeRail).assertFalse();
      expect(moonlightToolbarItems('md', true, false, false, desktopMd.maxVisibleItems).length)
        .assertEqual(8);

      const desktopXl = moonlightToolbarLayout(true, 'xl', false);
      expect(desktopXl.maxVisibleItems).assertEqual(8);
      expect(desktopXl.maxHeight).assertEqual(0);
      expect(moonlightToolbarAutoHideDelayMs(desktopXl, false)).assertEqual(5000);
      expect(moonlightToolbarAutoHideDelayMs(desktopXl, true)).assertEqual(0);
      expect(moonlightToolbarAutoHideDelayMs(desktopXl, false, true)).assertEqual(0);

      const sheet = moonlightControlCenterLayout(true, 'xl', false);
      expect(sheet.width).assertEqual('620vp');
      expect(sheet.rowHeight).assertEqual(68);

      const desktopLg = moonlightToolbarLayout(true, 'lg', false);
      expect(desktopLg.edgeRail).assertFalse();
      expect(desktopLg.maxVisibleItems).assertEqual(8);
      expect(moonlightToolbarAutoHideDelayMs(desktopLg, false)).assertEqual(0);
    });

    it('reconciles_auto_hide_when_sheet_or_breakpoint_changes', 0, (): void => {
      const desktopXl = moonlightToolbarLayout(true, 'xl', false);
      const desktopLg = moonlightToolbarLayout(true, 'lg', false);
      // Opening the control sheet cancels an existing 5-second hide timer;
      // closing it re-arms the timer only when the current layout is xl.
      expect(moonlightToolbarAutoHideDelayMs(desktopXl, false, true)).assertEqual(0);
      expect(moonlightToolbarAutoHideDelayMs(desktopXl, false, false)).assertEqual(5000);
      // A breakpoint change to lg has no automatic hide timer to carry over.
      expect(moonlightToolbarAutoHideDelayMs(desktopLg, false, false)).assertEqual(0);
      expect(moonlightToolbarAutoHideDelayMs(desktopLg, false, true)).assertEqual(0);
    });

    it('flushes_input_for_interactive_and_transaction_overlays', 0, (): void => {
      expect(moonlightOverlayRequiresInputFlush(2)).assertFalse();
      expect(moonlightOverlayRequiresInputFlush(3)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(4)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(5)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(6)).assertFalse();
    });

    it('cancels_every_tracked_contact_when_harmony_reports_only_one_changed_touch', 0,
      (): void => {
        const partial = moonlightTouchCancelPlan([1, 2], [1], true);
        expect(partial.cancelTrackedIds.length).assertEqual(2);
        expect(partial.cancelTrackedIds[0]).assertEqual(1);
        expect(partial.cancelTrackedIds[1]).assertEqual(2);
        expect(partial.clearAllLocalContacts).assertTrue();

        const suspended = moonlightTouchCancelPlan([1, 2], [1], false);
        expect(suspended.cancelTrackedIds.length).assertEqual(0);
        expect(suspended.clearAllLocalContacts).assertTrue();
      });

    it('fences_every_interactive_recovery_sheet_dismissal_while_resume_is_in_flight', 0,
      (): void => {
        // Back, mask taps and swipe-to-dismiss all enter the same native
        // onWillDismiss callback and must remain blocked until resume settles.
        expect(moonlightRecoverySheetDismissAllowed(true)).assertFalse();
        expect(moonlightRecoverySheetDismissAllowed(false)).assertTrue();
      });

    it('defines_complete_settings_taxonomy_and_unavailable_metrics', 0, (): void => {
      expect(moonlightSettingsSections().length).assertEqual(7);
      expect(moonlightSettingsSections()[6]).assertEqual('data');
      expect(moonlightMetric(-1, ' ms')).assertEqual('—');
      expect(moonlightMetric(8.25, ' ms', 1)).assertEqual('8.3 ms');
      expect(moonlightMetricPairUs(-1, -1)).assertEqual('—');
      expect(moonlightMetricPairUs(8200, 13400)).assertEqual('8.2 / 13.4 ms');
    });
  });
}
