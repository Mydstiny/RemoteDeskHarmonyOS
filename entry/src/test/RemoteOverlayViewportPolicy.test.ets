import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  OverlayPlacement,
  OverlayPlacementRequest,
  OverlayRect,
  OverlaySide,
  OverlayViewport,
  emptyOverlayPlacement,
  normalizeOverlayYRatio,
  overlayPositionPreferenceKey,
  resolveOverlayDragPreference,
  resolveOverlayAuxiliaryRect,
  resolveOverlayPlacement
} from '../main/ets/services/RemoteOverlayViewportPolicy';
import { RemoteOverlayRegistry } from '../main/ets/services/RemoteOverlayRegistry';

function viewport(deviceClass: 'pc' | 'pad' | 'phone', generation: number = 1): OverlayViewport {
  return {
    width: 1000,
    height: 800,
    systemTop: 24,
    systemBottom: 28,
    systemLeft: 12,
    systemRight: 12,
    cutoutRects: [],
    keyboardRect: null,
    orientation: 'landscape',
    deviceClass,
    occupiedRects: [],
    generation
  };
}

function request(ownerId: string = 'session-rail'): OverlayPlacementRequest {
  const preferredSide: OverlaySide = 'right';
  return {
    ownerId,
    preferredSide,
    yRatio: 0.5,
    handleSize: 44,
    railWidth: 64,
    railHeight: 300,
    menuWidth: 280,
    menuHeight: 360,
    expanded: true
  };
}

