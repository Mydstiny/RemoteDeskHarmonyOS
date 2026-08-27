import { describe, it, expect } from '@ohos/hypium';
import {
  RemoteSurfaceResizeCoordinator,
  RemoteSurfaceResizeGeometry,
  REMOTE_SURFACE_RESIZE_FRAME_MS,
  REMOTE_SURFACE_RESIZE_SETTLE_MS
} from '../main/ets/services/RemoteSurfaceResizePolicy';

export default function remoteSurfaceResizePolicyTest(): void {
  describe('RemoteSurfaceResizePolicy', (): void => {
    it('coalesces burst geometry to the newest display-frame value', 0, (): void => {
      const coordinator = new RemoteSurfaceResizeCoordinator();
      const first = coordinator.observe(680, 483, 1292, 918);
      const second = coordinator.observe(1642, 992, 3120, 1885);
      const final = coordinator.observe(1642, 1095, 3120, 2080);
      expect(first.accepted).assertTrue();
      expect(second.accepted).assertTrue();
      expect(final.accepted).assertTrue();
      const pending = coordinator.takeLatestForFrame();
      expect(pending !== null).assertTrue();
      expect((pending as RemoteSurfaceResizeGeometry).widthPx).assertEqual(3120);
      expect((pending as RemoteSurfaceResizeGeometry).heightPx).assertEqual(2080);
      expect(coordinator.takeLatestForFrame() === null).assertTrue();
    });

    it('rejects duplicate and invalid resize callbacks', 0, (): void => {
      const coordinator = new RemoteSurfaceResizeCoordinator();
      expect(coordinator.observe(680, 483, 1292, 918).accepted).assertTrue();
      expect(coordinator.observe(680.4, 483.2, 1292, 918).accepted).assertFalse();
      expect(coordinator.observe(0, 483, 0, 918).accepted).assertFalse();
    });

    it('settles only the latest observation revision', 0, (): void => {
      const coordinator = new RemoteSurfaceResizeCoordinator();
      const first = coordinator.observe(680, 483, 1292, 918);
      const second = coordinator.observe(1642, 1095, 3120, 2080);
      expect(first.geometry !== null).assertTrue();
      expect(second.geometry !== null).assertTrue();
      expect(coordinator.isLatest((first.geometry as RemoteSurfaceResizeGeometry).revision))
        .assertFalse();
      expect(coordinator.isLatest((second.geometry as RemoteSurfaceResizeGeometry).revision))
        .assertTrue();
      expect(REMOTE_SURFACE_RESIZE_FRAME_MS <= 16).assertTrue();
      expect(REMOTE_SURFACE_RESIZE_SETTLE_MS >= REMOTE_SURFACE_RESIZE_FRAME_MS).assertTrue();
    });

    it('clears pending geometry across a surface lifecycle boundary', 0, (): void => {
      const coordinator = new RemoteSurfaceResizeCoordinator();
      coordinator.observe(680, 483, 1292, 918);
      coordinator.reset();
      expect(coordinator.takeLatestForFrame() === null).assertTrue();
      expect(coordinator.isLatest(1)).assertFalse();
    });
  });
}
