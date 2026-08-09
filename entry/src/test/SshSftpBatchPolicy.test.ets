import { describe, it, expect } from '@ohos/hypium';
import {
  DEFAULT_SSH_SFTP_BATCH_LIMITS,
  SshSftpTreeItem,
  joinSshSftpRemotePath,
  normalizeSshSftpRemotePath,
  nextSshSftpKeepBothName,
  planSshSftpBatch,
  resolveSshSftpConflict
} from '../main/ets/services/SshSftpBatchPolicy';

function item(path: string, name: string, directory: boolean, size: number = 0): SshSftpTreeItem {
  return {
    relativePath: path,
    name,
    isDirectory: directory,
    isSymbolicLink: false,
    isSpecialFile: false,
    size,
    mtime: 1,
    mode: 0,
    uid: -1,
    gid: -1
  };
}

export default function sshSftpBatchPolicyTest(): void {
  describe('SshSftpBatchPolicy', (): void => {
    it('normalizes paths and rejects traversal', 0, (): void => {
      expect(normalizeSshSftpRemotePath('/a/./b/../c')).assertEqual('/a/c');
      expect(normalizeSshSftpRemotePath('../secret')).assertNull();
      expect(joinSshSftpRemotePath('/home/user', 'report.txt')).assertEqual('/home/user/report.txt');
      expect(joinSshSftpRemotePath('/home/user', '../report.txt')).assertNull();
      expect(joinSshSftpRemotePath('/home/user', 'a/b')).assertNull();
    });

    it('accepts directories and zero-byte files', 0, (): void => {
      const result = planSshSftpBatch([
        item('folder', 'folder', true),
        item('folder/empty.txt', 'empty.txt', false, 0)
      ]);
      expect(result.accepted).assertTrue();
      expect(result.fileCount).assertEqual(1);
      expect(result.totalBytes).assertEqual(0);
      expect(result.items.length).assertEqual(2);
    });

    it('rejects duplicates, unsafe types and limits', 0, (): void => {
      const duplicate = planSshSftpBatch([item('a.txt', 'a.txt', false), item('a.txt', 'a.txt', false)]);
      expect(duplicate.accepted).assertFalse();
      expect(duplicate.reason).assertEqual('duplicate-path');
      const link: SshSftpTreeItem = item('link', 'link', false);
      link.isSymbolicLink = true;
      expect(planSshSftpBatch([link]).reason).assertEqual('symbolic-link-not-allowed');
      const limited = planSshSftpBatch([item('big.bin', 'big.bin', false, 10)], {
        maxDepth: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxDepth,
        maxItems: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxItems,
        maxFiles: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxFiles,
        maxTotalBytes: 9,
        maxSingleFileBytes: 10,
        maxPathLength: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxPathLength,
        allowSymbolicLinks: false,
        allowSpecialFiles: false
      });
      expect(limited.reason).assertEqual('total-size-limit');
    });

    it('maps conflict policies without silently overwriting when asking', 0, (): void => {
      expect(resolveSshSftpConflict(true, false, 'ask').requiresDecision).assertTrue();
      expect(resolveSshSftpConflict(false, false, 'ask').action).assertEqual('overwrite');
      expect(resolveSshSftpConflict(false, true, 'resume').action).assertEqual('resume');
      expect(resolveSshSftpConflict(true, false, 'keepBoth').action).assertEqual('keepBoth');
      expect(resolveSshSftpConflict(true, false, 'skip').action).assertEqual('skip');
      expect(nextSshSftpKeepBothName('report.txt', ['report.txt', 'report (1).txt']))
        .assertEqual('report (2).txt');
      expect(nextSshSftpKeepBothName('.profile', ['.profile', '.profile (1)']))
        .assertEqual('.profile (2)');
    });
  });
}
