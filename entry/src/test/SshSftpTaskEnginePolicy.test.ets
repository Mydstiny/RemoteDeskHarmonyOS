import { describe, it, expect } from '@ohos/hypium';
import {
  planSshSftpStagingDiscard,
  SshSftpStagingDiscardPlan
} from '../main/ets/services/SshSftpTaskEngine';

export default function sshSftpTaskEnginePolicyTest(): void {
  describe('SshSftpTaskEnginePolicy', (): void => {
    it('defers_active_drop_cleanup_and_cleans_once_worker_stops', 0, (): void => {
      const running: SshSftpStagingDiscardPlan =
        planSshSftpStagingDiscard(true, true, true, 'local');
      expect(running.accepted).assertTrue();
      expect(running.deferUntilWorkerStops).assertTrue();
      expect(running.cleanupStagingRoot).assertTrue();

      const stopped: SshSftpStagingDiscardPlan =
        planSshSftpStagingDiscard(true, false, true, 'local');
      expect(stopped.deferUntilWorkerStops).assertFalse();
      expect(stopped.cleanupStagingRoot).assertTrue();
    });

    it('never_removes_non_drop_roots_or_unknown_bindings', 0, (): void => {
      expect(planSshSftpStagingDiscard(true, false, false, 'local').cleanupStagingRoot)
        .assertFalse();
      expect(planSshSftpStagingDiscard(true, false, true, 'ssh').cleanupStagingRoot)
        .assertFalse();
      expect(planSshSftpStagingDiscard(false, false, true, 'local').accepted)
        .assertFalse();
    });
  });
}
