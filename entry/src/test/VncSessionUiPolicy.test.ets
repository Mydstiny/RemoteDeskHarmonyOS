import { describe, it, expect } from '@ohos/hypium';
import {
  OverlayPlacement,
  OverlayPlacementRequest,
  OverlayViewport,
  resolveOverlayDragPreference,
  resolveOverlayPlacement
} from '../main/ets/services/RemoteOverlayViewportPolicy';
import {
  nextVncControlMode,
  nextVncDisplayScaleMode,
  resolveVncCursorOwnershipEvidence,
  shouldHideVncSystemPointer,
  shouldShowVncSessionToolbar,
  vncToolbarAutoCollapseDelayMs,
  vncToolbarDefaultSide,
  vncToolbarPositionPreferenceKey,
  vncToolbarPrimaryActionIds,
  vncToolbarRailHeight,
  vncToolbarRailWidth
} from '../main/ets/services/VncSessionUiPolicy';

function mobileViewport(): OverlayViewport {
  return {
    width: 360,
    height: 760,
    systemTop: 24,
    systemBottom: 20,
    systemLeft: 0,
    systemRight: 0,
    cutoutRects: [],
    keyboardRect: null,
    orientation: 'portrait',
    deviceClass: 'phone',
    occupiedRects: [],
    generation: 1
  };
}

function vncPhoneRailRequest(): OverlayPlacementRequest {
  return {
    ownerId: 'vnc-toolbar',
    preferredSide: 'right',
    yRatio: 0.5,
    handleSize: vncToolbarRailWidth('phone', true),
    railWidth: vncToolbarRailWidth('phone', false),
    railHeight: vncToolbarRailHeight('phone', false, false),
    menuWidth: 0,
    menuHeight: 0,
    expanded: false
  };
}

