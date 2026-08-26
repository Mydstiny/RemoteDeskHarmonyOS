import { describe, it, expect } from '@ohos/hypium';
import { SshSessionSnapshot } from '../main/ets/types/rdpnapi';
import {
  SshSftpBatchPlan,
  SshSftpTreeItem,
  planSshSftpBatch
} from '../main/ets/services/SshSftpBatchPolicy';
import {
  SftpEndpoint,
  SftpTransferSpec,
  SshSftpTaskRecord,
  canTransitionSshSftpTask,
  isValidSftpTransferSpec,
  isMonotonicSshSftpTaskProgress,
  isNewerSshSftpTaskUpdate,
  normalizeSshSftpTaskRecord,
  recoverInterruptedSshSftpTaskRecord,
  sftpEndpointPathIsSame,
  sshSftpCommitRecoveryDecision,
  sshSftpSessionSnapshotCanAttach,
  sshSftpTaskCommandTarget,
  sshSftpResumeDisposition,
  upsertSshSftpTask
} from '../main/ets/services/SshSftpTaskPolicy';
import { SshSftpTaskStore } from '../main/ets/services/SshSftpTaskStore';
import {
  SshSftpSessionOwnerPolicy,
  SshSftpTrackedSession
} from '../main/ets/services/SshSftpSessionOwnerPolicy';

