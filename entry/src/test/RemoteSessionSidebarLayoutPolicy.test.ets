import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from
  '../main/ets/services/FocusedTestRegistrationAudit';
import {
  remoteSessionSidebarAnchoredMenuTop,
  remoteSessionSidebarCanvasHeight,
  remoteSessionFloatingCardHeight,
  remoteSessionFloatingCardWidth,
  remoteSessionSidebarMenuMaxHeight,
  remoteSessionSidebarMenuWidth,
  remoteSessionSidebarVisibleRailHeight
} from '../main/ets/services/RemoteSessionSidebarLayoutPolicy';

export default function remoteSessionSidebarLayoutPolicyTest(): void {
  describe('RemoteSessionSidebarLayoutPolicy', (): void => {
    it('fits_phone_landscape_without_horizontal_clipping', 0, (): void => {
      expect(remoteSessionSidebarMenuWidth(320, 300, 52, 6)).assertEqual(250);
      expect(remoteSessionSidebarCanvasHeight(320)).assertEqual(304);
      expect(remoteSessionSidebarVisibleRailHeight(320, 364)).assertEqual(304);
      expect(remoteSessionSidebarCanvasHeight(80)).assertEqual(64);
      expect(remoteSessionSidebarMenuMaxHeight(80, 48)).assertEqual(16);
    });

    it('keeps_requested_pad_width_when_space_is_available', 0, (): void => {
      expect(remoteSessionSidebarMenuWidth(800, 340, 56, 8)).assertEqual(340);
      expect(remoteSessionSidebarVisibleRailHeight(720, 396)).assertEqual(396);
      expect(remoteSessionSidebarMenuMaxHeight(720, 0)).assertEqual(704);
    });

    it('fits_floating_cards_inside_phone_and_pad_viewports', 0, (): void => {
      expect(remoteSessionFloatingCardWidth(320, 360, 12)).assertEqual(296);
      expect(remoteSessionFloatingCardHeight(320, 520, 12, 12)).assertEqual(296);
      expect(remoteSessionFloatingCardWidth(800, 360, 12)).assertEqual(360);
      expect(remoteSessionFloatingCardHeight(720, 520, 12, 12)).assertEqual(520);
    });

    it('anchors_keyboard_menu_beside_rail_button_with_edge_clamping', 0, (): void => {
      expect(remoteSessionSidebarAnchoredMenuTop(720, 337, 44, 156)).assertEqual(281);
      expect(remoteSessionSidebarAnchoredMenuTop(320, 214, 44, 132)).assertEqual(164);
      expect(remoteSessionSidebarAnchoredMenuTop(320, -40, 44, 132)).assertEqual(8);
    });

    it('sanitizes_invalid_measurements', 0, (): void => {
      expect(remoteSessionSidebarMenuWidth(Number.NaN, 300, 52, 6)).assertEqual(290);
      expect(remoteSessionSidebarCanvasHeight(Number.NaN)).assertEqual(624);
      expect(remoteSessionSidebarMenuMaxHeight(320, Number.NaN)).assertEqual(304);
    });
  });
}
