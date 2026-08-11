import { describe, it, expect } from '@ohos/hypium';
import { MoonlightAppCacheEntry, moonlightAppCacheIdentity } from '../main/ets/model/MoonlightAppCache';
import { MoonlightProfile } from '../main/ets/model/MoonlightModels';
import {
  MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS,
  MOONLIGHT_CONNECT_DURATION_DELAY_MS,
  MOONLIGHT_CONNECT_STAGE_DELAY_MS,
  createMoonlightCatalogOperationKey,
  filterMoonlightCatalogItems,
  moonlightAppRouteParams,
  moonlightCatalogItems,
  moonlightCatalogOperationIsCurrent,
  moonlightCatalogPresentation,
  moonlightConnectStagePresentation,
  moonlightHostRouteParams,
  moonlightLaunchPreflight,
  moonlightMetric,
  moonlightMetricPairUs,
  moonlightOverlayRequiresInputFlush,
  moonlightRouteIdentity,
  moonlightSettingsSections,
  moonlightToolbarItems
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

    it('keeps_disconnect_dangerous_and_controller_fail_closed', 0, (): void => {
      const phone = moonlightToolbarItems('sm', true, false, true);
      expect(phone.length).assertEqual(5);
      expect(phone[2].action).assertEqual('controller');
      expect(phone[2].enabled).assertFalse();
      expect(phone[4].action).assertEqual('disconnect');
      expect(phone[4].dangerous).assertTrue();
      expect(moonlightToolbarItems('xl', true, true, true).length).assertEqual(7);
    });

    it('flushes_input_for_interactive_and_transaction_overlays', 0, (): void => {
      expect(moonlightOverlayRequiresInputFlush(2)).assertFalse();
      expect(moonlightOverlayRequiresInputFlush(3)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(4)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(5)).assertTrue();
      expect(moonlightOverlayRequiresInputFlush(6)).assertFalse();
    });

    it('defines_complete_settings_taxonomy_and_unavailable_metrics', 0, (): void => {
      expect(moonlightSettingsSections().length).assertEqual(9);
      expect(moonlightMetric(-1, ' ms')).assertEqual('—');
      expect(moonlightMetric(8.25, ' ms', 1)).assertEqual('8.3 ms');
      expect(moonlightMetricPairUs(-1, -1)).assertEqual('—');
      expect(moonlightMetricPairUs(8200, 13400)).assertEqual('8.2 / 13.4 ms');
    });
  });
}