function task(id: string, sequence: number): SshSftpTaskRecord {
  return {
    taskId: id, batchId: '', relativePath: '', hostId: 'host-1', direction: 'download', remotePath: './report.txt',
    isDirectory: false, fileName: 'report.txt', totalBytes: 100, verifiedOffset: 50,
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
      expect(normalized?.isDirectory).assertFalse();
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
        taskId: 'task-unknown', batchId: '', relativePath: '', hostId: 'host-1', direction: 'download', remotePath: './report.txt',
        isDirectory: false, fileName: 'report.txt', totalBytes: 100, verifiedOffset: 50,
        sourceSize: 100, sourceMtime: 20, partialSize: -1, partialMtime: -1,
        sessionGeneration: 3, sequence: 2, stage: 'waitingForConnection', updatedAt: 2
      };
      expect(sshSftpResumeDisposition(unknownPartial, {
        hasAuthorization: true, hasAuthentication: true, hasMatchingSession: true, hasMatchingPartial: true
      })).assertEqual('NotResumable');
    });

    it('turns persisted in-flight work into an explicit reconnect wait', 0, (): void => {
      const interruptedStages = ['inspecting', 'transferring', 'verifying', 'committing'];
      for (let index: number = 0; index < interruptedStages.length; index++) {
        const interrupted: SshSftpTaskRecord = {
          ...task('restore-' + index.toString(), 10),
          stage: interruptedStages[index] as SshSftpTaskRecord['stage'],
          sessionGeneration: 9
        };
        const recovered: SshSftpTaskRecord =
          recoverInterruptedSshSftpTaskRecord(interrupted, 20 + index);
        expect(recovered.stage).assertEqual('waitingForConnection');
        expect(recovered.sessionGeneration).assertEqual(0);
        expect(recovered.verifiedOffset).assertEqual(interrupted.verifiedOffset);
        expect(recovered.partialSize).assertEqual(interrupted.partialSize);
        expect(recovered.sequence).assertEqual(20 + index);
      }
      const paused: SshSftpTaskRecord = task('paused', 30);
      paused.stage = 'paused';
      expect(recoverInterruptedSshSftpTaskRecord(paused, 40)).assertEqual(paused);
    });

    it('keeps task transitions explicit and replaces by id', 0, (): void => {
      expect(canTransitionSshSftpTask('transferring', 'waitingForConnection')).assertTrue();
      expect(canTransitionSshSftpTask('queued', 'inspecting')).assertTrue();
      expect(canTransitionSshSftpTask('transferring', 'verifying')).assertTrue();
      expect(canTransitionSshSftpTask('verifying', 'committing')).assertTrue();
      expect(canTransitionSshSftpTask('committing', 'completed')).assertTrue();
      expect(canTransitionSshSftpTask('committing', 'waitingForConnection')).assertTrue();
      expect(canTransitionSshSftpTask('queued', 'completed')).assertTrue();
      expect(canTransitionSshSftpTask('transferring', 'completed')).assertFalse();
      expect(canTransitionSshSftpTask('completed', 'queued')).assertFalse();
      const replaced = upsertSshSftpTask([task('task-1', 1)], task('task-1', 2));
      expect(replaced.length).assertEqual(1);
      expect(replaced[0].sequence).assertEqual(2);
    });

    it('rejects stale or regressive durable updates', 0, (): void => {
      const current: SshSftpTaskRecord = task('task-1', 4);
      const stale: SshSftpTaskRecord = {
        taskId: current.taskId, batchId: current.batchId, relativePath: current.relativePath,
        hostId: current.hostId, direction: current.direction,
        isDirectory: current.isDirectory, remotePath: current.remotePath, fileName: current.fileName,
        totalBytes: current.totalBytes,
        verifiedOffset: current.verifiedOffset, sourceSize: current.sourceSize,
        sourceMtime: current.sourceMtime, partialSize: current.partialSize,
        partialMtime: current.partialMtime, sessionGeneration: current.sessionGeneration,
        sequence: 3, stage: current.stage, updatedAt: 99
      };
      const regressive: SshSftpTaskRecord = {
        taskId: current.taskId, batchId: current.batchId, relativePath: current.relativePath,
        hostId: current.hostId, direction: current.direction,
        isDirectory: current.isDirectory, remotePath: current.remotePath, fileName: current.fileName,
        totalBytes: current.totalBytes,
        verifiedOffset: 20, sourceSize: current.sourceSize, sourceMtime: current.sourceMtime,
        partialSize: 20, partialMtime: current.partialMtime,
        sessionGeneration: current.sessionGeneration, sequence: 5, stage: current.stage, updatedAt: 5
      };
      const newer: SshSftpTaskRecord = {
        taskId: current.taskId, batchId: current.batchId, relativePath: current.relativePath,
        hostId: current.hostId, direction: current.direction,
        isDirectory: current.isDirectory, remotePath: current.remotePath, fileName: current.fileName,
        totalBytes: current.totalBytes,
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

    it('maps lifecycle commands to explicit durable stages', 0, (): void => {
      expect(sshSftpTaskCommandTarget('transferring', { kind: 'pause' })).assertEqual('paused');
      expect(sshSftpTaskCommandTarget('paused', { kind: 'resume' })).assertEqual('queued');
      expect(sshSftpTaskCommandTarget('waitingForConnection', { kind: 'resume' })).assertEqual('queued');
      expect(sshSftpTaskCommandTarget('failed', { kind: 'retry' })).assertEqual('queued');
      expect(sshSftpTaskCommandTarget('awaitingConflictDecision', { kind: 'retry' })).assertEqual('queued');
      expect(sshSftpTaskCommandTarget('needsAuthorization', { kind: 'authorize' })).assertEqual('queued');
      expect(sshSftpTaskCommandTarget('queued', { kind: 'complete' })).assertEqual('completed');
      expect(sshSftpTaskCommandTarget('transferring', { kind: 'detach' })).assertEqual('waitingForConnection');
      expect(sshSftpTaskCommandTarget('completed', { kind: 'cancel' })).assertNull();
    });

    it('owns command transitions and publishes task changes', 0, (): void => {
      const store: SshSftpTaskStore = new SshSftpTaskStore();
      let events: number = 0;
      const unsubscribe: () => void = store.subscribe((_event): void => { events++; });
      const ownerRecord: SshSftpTaskRecord = task('owner-task', 10);
      ownerRecord.stage = 'transferring';
      expect(store.upsert(ownerRecord)).assertTrue();
      expect(store.command('owner-task', { kind: 'detach' }).accepted).assertTrue();
      expect(store.get('owner-task')?.stage).assertEqual('waitingForConnection');
      expect(store.command('owner-task', { kind: 'resume' }).accepted).assertTrue();
      expect(store.get('owner-task')?.stage).assertEqual('queued');
      expect(store.command('owner-task', { kind: 'complete' }).accepted).assertFalse();
      expect(store.command('owner-task', { kind: 'cancel' }).accepted).assertTrue();
      expect(store.get('owner-task')?.stage).assertEqual('cancelled');
      expect(events).assertEqual(4);
      unsubscribe();
    });

    it('requeues an orphaned in-flight task only after it is detached', 0, (): void => {
      const store: SshSftpTaskStore = new SshSftpTaskStore();
      const interrupted: SshSftpTaskRecord = task('route-loss-task', 20);
      interrupted.stage = 'transferring';
      expect(store.upsert(interrupted)).assertTrue();
      expect(store.command(interrupted.taskId, { kind: 'retry' }).accepted).assertFalse();
      expect(store.command(interrupted.taskId, { kind: 'detach' }).accepted).assertTrue();
      expect(store.get(interrupted.taskId)?.stage).assertEqual('waitingForConnection');
      expect(store.command(interrupted.taskId, { kind: 'retry' }).accepted).assertTrue();
      expect(store.get(interrupted.taskId)?.stage).assertEqual('queued');
    });

    it('creates durable file and directory tasks from an accepted batch plan', 0, (): void => {
      const item = (path: string, name: string, size: number): SshSftpTreeItem => ({
        relativePath: path, name, isDirectory: false, isSymbolicLink: false,
        isSpecialFile: false, size, mtime: 20, mode: 0, uid: -1, gid: -1
      });
      const directory: SshSftpTreeItem = {
        relativePath: 'folder', name: 'folder', isDirectory: true, isSymbolicLink: false,
        isSpecialFile: false, size: 0, mtime: 20, mode: 0, uid: -1, gid: -1
      };
      const plan: SshSftpBatchPlan = planSshSftpBatch([
        directory, item('folder/a.txt', 'a.txt', 10), item('folder/empty.txt', 'empty.txt', 0)
      ]);
      const store: SshSftpTaskStore = new SshSftpTaskStore();
      const result = store.enqueueBatch('host-1', 'upload', './remote', plan, 'batch-1');
      expect(result.accepted).assertTrue();
      expect(result.records.length).assertEqual(3);
      expect(store.listBatch('host-1', 'batch-1').length).assertEqual(3);
      expect(result.records[0].isDirectory).assertTrue();
      expect(result.records[0].remotePath).assertEqual('./remote/folder');
      expect(result.records[1].remotePath).assertEqual('./remote/folder/a.txt');
      expect(result.records[2].totalBytes).assertEqual(0);
      expect(store.command(result.records[0].taskId, { kind: 'complete' }).accepted).assertTrue();
      expect(store.get(result.records[0].taskId)?.stage).assertEqual('completed');
      expect(store.enqueueBatch('host-1', 'upload', './remote', plan, 'batch-1').accepted).assertFalse();

      const emptyPlan: SshSftpBatchPlan = planSshSftpBatch([{
        relativePath: 'empty', name: 'empty', isDirectory: true, isSymbolicLink: false,
        isSpecialFile: false, size: 0, mtime: 20, mode: 0, uid: -1, gid: -1
      }]);
      const emptyResult = store.enqueueBatch('host-1', 'upload', './remote', emptyPlan, 'batch-empty');
      expect(emptyResult.accepted).assertTrue();
      expect(emptyResult.records.length).assertEqual(1);
      expect(emptyResult.records[0].isDirectory).assertTrue();

      const downloadResult = store.enqueueBatch('host-1', 'download', './remote-source', plan,
        'batch-download');
      expect(downloadResult.accepted).assertTrue();
      expect(downloadResult.records[0].direction).assertEqual('download');
      expect(downloadResult.records[0].remotePath).assertEqual('./remote-source/folder');
      expect(downloadResult.records[1].remotePath).assertEqual('./remote-source/folder/a.txt');
    });

    it('persists explicit SSH endpoints and paths for remote batches', 0, (): void => {
      const plan: SshSftpBatchPlan = planSshSftpBatch([{
        relativePath: 'folder/empty.txt', name: 'empty.txt', isDirectory: false,
        isSymbolicLink: false, isSpecialFile: false, size: 0, mtime: 20,
        mode: 0, uid: -1, gid: -1
      }]);
      const store: SshSftpTaskStore = new SshSftpTaskStore();
      const result = store.enqueueRemoteBatch(
        'source-host', 'target-host', './source', './target', 'upload', plan, 'remote-1');
      expect(result.accepted).assertTrue();
      expect(result.records.length).assertEqual(1);
      const record: SshSftpTaskRecord = result.records[0];
      expect(record.hostId).assertEqual('target-host');
      expect(record.sourceEndpoint?.kind).assertEqual('ssh');
      expect(record.sourceEndpoint?.hostId).assertEqual('source-host');
      expect(record.targetEndpoint?.hostId).assertEqual('target-host');
      expect(record.sourcePath).assertEqual('./source/folder/empty.txt');
      expect(record.targetPath).assertEqual('./target/folder/empty.txt');
      expect(record.sessionGeneration).assertEqual(0);
      expect(record.schemaVersion).assertEqual(4);

      const transferring: SshSftpTaskRecord = {
        ...record,
        stage: 'transferring',
        verifiedOffset: 0,
        partialSize: -1,
        partialMtime: -1,
        sequence: record.sequence + 1,
        updatedAt: record.updatedAt + 1
      };
      expect(store.upsert(transferring)).assertTrue();
      expect(store.command(record.taskId, { kind: 'detach' }).accepted).assertTrue();
      const detached: SshSftpTaskRecord | null = store.get(record.taskId);
      expect(detached?.stage).assertEqual('waitingForConnection');
      expect(detached?.sourceEndpoint?.hostId).assertEqual('source-host');
      expect(detached?.targetEndpoint?.hostId).assertEqual('target-host');
      expect(detached?.sourcePath).assertEqual('./source/folder/empty.txt');
      expect(detached?.targetPath).assertEqual('./target/folder/empty.txt');

      const renaming: SshSftpTaskRecord = {
        ...detached as SshSftpTaskRecord,
        stage: 'committing',
        commitState: 'renaming',
        sequence: (detached as SshSftpTaskRecord).sequence + 1,
        updatedAt: (detached as SshSftpTaskRecord).updatedAt + 1
      };
      expect(store.upsert(renaming)).assertTrue();
      expect(store.command(record.taskId, { kind: 'detach' }).accepted).assertTrue();
      expect(store.get(record.taskId)?.commitState).assertEqual('renaming');

      const renamed: SshSftpTaskRecord = {
        ...store.get(record.taskId) as SshSftpTaskRecord,
        stage: 'committing',
        commitState: 'renamed',
        sequence: (store.get(record.taskId) as SshSftpTaskRecord).sequence + 1,
        updatedAt: (store.get(record.taskId) as SshSftpTaskRecord).updatedAt + 1
      };
      expect(store.upsert(renamed)).assertTrue();
      expect(store.get(record.taskId)?.commitState).assertEqual('renamed');
    });

    it('does not mistake a same-sized old target for a completed rename', 0, (): void => {
      expect(sshSftpCommitRecoveryDecision('renaming', 100, 100, 100))
        .assertEqual('retryRename');
      expect(sshSftpCommitRecoveryDecision('renaming', 100, 100, null))
        .assertEqual('complete');
      expect(sshSftpCommitRecoveryDecision('renaming', 100, 100, 40))
        .assertEqual('failed');
      expect(sshSftpCommitRecoveryDecision('renamed', 100, 100, null))
        .assertEqual('complete');
      expect(sshSftpCommitRecoveryDecision('renamed', 100, null, null))
        .assertEqual('failed');
      expect(sshSftpCommitRecoveryDecision('renaming', 100, 100, null, 0, -20))
        .assertEqual('failed');
      expect(sshSftpCommitRecoveryDecision('renamed', 100, 100, null, -20, 0))
        .assertEqual('failed');
    });

    it('rejects stale or non-ready native session snapshots before attach', 0, (): void => {
      const ready: SshSessionSnapshot = {
        schemaVersion: 1, errorCode: 0, sessionId: 7, generation: 3,
        channelId: 'shell', state: 3, stateName: 'Ready', eventSequence: 12,
        host: 'host-1', port: 22, backgroundLimited: false, lastEventType: 'ready'
      };
      const stale: SshSessionSnapshot = { ...ready, errorCode: -6 };
      const reconnecting: SshSessionSnapshot = {
        ...ready, state: 6, stateName: 'Reconnecting'
      };
      expect(sshSftpSessionSnapshotCanAttach(7, 3, 2, ready)).assertTrue();
      expect(sshSftpSessionSnapshotCanAttach(7, 2, 2, stale)).assertFalse();
      expect(sshSftpSessionSnapshotCanAttach(7, 2, 2, ready)).assertFalse();
      expect(sshSftpSessionSnapshotCanAttach(8, 3, 2, ready)).assertFalse();
      expect(sshSftpSessionSnapshotCanAttach(7, 3, 2, reconnecting)).assertFalse();
      expect(sshSftpSessionSnapshotCanAttach(7, 3, 1, ready)).assertFalse();
    });

    it('keeps a recovered owner when an old transport callback arrives late', 0, (): void => {
      const owners: SshSftpSessionOwnerPolicy = new SshSftpSessionOwnerPolicy();
      const oldOwner: SshSftpTrackedSession = owners.attach('host-1', 7, 3, 10);
      const recoveredOwner: SshSftpTrackedSession = owners.attach('host-1', 7, 3, 12);
      expect(recoveredOwner === oldOwner).assertFalse();
      expect(owners.detach(oldOwner)).assertFalse();
      expect(owners.markTransportLost(oldOwner)).assertFalse();
      expect(owners.current('host-1') === recoveredOwner).assertTrue();
      expect(owners.isCurrent('host-1', recoveredOwner)).assertTrue();
    });

    it('clears a loss marker only by attaching a new recovered owner', 0, (): void => {
      const owners: SshSftpSessionOwnerPolicy = new SshSftpSessionOwnerPolicy();
      const lostOwner: SshSftpTrackedSession = owners.attach('host-1', 7, 3, 10);
      expect(owners.markTransportLost(lostOwner)).assertTrue();
      expect(owners.current('host-1')).assertNull();
      const recoveredOwner: SshSftpTrackedSession = owners.attach('host-1', 7, 3, 12);
      expect(owners.isCurrent('host-1', recoveredOwner)).assertTrue();
      expect(owners.markTransportLost(lostOwner)).assertFalse();
      expect(owners.current('host-1') === recoveredOwner).assertTrue();
      expect(owners.detach(recoveredOwner)).assertTrue();
      expect(owners.current('host-1')).assertNull();
    });

    it('rejects only identical endpoint paths and allows same-host path copies', 0, (): void => {
      const sameHost: SftpEndpoint = { kind: 'ssh', hostId: 'same-host' };
      const samePath: SftpTransferSpec = {
        schemaVersion: 2,
        taskId: 'same-path',
        source: sameHost,
        target: sameHost,
        sourcePath: './data.txt',
        targetPath: './data.txt',
        direction: 'upload',
        checksumPolicy: 'size_mtime'
      };
      expect(sftpEndpointPathIsSame(sameHost, './data.txt', sameHost, './data.txt')).assertTrue();
      expect(isValidSftpTransferSpec(samePath)).assertFalse();

      const differentPath: SftpTransferSpec = {
        ...samePath,
        taskId: 'different-path',
        targetPath: './copy/data.txt'
      };
      expect(sftpEndpointPathIsSame(sameHost, differentPath.sourcePath,
        sameHost, differentPath.targetPath)).assertFalse();
      expect(isValidSftpTransferSpec(differentPath)).assertTrue();

      const plan: SshSftpBatchPlan = planSshSftpBatch([{
        relativePath: 'data.txt', name: 'data.txt', isDirectory: false,
        isSymbolicLink: false, isSpecialFile: false, size: 1, mtime: 20,
        mode: 0, uid: -1, gid: -1
      }]);
      const store: SshSftpTaskStore = new SshSftpTaskStore();
      expect(store.enqueueRemoteBatch('same-host', 'same-host', './source', './target',
        'upload', plan, 'same-host-copy').accepted).assertTrue();
      expect(store.enqueueRemoteBatch('same-host', 'same-host', './same', './same',
        'upload', plan, 'same-host-reject').accepted).assertFalse();
    });
  });
}
