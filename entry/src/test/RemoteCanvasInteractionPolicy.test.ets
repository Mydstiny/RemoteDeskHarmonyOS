import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  REMOTE_CANVAS_INPUT_SURFACE_ID,
  RemoteCanvasPoint,
  RemoteVisibleOverlayHitTarget,
  remoteCanvasGestureIsRemote,
  resolveRemoteInteractionTarget
} from '../main/ets/services/RemoteCanvasInteractionPolicy';

export default function remoteCanvasInteractionPolicyTest(): void {
  describe('RemoteCanvasInteractionPolicy_real_surface_contract', (): void => {
    it('routes_blank_canvas_drag_to_the_real_remote_surface', 0, (): void => {
      const point: RemoteCanvasPoint = { x: 900, y: 700 };
      const overlays: Array<RemoteVisibleOverlayHitTarget> = [
        { ownerId: 'session-rail', rect: { x: 20, y: 20, width: 64, height: 220 },
          generation: 3, visible: true, priority: 10 }
      ];
      const target: string = resolveRemoteInteractionTarget(point, overlays, 3);
      expect(target).assertEqual(REMOTE_CANVAS_INPUT_SURFACE_ID);
      expect(remoteCanvasGestureIsRemote(target)).assertTrue();
    });

    it('visible_button_wins_over_canvas_and_stale_callback_does_not', 0, (): void => {
      const overlays: Array<RemoteVisibleOverlayHitTarget> = [
        { ownerId: 'shortcut-surface', rect: { x: 100, y: 100, width: 80, height: 44 },
          generation: 4, visible: true, priority: 20 },
        { ownerId: 'old-rail', rect: { x: 100, y: 100, width: 80, height: 44 },
          generation: 3, visible: true, priority: 100 }
      ];
      const buttonPoint: RemoteCanvasPoint = { x: 120, y: 120 };
      expect(resolveRemoteInteractionTarget(buttonPoint, overlays, 4))
        .assertEqual('shortcut-surface');
      expect(resolveRemoteInteractionTarget(buttonPoint, overlays, 5))
        .assertEqual(REMOTE_CANVAS_INPUT_SURFACE_ID);
    });

    it('canvas_drag_and_visible_button_click_are_distinct_targets', 0, (): void => {
      const overlay: Array<RemoteVisibleOverlayHitTarget> = [{ ownerId: 'rail-button', rect: { x: 0, y: 0, width: 44, height: 44 },
        generation: 9, visible: true, priority: 50 }];
      const buttonPoint: RemoteCanvasPoint = { x: 22, y: 22 };
      const canvasPoint: RemoteCanvasPoint = { x: 45, y: 45 };
      expect(resolveRemoteInteractionTarget(buttonPoint, overlay, 9))
        .assertEqual('rail-button');
      expect(resolveRemoteInteractionTarget(canvasPoint, overlay, 9))
        .assertEqual(REMOTE_CANVAS_INPUT_SURFACE_ID);
    });
  });
}
