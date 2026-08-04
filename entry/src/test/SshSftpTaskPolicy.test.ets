import { describe, it, expect } from '@ohos/hypium';
import {
  SshSftpTaskRecord,
  canTransitionSshSftpTask,
  isMonotonicSshSftpTaskProgress,
  isNewerSshSftpTaskUpdate,
  normalizeSshSftpTaskRecord,
  sshSftpResumeDisposition,
  upsertSshSftpTask
} from '../main/ets/services/SshSftpTaskPolicy';

function task(id: string, sequence: number): SshSftpTaskRecord {
  return {
    taskId: id, hostId: 'host-1', direction: 'download', remotePath: './report.txt',
    fileName: 'report.txt', totalBytes: 100, verifiedOffset: 50,
    sourceSize: 100, sourceMtime: 20, partialSize: 50, partialMtime: 21,
    sessionGeneration: 3, sequence, stage: 'waitingForConnection', updatedAt: sequence
  };
}

export default function sshSftpTaskPolicyTest(): void {
  describe('SshSftpTaskPolicy', (): void => {
    it('normalizes persisted metadata and clamps invalid offsets', 0, (): void => {
      const normalized = normalizeSshSftpTaskRecord({
        taskId: 'task-1', hostId: 'host-1', direction: 'upload', remotePath: './x', fileName: 'x',
        totalBytes: 10, verifiedOffset: 99, stage: 'transferring', sequence: 2, updatedAt: 3
      });
      expect(normalized !== null).assertTrue();
      expect(normalized?.verifiedOffset).assertEqual(10);
      expect(normalizeSshSftpTaskRecord({ taskId: '', hostId: 'host', remotePath: '.', fileName: 'x' })).assertNull();

      const unknownTotal = normalizeSshSftpTaskRecord({
        taskId: 'legacy-1', hostId: 'host-1', direction: 'download', remotePath: './x', fileName: 'x',
        verifiedOffset: 0, sourceSize: 100, sourceMtime: 20, partialSize: 0, partialMtime: 21,
        stage: 'waitingForConnection', sequence: 3, updatedAt: 4
      });
      expect(unknownTotal !== null).assertTrue();
      expect(unknownTotal?.totalBytes).assertEqual(-1);
      expect(unknownTotal?.verifiedOffset).assertEqual(-1);
      expect(sshSftpResumeDisposition(unknownTotal as SshSftpTaskRecord, {
        hasAuthorization: true, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: true
      })).assertEqual('NotResumable');
    });

    it('requires authorization and matching partial before resume', 0, (): void => {
      const record: SshSftpTaskRecord = task('task-1', 1);
      expect(sshSftpResumeDisposition(record, {
        hasAuthorization: false, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: true
      })).assertEqual('NeedsAuthorization');
      expect(sshSftpResumeDisposition(record, {
        hasAuthorization: true, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: false
      })).assertEqual('NotResumable');
      expect(sshSftpResumeDisposition(record, {
        hasAuthorization: true, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: true
      })).assertEqual('ReadyToResume');
      const unknownPartial: SshSftpTaskRecord = {
        taskId: 'task-unknown', hostId: 'host-1', direction: 'download', remotePath: './report.txt',
        fileName: 'report.txt', totalBytes: 100, verifiedOffset: 50,
        sourceSize: 100, sourceMtime: 20, partialSize: -1, partialMtime: -1,
        sessionGeneration: 3, sequence: 2, stage: 'waitingForConnection', updatedAt: 2
      };
      expect(sshSftpResumeDisposition(unknownPartial, {
        hasAuthorization: true, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: true
      })).assertEqual('NotResumable');
    });

    it('keeps task transitions explicit and replaces by id', 0, (): void => {
      expect(canTransitionSshSftpTask('transferring', 'waitingForConnection')).assertTrue();
      expect(canTransitionSshSftpTask('queued', 'inspecting')).assertTrue();
      expect(canTransitionSshSftpTask('transferring', 'verifying')).assertTrue();
      expect(canTransitionSshSftpTask('verifying', 'committing')).assertTrue();
      expect(canTransitionSshSftpTask('committing', 'completed')).assertTrue();
      expect(canTransitionSshSftpTask('transferring', 'completed')).assertFalse();
      expect(canTransitionSshSftpTask('completed', 'queued')).assertFalse();
      const replaced = upsertSshSftpTask([task('task-1', 1)], task('task-1', 2));
      expect(replaced.length).assertEqual(1);
      expect(replaced[0].sequence).assertEqual(2);
    });

    it('rejects stale or regressive durable updates', 0, (): void => {
      const current: SshSftpTaskRecord = task('task-1', 4);
      const stale: SshSftpTaskRecord = {
        taskId: current.taskId, hostId: current.hostId, direction: current.direction,
        remotePath: current.remotePath, fileName: current.fileName, totalBytes: current.totalBytes,
        verifiedOffset: current.verifiedOffset, sourceSize: current.sourceSize,
        sourceMtime: current.sourceMtime, partialSize: current.partialSize,
        partialMtime: current.partialMtime, sessionGeneration: current.sessionGeneration,
        sequence: 3, stage: current.stage, updatedAt: 99
      };
      const regressive: SshSftpTaskRecord = {
        taskId: current.taskId, hostId: current.hostId, direction: current.direction,
        remotePath: current.remotePath, fileName: current.fileName, totalBytes: current.totalBytes,
        verifiedOffset: 20, sourceSize: current.sourceSize, sourceMtime: current.sourceMtime,
        partialSize: 20, partialMtime: current.partialMtime,
        sessionGeneration: current.sessionGeneration, sequence: 5, stage: current.stage, updatedAt: 5
      };
      const newer: SshSftpTaskRecord = {
        taskId: current.taskId, hostId: current.hostId, direction: current.direction,
        remotePath: current.remotePath, fileName: current.fileName, totalBytes: current.totalBytes,
        verifiedOffset: 75, sourceSize: current.sourceSize, sourceMtime: current.sourceMtime,
        partialSize: 75, partialMtime: current.partialMtime,
        sessionGeneration: current.sessionGeneration, sequence: 5, stage: current.stage, updatedAt: 6
      };
      expect(isNewerSshSftpTaskUpdate(current, stale)).assertFalse();
      expect(isNewerSshSftpTaskUpdate(current, newer)).assertTrue();
      expect(isMonotonicSshSftpTaskProgress(current, regressive)).assertFalse();
      expect(isMonotonicSshSftpTaskProgress(current, newer)).assertTrue();
      expect(upsertSshSftpTask([current], stale)[0].sequence).assertEqual(4);
      expect(upsertSshSftpTask([current], regressive)[0].verifiedOffset).assertEqual(50);
      expect(upsertSshSftpTask([current], newer)[0].verifiedOffset).assertEqual(75);
    });
  });
}