export default function vncSessionUiPolicyTest(): void {
  describe('VncSessionUiPolicy', (): void => {
    it('shows_toolbar_only_for_connected_vnc_session', 0, (): void => {
      expect(shouldShowVncSessionToolbar('vnc', true, 4)).assertTrue();
      expect(shouldShowVncSessionToolbar('vnc', false, 4)).assertFalse();
      expect(shouldShowVncSessionToolbar('rdp', true, 4)).assertFalse();
    });

    it('keeps_a_recoverable_toolbar_when_legacy_hidden_is_requested', 0, (): void => {
      expect(shouldShowVncSessionToolbar('vnc', true, 4, true, true)).assertTrue();
      expect(shouldShowVncSessionToolbar('vnc', true, 4, false, true)).assertTrue();
      expect(shouldShowVncSessionToolbar('vnc', true, 4, true, false)).assertTrue();
    });

    it('keeps_pc_top_bar_and_mobile_rail_on_one_action_contract', 0, (): void => {
      const actions = vncToolbarPrimaryActionIds();
      expect(actions.length).assertEqual(6);
      expect(actions.join(','))
        .assertEqual('keyboard,controlMode,shortcuts,displayScale,diagnostics,disconnect');
    });

    it('transitions_cursor_ownership_from_bootstrap_to_protocol_shape', 0, (): void => {
      const initial = resolveVncCursorOwnershipEvidence(false, true, false, false);
      const macBootstrap = resolveVncCursorOwnershipEvidence(true, true, false, true);
      const protocolCursor = resolveVncCursorOwnershipEvidence(true, true, true, true);
      expect(initial).assertEqual('bootstrap');
      expect(macBootstrap).assertEqual('bootstrap');
      expect(protocolCursor).assertEqual('protocol_cursor');
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'auto', initial)).assertFalse();
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'auto', macBootstrap)).assertFalse();
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'auto', protocolCursor)).assertFalse();
    });

    it('uses_framebuffer_cursor_for_modern_no_cursor_peers_and_honors_hide', 0, (): void => {
      const ultraVnc = resolveVncCursorOwnershipEvidence(true, false, false, true);
      const protocolHidden = resolveVncCursorOwnershipEvidence(true, true, false, false);
      expect(ultraVnc).assertEqual('framebuffer_composited');
      expect(protocolHidden).assertEqual('protocol_hidden');
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'auto', ultraVnc)).assertTrue();
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'auto', protocolHidden)).assertTrue();
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'hidden', 'bootstrap')).assertTrue();
      expect(shouldHideVncSystemPointer('vnc', true, true, true, 'arrow', protocolHidden)).assertFalse();
    });

    it('resets_pointer_hiding_outside_the_active_vnc_surface', 0, (): void => {
      expect(shouldHideVncSystemPointer('vnc', false, true, true, 'auto',
        'framebuffer_composited')).assertFalse();
      expect(shouldHideVncSystemPointer('vnc', true, true, false, 'auto',
        'framebuffer_composited')).assertFalse();
      expect(shouldHideVncSystemPointer('rdp', true, true, true, 'auto',
        'framebuffer_composited')).assertFalse();
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

    it('keeps_pc_on_legacy_toolbar_geometry', 0, (): void => {
      expect(vncToolbarRailWidth('pc', false)).assertEqual(0);
      expect(vncToolbarRailWidth('pc', true)).assertEqual(0);
      expect(vncToolbarRailHeight('pc', false, false)).assertEqual(0);
      expect(vncToolbarDefaultSide('pc')).assertEqual('right');
    });

    it('uses_edge_rail_dimensions_for_phone_and_pad', 0, (): void => {
      expect(vncToolbarRailWidth('phone', false)).assertEqual(68);
      expect(vncToolbarRailWidth('phone', true)).assertEqual(44);
      expect(vncToolbarRailHeight('phone', false, false)).assertEqual(350);
      expect(vncToolbarRailHeight('phone', false, true)).assertEqual(72);
      expect(vncToolbarRailWidth('pad', false)).assertEqual(68);
      expect(vncToolbarRailHeight('pad', false, false)).assertEqual(350);
      expect(vncToolbarRailHeight('pad', true, false)).assertEqual(379);
      expect(vncToolbarRailHeight('pad', true, true)).assertEqual(72);
      expect(vncToolbarRailHeight('phone', false, false, 248)).assertEqual(248);
      expect(vncToolbarRailHeight('pad', true, false, 216)).assertEqual(216);
      expect(vncToolbarRailHeight('phone', false, true, 56)).assertEqual(56);
    });

    it('isolates_vnc_position_preferences_by_device_and_orientation', 0, (): void => {
      expect(vncToolbarPositionPreferenceKey('phone', 'portrait', 'side'))
        .assertEqual('vncSessionToolbar:phone:portrait:side');
      expect(vncToolbarPositionPreferenceKey('pad', 'landscape', 'yRatio'))
        .assertEqual('vncSessionToolbar:pad:landscape:yRatio');
      expect(vncToolbarPositionPreferenceKey('pc', 'portrait', 'side'))
        .assertEqual('vncSessionToolbar:pc:portrait:side');
    });

    it('moves_vnc_phone_rail_away_from_keyboard_and_collision', 0, (): void => {
      const viewport: OverlayViewport = mobileViewport();
      viewport.keyboardRect = { x: 0, y: 520, width: 360, height: 240 };
      viewport.occupiedRects = [{ x: 284, y: 180, width: 76, height: 300 }];
      const placement: OverlayPlacement = resolveOverlayPlacement(viewport, vncPhoneRailRequest());
      expect(placement.side).assertEqual('left');
      expect(placement.recovery).assertEqual('none');
      expect(placement.railRect.y >= viewport.systemTop).assertTrue();
      expect(placement.railRect.y + placement.railRect.height <= viewport.keyboardRect.y).assertTrue();
    });

    it('keeps_a_scrollable_expanded_rail_in_short_landscape', 0, (): void => {
      const viewport: OverlayViewport = mobileViewport();
      viewport.width = 760;
      viewport.height = 280;
      viewport.systemBottom = 8;
      viewport.orientation = 'landscape';
      const request: OverlayPlacementRequest = vncPhoneRailRequest();
      request.railHeight = vncToolbarRailHeight('phone', false, false, 248);
      const placement: OverlayPlacement = resolveOverlayPlacement(viewport, request);
      expect(placement.recovery).assertEqual('none');
      expect(placement.railRect.height).assertEqual(248);
      expect(placement.railRect.y + placement.railRect.height <= 272).assertTrue();
    });

    it('hides_vnc_rail_when_no_safe_mobile_slot_exists', 0, (): void => {
      const viewport: OverlayViewport = mobileViewport();
      viewport.occupiedRects = [{ x: 0, y: 24, width: 360, height: 716 }];
      const placement: OverlayPlacement = resolveOverlayPlacement(viewport, vncPhoneRailRequest());
      expect(placement.fallback).assertEqual('hidden');
      expect(placement.recovery).assertEqual('retry-after-resize');
      expect(placement.railRect.width).assertEqual(0);
      expect(placement.handleRect.width).assertEqual(0);
    });

    it('clamps_vnc_drag_to_keyboard_boundary_and_persists_side', 0, (): void => {
      const viewport: OverlayViewport = mobileViewport();
      viewport.keyboardRect = { x: 0, y: 520, width: 360, height: 240 };
      const placement: OverlayPlacement = resolveOverlayPlacement(viewport, vncPhoneRailRequest());
      const moved = resolveOverlayDragPreference(viewport, placement, -1000, 1000);
      expect(moved.side).assertEqual('left');
      expect(moved.yRatio <= 520 / 760).assertTrue();
    });
  });
}
