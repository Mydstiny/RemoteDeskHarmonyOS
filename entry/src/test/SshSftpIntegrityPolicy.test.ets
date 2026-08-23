import { describe, it, expect } from '@ohos/hypium';
import {
  sshSftpCommittedDisposition,
  sshSftpCommitSizeMatches,
  sshSftpFinalUriFromPartial,
  sshSftpIdentityMatches,
  sshSftpLocalExportShouldContinue,
  sshSftpOffsetIsValid,
  sshSftpPartialSuffix,
  sshSftpSkipRemovalDecision
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

    it('commits a successful conflict skip after a same-attempt stop', 0, (): void => {
      const decision = sshSftpSkipRemovalDecision(0, true, true);
      expect(decision.committedSkip).assertTrue();
      expect(decision.clearCheckpoint).assertTrue();
      expect(decision.publishError).assertFalse();
    });

    it('does not apply a stale skip result to a replacement attempt', 0, (): void => {
      const decision = sshSftpSkipRemovalDecision(0, false, true);
      expect(decision.committedSkip).assertFalse();
      expect(decision.clearCheckpoint).assertFalse();
      expect(decision.publishError).assertFalse();
    });

    it('publishes removal errors only for the active request', 0, (): void => {
      expect(sshSftpSkipRemovalDecision(-5, true, false).publishError).assertTrue();
      expect(sshSftpSkipRemovalDecision(-5, true, true).publishError).assertFalse();
      expect(sshSftpSkipRemovalDecision(-5, false, false).publishError).assertFalse();
    });

    it('keeps successful remote commits completed when stop requests arrive late', 0, (): void => {
      expect(sshSftpCommittedDisposition(false, false, false)).assertEqual('normal');
      expect(sshSftpCommittedDisposition(true, false, false)).assertEqual('request-stale');
      expect(sshSftpCommittedDisposition(true, true, false))
        .assertEqual('cancelled-after-commit');
      expect(sshSftpCommittedDisposition(true, false, true))
        .assertEqual('paused-after-commit');
      expect(sshSftpCommittedDisposition(false, false, true))
        .assertEqual('paused-after-commit');
      expect(sshSftpCommittedDisposition(false, true, true))
        .assertEqual('cancelled-after-commit');
    });

    it('finishes only the current local export after its truncate boundary', 0, (): void => {
      expect(sshSftpLocalExportShouldContinue(false, true, false)).assertTrue();
      expect(sshSftpLocalExportShouldContinue(false, true, true)).assertFalse();
      expect(sshSftpLocalExportShouldContinue(true, true, true)).assertTrue();
      expect(sshSftpLocalExportShouldContinue(true, false, false)).assertFalse();
      expect(sshSftpLocalExportShouldContinue(true, false, true)).assertFalse();
    });
  });
}
