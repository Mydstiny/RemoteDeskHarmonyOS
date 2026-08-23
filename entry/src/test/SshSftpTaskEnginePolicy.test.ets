import { describe, it, expect } from '@ohos/hypium';
import {
  planSshSftpStagingDiscard,
  reconcileSshSftpStoppedDownloadExport,
  reconcileSshSftpStoppedUploadCheckpoint,
  reconcileSshSftpStoppedRemoteCommit,
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

    it('completes_only_the_exact_stopped_task_after_atomic_remote_commit', 0, (): void => {
      const committing: SshSftpTaskRecord = {
        taskId: 'upload-commit', batchId: 'batch-1', relativePath: 'source.bin',
        hostId: 'host-1', direction: 'upload', isDirectory: false,
        remotePath: '/target.bin', fileName: 'target.bin', totalBytes: 1024,
        verifiedOffset: 1024, sourceSize: 1024, sourceMtime: 20,
        partialSize: 1024, partialMtime: 30, sessionGeneration: 4,
        sequence: 8, stage: 'committing', updatedAt: 40,
        sourcePath: 'source.bin', targetPath: '/target.bin', commitState: 'renaming'
      };
      const cancelled: SshSftpTaskRecord = {
        ...committing, sequence: 9, stage: 'cancelled', updatedAt: 41
      };
      const completed: SshSftpTaskRecord | null = reconcileSshSftpStoppedRemoteCommit(
        cancelled, committing, 1024, 10, 42);

      expect(completed === null).assertFalse();
      expect((completed as SshSftpTaskRecord).stage).assertEqual('completed');
      expect((completed as SshSftpTaskRecord).verifiedOffset).assertEqual(1024);
      expect((completed as SshSftpTaskRecord).partialSize).assertEqual(-1);
      expect((completed as SshSftpTaskRecord).commitState).assertEqual('renamed');

      const paused: SshSftpTaskRecord = { ...cancelled, stage: 'paused' };
      expect(reconcileSshSftpStoppedRemoteCommit(paused, committing, 1024, 11, 43)?.stage)
        .assertEqual('completed');
      const wrongTarget: SshSftpTaskRecord = { ...cancelled, targetPath: '/other.bin' };
      expect(reconcileSshSftpStoppedRemoteCommit(
        wrongTarget, committing, 1024, 11, 43) === null).assertTrue();
      expect(reconcileSshSftpStoppedRemoteCommit(
        { ...cancelled, stage: 'transferring' }, committing, 1024, 11, 43) === null)
        .assertTrue();
      expect(reconcileSshSftpStoppedRemoteCommit(
        cancelled, { ...committing, commitState: 'renamed' }, 1024, 11, 43) === null)
        .assertTrue();
    });

    it('completes_only_the_exact_stopped_download_after_verified_export', 0, (): void => {
      const exporting: SshSftpTaskRecord = {
        taskId: 'download-export', batchId: 'batch-2', relativePath: 'target.bin',
        hostId: 'host-1', direction: 'download', isDirectory: false,
        remotePath: '/source.bin', fileName: 'target.bin', totalBytes: 2048,
        verifiedOffset: 2048, sourceSize: 2048, sourceMtime: 20,
        partialSize: 2048, partialMtime: 30, sessionGeneration: 4,
        sequence: 12, stage: 'transferring', updatedAt: 50,
        sourcePath: '/source.bin', targetPath: 'target.bin'
      };
      const paused: SshSftpTaskRecord = {
        ...exporting, sequence: 13, stage: 'paused', updatedAt: 51
      };
      const completed: SshSftpTaskRecord | null = reconcileSshSftpStoppedDownloadExport(
        paused, exporting, 2048, 14, 52);

      expect(completed === null).assertFalse();
      expect((completed as SshSftpTaskRecord).stage).assertEqual('completed');
      expect((completed as SshSftpTaskRecord).verifiedOffset).assertEqual(2048);
      expect((completed as SshSftpTaskRecord).partialSize).assertEqual(-1);
      expect((completed as SshSftpTaskRecord).commitState).assertUndefined();
      const cancelled: SshSftpTaskRecord = { ...paused, stage: 'cancelled' };
      expect(reconcileSshSftpStoppedDownloadExport(
        cancelled, exporting, 2048, 15, 53)?.stage).assertEqual('completed');

      const unknownSize: SshSftpTaskRecord = {
        ...paused, totalBytes: -1, sourceSize: -1
      };
      const unknownAttempt: SshSftpTaskRecord = {
        ...exporting, totalBytes: -1, sourceSize: -1
      };
      expect(reconcileSshSftpStoppedDownloadExport(
        unknownSize, unknownAttempt, 2048, 15, 53)?.totalBytes).assertEqual(2048);
      expect(reconcileSshSftpStoppedDownloadExport(
        { ...paused, targetPath: 'other.bin' }, exporting, 2048, 15, 53) === null)
        .assertTrue();
      expect(reconcileSshSftpStoppedDownloadExport(
        { ...paused, stage: 'transferring' }, exporting, 2048, 15, 53) === null)
        .assertTrue();
      expect(reconcileSshSftpStoppedDownloadExport(
        paused, { ...exporting, direction: 'upload' }, 2048, 15, 53) === null)
        .assertTrue();
    });
  });
}
