import { describe, it, expect } from '@ohos/hypium';
import {
  sshSftpCommitSizeMatches,
  sshSftpFinalUriFromPartial,
  sshSftpIdentityMatches,
  sshSftpOffsetIsValid,
  sshSftpPartialSuffix
} from '../main/ets/services/SshSftpIntegrityPolicy';

export default function sshSftpIntegrityPolicyTest(): void {
  describe('SshSftpIntegrityPolicy', (): void => {
    it('accepts zero-byte transfers and exact commits', 0, (): void => {
      expect(sshSftpOffsetIsValid(0, 0)).assertTrue();
      expect(sshSftpCommitSizeMatches(0, 0)).assertTrue();
      expect(sshSftpOffsetIsValid(1, 0)).assertFalse();
    });

    it('requires both source size and mtime for resume identity', 0, (): void => {
      const identity = { size: 10, mtime: 20 };
      expect(sshSftpIdentityMatches(identity, { size: 10, mtime: 20 })).assertTrue();
      expect(sshSftpIdentityMatches(identity, { size: 11, mtime: 20 })).assertFalse();
      expect(sshSftpIdentityMatches(identity, { size: 10, mtime: 21 })).assertFalse();
      expect(sshSftpIdentityMatches(identity, { size: 10, mtime: -1 })).assertFalse();
      expect(sshSftpIdentityMatches(identity, { size: Number.NaN, mtime: 20 })).assertFalse();
      expect(sshSftpIdentityMatches(identity, { size: 10, mtime: Number.NaN })).assertFalse();
    });

    it('derives a final URI only from the generated suffix', 0, (): void => {
      const suffix = sshSftpPartialSuffix('ssh-download-12');
      const partial = 'file://cache/report.txt' + suffix;
      expect(sshSftpFinalUriFromPartial(partial, suffix)).assertEqual('file://cache/report.txt');
      expect(sshSftpFinalUriFromPartial('file://cache/report.txt', suffix)).assertEqual('');
    });
  });
}