export default function remoteOverlayViewportPolicyTest(
  scope: 'all' | 'viewport' | 'registry' = 'all'): void {
  if (scope === 'all' || scope === 'viewport') {
  describe('RemoteOverlayViewportPolicy_contract', (): void => {
    it('keeps_pc_overlay_top_centered_and_menu_downward', 0, (): void => {
      const result: OverlayPlacement = resolveOverlayPlacement(viewport('pc'), request());
      expect(result.railRect.y).assertEqual(24);
      expect(result.railRect.x).assertEqual(468);
      expect(result.expandedRect.x).assertEqual(result.railRect.x);
      expect(result.menuDirection).assertEqual('down');
      expect(result.fallback).assertEqual('none');
    });

    it('defaults_phone_and_pad_to_right_middle_and_preserves_saved_side_ratio', 0, (): void => {
      const phone: OverlayPlacement = resolveOverlayPlacement(viewport('phone'), request());
      expect(phone.side).assertEqual('right');
      expect(phone.railRect.y).assertEqual(248);

      const leftRequest = request();
      leftRequest.preferredSide = 'left';
      leftRequest.yRatio = 0.8;
      const pad: OverlayPlacement = resolveOverlayPlacement(viewport('pad'), leftRequest);
      expect(pad.side).assertEqual('left');
      expect(pad.railRect.x).assertEqual(12);
      expect(pad.railRect.y).assertEqual(382);
      expect(normalizeOverlayYRatio(-1)).assertEqual(0);
      expect(normalizeOverlayYRatio(2)).assertEqual(1);
      expect(overlayPositionPreferenceKey('phone', 'portrait', 'side'))
        .assertEqual('remoteSessionRail:phone:portrait:side');
      expect(overlayPositionPreferenceKey('pad', 'landscape', 'yRatio'))
        .assertEqual('remoteSessionRail:pad:landscape:yRatio');
    });

    it('keeps_handle_at_least_44_and_avoids_keyboard_cutout_and_insets', 0, (): void => {
      const v = viewport('phone');
      v.cutoutRects = [{ x: 900, y: 24, width: 100, height: 180 }];
      v.keyboardRect = { x: 0, y: 560, width: 1000, height: 240 };
      const result: OverlayPlacement = resolveOverlayPlacement(v, request());
      expect(result.handleRect.width >= 44).assertTrue();
      expect(result.handleRect.height >= 44).assertTrue();
      expect(result.railRect.y + result.railRect.height <= 560).assertTrue();
      const cutout: OverlayRect = v.cutoutRects[0];
      const railIntersectsCutout: boolean = result.railRect.x < cutout.x + cutout.width &&
        result.railRect.x + result.railRect.width > cutout.x &&
        result.railRect.y < cutout.y + cutout.height &&
        result.railRect.y + result.railRect.height > cutout.y;
      expect(railIntersectsCutout).assertFalse();
      expect(result.railRect.y >= 24).assertTrue();
    });

    it('persists_drag_side_and_clamps_ratio_to_real_keyboard_boundary', 0, (): void => {
      const v = viewport('phone');
      v.keyboardRect = { x: 0, y: 560, width: 1000, height: 240 };
      const placement: OverlayPlacement = resolveOverlayPlacement(v, request());
      const moved = resolveOverlayDragPreference(v, placement, -1200, 1200);
      expect(moved.side).assertEqual('left');
      expect(moved.yRatio <= 560 / 800).assertTrue();
      const movedUp = resolveOverlayDragPreference(v, placement, 1200, -1200);
      expect(movedUp.side).assertEqual('right');
      expect(movedUp.yRatio >= 24 / 800).assertTrue();
    });

    it('tries_the_other_side_when_occupied_rect_blocks_preferred_side', 0, (): void => {
      const v = viewport('phone');
      v.occupiedRects = [{ x: 924, y: 250, width: 64, height: 300 }];
      const result: OverlayPlacement = resolveOverlayPlacement(v, request());
      expect(result.side).assertEqual('left');
      expect(result.fallback).assertEqual('none');
    });

    it('uses_bottom_sheet_fallback_when_no_safe_inward_menu_exists', 0, (): void => {
      const v = viewport('phone');
      v.occupiedRects = [
        { x: 0, y: 24, width: 1000, height: 776 }
      ];
      const result: OverlayPlacement = resolveOverlayPlacement(v, request());
      expect(result.fallback).assertEqual('hidden');
      expect(result.recovery).assertEqual('retry-after-resize');
      expect(result.railRect.width).assertEqual(0);
      expect(result.handleRect.width).assertEqual(0);
      expect(result.menuRect.width).assertEqual(0);
      expect(result.railRect.x + result.railRect.width <= v.width).assertTrue();
      expect(result.handleRect.x + result.handleRect.width <= v.width).assertTrue();
    });

    it('keeps_resolved_menu_rect_inside_keyboard_and_occupied_safe_viewport', 0, (): void => {
      const v = viewport('phone');
      v.width = 420;
      v.height = 900;
      v.keyboardRect = { x: 0, y: 620, width: 420, height: 280 };
      v.occupiedRects = [{ x: 0, y: 24, width: 120, height: 120 }];
      const r = request('narrow-phone-menu');
      r.menuWidth = 300;
      r.menuHeight = 360;
      const result: OverlayPlacement = resolveOverlayPlacement(v, r);
      expect(result.menuRect.width).assertEqual(300);
      expect(result.menuRect.height).assertEqual(360);
      expect(result.menuRect.x >= v.systemLeft).assertTrue();
      expect(result.menuRect.x + result.menuRect.width <= v.width - v.systemRight).assertTrue();
      expect(result.menuRect.y >= v.systemTop).assertTrue();
      expect(result.menuRect.y + result.menuRect.height <= v.keyboardRect.y).assertTrue();

      const modifier = resolveOverlayAuxiliaryRect(v, {
        ownerId: 'modifier-panel', preferredSide: 'right', preferredX: 900,
        preferredY: 100, width: 280, height: 220
      });
      expect(modifier !== null).assertTrue();
      if (modifier !== null) {
        expect(modifier.x >= v.systemLeft).assertTrue();
        expect(modifier.x + modifier.width <= v.width - v.systemRight).assertTrue();
        expect(modifier.y >= v.systemTop).assertTrue();
        expect(modifier.y + modifier.height <= v.keyboardRect.y).assertTrue();
      }
    });
  });
  }

  if (scope === 'all' || scope === 'registry') {
  describe('RemoteOverlayRegistry_generation_and_cleanup', (): void => {
    it('rejects_begin_from_an_older_generation', 0, (): void => {
      const registry = new RemoteOverlayRegistry();
      expect(registry.begin('rail', 9, 'rail-g9-old')).assertTrue();
      expect(registry.begin('rail', 8)).assertFalse();
      expect(registry.currentGeneration('rail')).assertEqual(9);
      expect(registry.currentMeasurementToken('rail')).assertEqual('rail-g9-old');
      expect(registry.begin('empty-token-owner', 1)).assertFalse();
      expect(registry.begin('empty-token-owner', 1, 'owner-g1')).assertTrue();
    });

    it('rejects_stale_measurement_and_clears_disconnect_owner', 0, (): void => {
      const registry = new RemoteOverlayRegistry();
      registry.begin('session-a', 7, 'session-a-s1');
      const placement: OverlayPlacement = emptyOverlayPlacement('session-a', 7);
      placement.railRect = { x: 900, y: 200, width: 64, height: 220 };
      placement.expandedRect = placement.railRect;
      placement.handleRect = { x: 920, y: 280, width: 44, height: 44 };
      expect(registry.acceptPlacement('session-a', 6, placement, 'session-a-s1')).assertFalse();
      // A late same-generation UI callback must not be allowed to omit or
      // forge the current instance token.
      expect(registry.acceptPlacement('session-a', 7, placement)).assertFalse();
      expect(registry.acceptPlacement('session-a', 7, placement, 'session-a-old')).assertFalse();
      expect(registry.acceptPlacement('session-a', 7, placement, 'session-a-s1')).assertTrue();
      expect(registry.occupiedRects().length).assertEqual(1);
      registry.clearOwner('session-a');
      expect(registry.occupiedRects().length).assertEqual(0);
    });

    it('registers_pair_and_triple_auxiliary_rects_without_cross_generation_leaks', 0, (): void => {
      const registry = new RemoteOverlayRegistry();
      registry.begin('rail', 12, 'rail-g12');
      registry.acceptPlacement('rail', 12, {
        ownerId: 'rail', generation: 12, side: 'right',
        railRect: { x: 900, y: 200, width: 64, height: 220 },
        handleRect: { x: 920, y: 280, width: 44, height: 44 },
        expandedRect: { x: 900, y: 200, width: 64, height: 220 },
        menuRect: { x: 0, y: 0, width: 0, height: 0 },
        menuDirection: 'inward-left', fallback: 'none', recovery: 'none'
      }, 'rail-g12');
      registry.begin('modifier-panel', 12, 'panel-g12-old');
      registry.acceptRects('modifier-panel', 12, [{ x: 600, y: 200, width: 280, height: 260 }],
        'panel-g12-old');
      registry.begin('diagnostics', 12, 'diagnostics-g12');
      registry.acceptRects('diagnostics', 12, [{ x: 300, y: 200, width: 270, height: 205 }],
        'diagnostics-g12');
      expect(registry.occupiedRects('rail').length).assertEqual(2);
      registry.begin('modifier-panel', 13, 'panel-g13');
      registry.acceptRects('modifier-panel', 13, [{ x: 20, y: 20, width: 280, height: 260 }],
        'panel-g13');
      expect(registry.occupiedRects('rail').length).assertEqual(2);
      expect(registry.occupiedRects('rail')[0].x).assertEqual(20);
      expect(registry.occupiedRects('rail')[1].x).assertEqual(300);
      registry.begin('diagnostics', 13, 'diagnostics-g13');
      expect(registry.acceptRects('diagnostics', 12, [
        { x: 0, y: 0, width: 10, height: 10 }
      ], 'diagnostics-g12')).assertFalse();
      expect(registry.acceptRects('diagnostics', 13, [
        { x: 0, y: 0, width: 10, height: 10 }
      ], 'diagnostics-g12')).assertFalse();
      registry.clearOwner('diagnostics');
      expect(registry.occupiedRects('rail').length).assertEqual(1);
    });

    it('accepts_real_rdp_shortcut_surface_measurement_only_for_current_token', 0, (): void => {
      const registry = new RemoteOverlayRegistry();
      registry.begin('remote-shortcut-surface', 4, 'rdp-surface-g4');
      registry.acceptRects('remote-shortcut-surface', 4,
        [{ x: 0, y: 0, width: 64, height: 52 }], 'rdp-surface-g4');
      expect(registry.acceptMeasuredRect('remote-shortcut-surface', 4,
        'stale-token', { x: 812, y: 44, width: 288, height: 58 })).assertFalse();
      expect(registry.acceptMeasuredRect('remote-shortcut-surface', 4,
        'rdp-surface-g4', { x: 812, y: 44, width: 288, height: 58 })).assertTrue();
      const occupied: Array<OverlayRect> = registry.occupiedRects();
      expect(occupied.length).assertEqual(1);
      expect(occupied[0].x).assertEqual(812);
      expect(occupied[0].width).assertEqual(288);
    });
  });
  }
}
