import { describe, it, expect } from '@ohos/hypium';
import {
  decideSshBackgroundSignalAction,
  SshBackgroundSignalTaskRegistry,
  SshBackgroundSignalAction
} from '../main/ets/services/SshTerminalBackgroundTaskService';

export default function sshTerminalBackgroundTaskServiceTest(): void {
  describe('SshTerminalBackgroundTaskService', (): void => {
    it('live_background_signal_should_start_active_sessions', 0, (): void => {
      expect(decideSshBackgroundSignalAction(true, false, 1, 0))
        .assertEqual(SshBackgroundSignalAction.start);
      expect(decideSshBackgroundSignalAction(true, false, 3, 2))
        .assertEqual(SshBackgroundSignalAction.start);
    });

    it('foreground_should_stop_only_page_tracked_tasks', 0, (): void => {
      expect(decideSshBackgroundSignalAction(false, false, 1, 1))
        .assertEqual(SshBackgroundSignalAction.stop);
      expect(decideSshBackgroundSignalAction(false, false, 1, 0))
        .assertEqual(SshBackgroundSignalAction.none);
    });

    it('teardown_or_empty_background_should_not_duplicate_lifecycle_work', 0, (): void => {
      expect(decideSshBackgroundSignalAction(true, true, 2, 0))
        .assertEqual(SshBackgroundSignalAction.none);
      expect(decideSshBackgroundSignalAction(false, true, 0, 2))
        .assertEqual(SshBackgroundSignalAction.none);
      expect(decideSshBackgroundSignalAction(true, false, 0, 0))
        .assertEqual(SshBackgroundSignalAction.none);
    });

    it('page_signal_registry_should_reset_recycled_session_id_ownership', 0, (): void => {
      const registry: SshBackgroundSignalTaskRegistry =
        new SshBackgroundSignalTaskRegistry();
      registry.track({
        hostId: ' host-a ', sessionId: 17, hostLabel: 'Host A', hostAddress: 'user@a'
      });
      registry.track({
        hostId: 'host-a', sessionId: 17, hostLabel: 'Host A (new)', hostAddress: 'user@a-new'
      });
      expect(registry.size()).assertEqual(1);
      expect(registry.snapshot()[0].hostId).assertEqual('host-a');
      expect(registry.snapshot()[0].hostAddress).assertEqual('user@a-new');
      registry.clear();
      expect(registry.size()).assertEqual(0);
      expect(registry.snapshot().length).assertEqual(0);
    });
  });
}
