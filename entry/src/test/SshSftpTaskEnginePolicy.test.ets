import { describe, it, expect } from '@ohos/hypium';
import {
  planSshSftpStagingDiscard,
  reconcileSshSftpStoppedUploadCheckpoint,
  SshSftpStagingDiscardPlan,
  shouldReleaseSshSftpRuntimeOnPageTeardown
} from '../main/ets/services/SshSftpTaskEngine';
import { SshSftpTaskRecord } from '../main/ets/services/SshSftpTaskPolicy';

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

    it('releases_page_bindings_only_when_background_survival_is_not_active', 0, (): void => {
      expect(shouldReleaseSshSftpRuntimeOnPageTeardown(false)).assertTrue();
      expect(shouldReleaseSshSftpRuntimeOnPageTeardown(true)).assertFalse();
    });

    it('preserves_cancelled_stage_while_reconciling_confirmed_upload_write', 0, (): void => {
      const cancelled: SshSftpTaskRecord = {
        taskId: 'upload-1', batchId: '', relativePath: 'source.bin', hostId: 'host-1',
        direction: 'upload', isDirectory: false, remotePath: '/source.bin',
        fileName: 'source.bin', totalBytes: 1024, verifiedOffset: 256,
        sourceSize: 1024, sourceMtime: 20, partialSize: 256, partialMtime: 30,
        sessionGeneration: 4, sequence: 8, stage: 'cancelled', updatedAt: 40
      };
      const reconciled: SshSftpTaskRecord | null = reconcileSshSftpStoppedUploadCheckpoint(
        cancelled, 320, { size: 320, mtime: 31 }, 9, 41);

      expect(reconciled === null).assertFalse();
      expect((reconciled as SshSftpTaskRecord).stage).assertEqual('cancelled');
      expect((reconciled as SshSftpTaskRecord).verifiedOffset).assertEqual(320);
      expect((reconciled as SshSftpTaskRecord).partialSize).assertEqual(320);
      expect((reconciled as SshSftpTaskRecord).partialMtime).assertEqual(31);
    });

    it('rejects_checkpoint_reconciliation_without_stopped_stage_or_matching_partial', 0, (): void => {
      const active: SshSftpTaskRecord = {
        taskId: 'upload-2', batchId: '', relativePath: 'source.bin', hostId: 'host-1',
        direction: 'upload', isDirectory: false, remotePath: '/source.bin',
        fileName: 'source.bin', totalBytes: 1024, verifiedOffset: 256,
        sourceSize: 1024, sourceMtime: 20, partialSize: 256, partialMtime: 30,
        sessionGeneration: 4, sequence: 8, stage: 'transferring', updatedAt: 40
      };
      expect(reconcileSshSftpStoppedUploadCheckpoint(
        active, 320, { size: 320, mtime: 31 }, 9, 41) === null).assertTrue();
      active.stage = 'paused';
      expect(reconcileSshSftpStoppedUploadCheckpoint(
        active, 320, { size: 319, mtime: 31 }, 9, 41) === null).assertTrue();
    });
  });
}
