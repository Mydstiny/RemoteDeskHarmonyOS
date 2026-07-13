import { describe, it, expect } from '@ohos/hypium';
import {
  canTransition,
  cancelTransfer,
  downloadResumeOffset,
  isRemoteCompletionConfirmed,
  recordConfirmedUploadWrite,
  shouldShowTransferCancelAction,
  transferProgressPanelHeight,
  TransferSession,
  uploadResumeOffset
} from '../main/ets/services/TransferSessionPolicy';
import { transferProtocolName } from '../main/ets/services/FileTransferProgressModel';

export default function transferSessionPolicyTest(): void {
  describe('TransferSessionPolicy', (): void => {
    it('allows_preparing_to_transferring', 0, (): void => {
      expect(canTransition('preparing', 'transferring')).assertTrue();
    });

    it('allows_waiting_remote_to_completed', 0, (): void => {
      expect(canTransition('waitingRemote', 'completed')).assertTrue();
    });

    it('does_not_treat_waiting_remote_as_a_confirmed_completion', 0, (): void => {
      expect(isRemoteCompletionConfirmed('waitingRemote')).assertFalse();
      expect(isRemoteCompletionConfirmed('completed')).assertTrue();
    });

    it('rejects_completed_to_transferring', 0, (): void => {
      expect(canTransition('completed', 'transferring')).assertFalse();
    });

    it('cancels_a_cancellable_transferring_session', 0, (): void => {
      const session: TransferSession = {
        id: 'ssh-upload-1', protocol: 'ssh', direction: 'upload', fileName: 'report.txt',
        totalBytes: 1024, transferredBytes: 512, stage: 'transferring', canCancel: true,
        diagnosticCode: ''
      };
      const cancelled: TransferSession = cancelTransfer(session);
      expect(cancelled.stage).assertEqual('cancelled');
      expect(cancelled.canCancel).assertFalse();
    });

    it('reserves_visible_space_for_cancellable_transfer_actions', 0, (): void => {
      const session: TransferSession = {
        id: 'ssh-upload-2', protocol: 'ssh', direction: 'upload', fileName: 'archive.zip',
        totalBytes: 1024, transferredBytes: 512, stage: 'transferring', canCancel: true,
        diagnosticCode: ''
      };
      expect(transferProgressPanelHeight(session)).assertEqual(116);
      expect(transferProgressPanelHeight(null)).assertEqual(70);
    });

    it('shows_the_cancel_action_for_active_transfer_sessions', 0, (): void => {
      const session: TransferSession = {
        id: 'ssh-upload-3', protocol: 'ssh', direction: 'upload', fileName: 'backup.zip',
        totalBytes: 1024, transferredBytes: 512, stage: 'transferring', canCancel: true,
        diagnosticCode: ''
      };
      expect(shouldShowTransferCancelAction(session)).assertTrue();
      expect(shouldShowTransferCancelAction(null)).assertFalse();
    });

    it('resumes_upload_from_the_native_confirmed_offset', 0, (): void => {
      expect(uploadResumeOffset(65536, 131072)).assertEqual(65536);
    });

    it('records_positive_partial_upload_writes_before_retrying', 0, (): void => {
      expect(recordConfirmedUploadWrite(65536, 32768, 65536)).assertEqual(98304);
    });

    it('rejects_upload_resume_when_the_source_shrank_below_confirmed_offset', 0, (): void => {
      expect(uploadResumeOffset(131072, 65536)).assertEqual(-1);
    });

    it('resumes_download_at_the_known_local_byte_count', 0, (): void => {
      expect(downloadResumeOffset(65536, 98304, 131072)).assertEqual(98304);
    });

    it('rejects_download_resume_when_the_local_file_exceeds_remote_total', 0, (): void => {
      expect(downloadResumeOffset(65536, 131073, 131072)).assertEqual(-1);
    });

    it('uses_ssh_as_the_ssh_transfer_display_name', 0, (): void => {
      expect(transferProtocolName('ssh')).assertEqual('SSH');
    });
  });
}
