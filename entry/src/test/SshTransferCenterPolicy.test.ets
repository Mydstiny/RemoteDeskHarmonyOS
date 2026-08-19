import { describe, it, expect } from '@ohos/hypium';
import { SshSftpTaskRecord } from '../main/ets/services/SshSftpTaskPolicy';
import {
  buildSshTransferCenterViews,
  canExecuteSshTransferCenterAction,
  summarizeSshTransferCenter,
  SshTransferCenterTaskView
} from '../main/ets/services/ssh/sftp/SshTransferCenterPolicy';

function task(id: string, stage: SshSftpTaskRecord['stage'], hostId: string = 'host-secret'):
  SshSftpTaskRecord {
  return {
    schemaVersion: 4,
    taskId: id,
    batchId: '',
    relativePath: 'private/relative',
    hostId,
    direction: 'upload',
    isDirectory: false,
    remotePath: '/private/remote/' + id,
    fileName: id + '.bin',
    totalBytes: 100,
    verifiedOffset: 25,
    sourceSize: 100,
    sourceMtime: 1,
    partialSize: 25,
    partialMtime: 1,
    sessionGeneration: 3,
    sequence: 1,
    stage,
    updatedAt: stage === 'failed' ? 20 : 10,
    sourceEndpoint: { kind: 'local' },
    targetEndpoint: { kind: 'ssh', hostId },
    sourcePath: '/private/local/' + id,
    targetPath: '/private/remote/' + id,
    checksumPolicy: 'size_mtime'
  };
}

export default function sshTransferCenterPolicyTest(): void {
  describe('SshTransferCenterPolicy', (): void => {
    it('projects_tasks_without_paths_addresses_or_raw_host_ids', 0, (): void => {
      const views: Array<SshTransferCenterTaskView> = buildSshTransferCenterViews(
        [task('upload-1', 'transferring')],
        [{ hostId: 'host-secret', alias: 'Production' }]);
      const encoded: string = JSON.stringify(views);
      expect(encoded.indexOf('/private/')).assertEqual(-1);
      expect(encoded.indexOf('host-secret')).assertEqual(-1);
      expect(encoded.indexOf('Production') >= 0).assertTrue();
      expect(views[0].progress).assertEqual(0.25);
    });

    it('sorts_attention_before_active_and_terminal_and_filters_deterministically', 0,
      (): void => {
        const records: Array<SshSftpTaskRecord> = [
          task('done', 'completed'), task('running', 'transferring'), task('failed', 'failed')
        ];
        const all = buildSshTransferCenterViews(records, []);
        expect(all[0].taskId).assertEqual('failed');
        expect(all[1].taskId).assertEqual('running');
        expect(all[2].taskId).assertEqual('done');
        expect(buildSshTransferCenterViews(records, [], 'active')[0].taskId).assertEqual('running');
        expect(buildSshTransferCenterViews(records, [], 'attention')[0].taskId).assertEqual('failed');
        expect(buildSshTransferCenterViews(records, [], 'completed')[0].taskId).assertEqual('done');
      });

    it('exposes_only_stage_valid_actions_and_summary_counts', 0, (): void => {
      const records: Array<SshSftpTaskRecord> = [
        task('paused', 'paused'), task('failed', 'failed'), task('done', 'completed')
      ];
      const views = buildSshTransferCenterViews(records, []);
      const paused = views.find((view: SshTransferCenterTaskView): boolean => view.taskId === 'paused');
      const failed = views.find((view: SshTransferCenterTaskView): boolean => view.taskId === 'failed');
      const done = views.find((view: SshTransferCenterTaskView): boolean => view.taskId === 'done');
      expect(paused !== undefined && canExecuteSshTransferCenterAction(paused!, 'resume')).assertTrue();
      expect(failed !== undefined && canExecuteSshTransferCenterAction(failed!, 'retry')).assertTrue();
      expect(done !== undefined && canExecuteSshTransferCenterAction(done!, 'clear')).assertTrue();
      expect(done !== undefined && canExecuteSshTransferCenterAction(done!, 'cancel')).assertFalse();
      const summary = summarizeSshTransferCenter(records);
      expect(summary.active).assertEqual(0);
      expect(summary.attention).assertEqual(2);
      expect(summary.completed).assertEqual(1);
    });
  });
}
