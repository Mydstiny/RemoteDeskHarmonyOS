import { describe, expect, it } from '@ohos/hypium';
import { SshModalCoordinator, SshModalDecision } from '../main/ets/services/SshModalCoordinator';

export default function sshModalCoordinatorTest(): void {
  describe('SshModalCoordinator', (): void => {
    it('coalesces repeated opens for one native surface', 0, (): void => {
      const coordinator: SshModalCoordinator = new SshModalCoordinator();
      const first: SshModalDecision = coordinator.requestOpen();
      expect(first.mount).assertTrue();
      expect(coordinator.requestOpen().mount).assertFalse();
      expect(coordinator.noteAppeared(first.token)).assertTrue();
      expect(coordinator.requestOpen().mount).assertFalse();
    });

    it('replays an open only after the closing surface disappears', 0, (): void => {
      const coordinator: SshModalCoordinator = new SshModalCoordinator();
      const first: SshModalDecision = coordinator.requestOpen();
      coordinator.noteAppeared(first.token);
      expect(coordinator.requestClose().dismiss).assertTrue();
      expect(coordinator.requestOpen().mount).assertFalse();
      const replay: SshModalDecision = coordinator.noteDisappeared(first.token);
      expect(replay.mount).assertTrue();
      expect(replay.token > first.token).assertTrue();
    });

    it('invalidates stale sheet callbacks', 0, (): void => {
      const coordinator: SshModalCoordinator = new SshModalCoordinator();
      const first: SshModalDecision = coordinator.requestOpen();
      coordinator.invalidate();
      expect(coordinator.noteAppeared(first.token)).assertFalse();
      expect(coordinator.noteDisappeared(first.token).mount).assertFalse();
    });
  });
}
