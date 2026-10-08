import { describe, it, expect } from '@ohos/hypium';
import { rustDeskFileFailureText, transferFailureReason, transferTaskCancellable,
  transferTaskDescription } from '../main/ets/services/TransferUserTextPolicy';
import { managedTransferSettled, managedTransferTerminal, recoverManagedTransferRecord,
  ManagedTransferRecord } from '../main/ets/services/ManagedTransferTaskPolicy';

export default function transferUserTextPolicyTest(): void {
  describe('TransferUserTextPolicy', (): void => {
    it('failures_say_what_happened_and_what_to_do', 0, (): void => {
      expect(transferTaskDescription({ stage: 'failed', direction: 'download', evidence: 'none',
        diagnosticCode: 'transfer_space_limit', queued: false })).assertEqual('未完成：本机存储空间不足，清理空间后重试');
      expect(transferTaskDescription({ stage: 'failed', direction: 'upload', evidence: 'none',
        diagnosticCode: 'some_internal_code', queued: false })).assertEqual('发送未完成，请重试');
      expect(transferFailureReason('unknown')).assertEqual('');
    });

    it('handed_off_queued_and_interrupted_tasks_read_plainly', 0, (): void => {
      expect(transferTaskDescription({ stage: 'handedOff', direction: 'upload', evidence: 'offered',
        diagnosticCode: 'target_write_unconfirmed', queued: false })).assertEqual('已交给远端，可在远端粘贴或保存');
      expect(transferTaskDescription({ stage: 'preparing', direction: 'upload', evidence: 'none',
        diagnosticCode: '', queued: true })).assertEqual('排队中，等前面的传输完成');
      expect(transferTaskDescription({ stage: 'interrupted', direction: 'download', evidence: 'none',
        diagnosticCode: 'interrupted', queued: false })).assertEqual('应用退出时传输中断，请重新传输');
    });

    it('saving_received_data_is_not_offered_for_cancel', 0, (): void => {
      expect(transferTaskCancellable('transferring')).assertTrue();
      expect(transferTaskCancellable('committing')).assertFalse();
      expect(transferTaskCancellable('handedOff')).assertFalse();
    });

    it('rustdesk_file_failures_name_the_cause_and_the_controlled_side_fix', 0, (): void => {
      expect(rustDeskFileFailureText('file_transfer:peer_prelogin', 'macos').indexOf('注销后重新登录') >= 0).assertTrue();
      expect(rustDeskFileFailureText('file_transfer:peer_file_service_unavailable', 'windows')
        .indexOf('托盘') >= 0).assertTrue();
      expect(rustDeskFileFailureText('file_transfer:remote_permission_denied', 'macos')
        .indexOf('完全磁盘访问权限') >= 0).assertTrue();
      expect(rustDeskFileFailureText('lost', 'unknown')).assertEqual('读取远端目录失败，请稍后重试。');
    });

    it('records_found_at_start_are_settled', 0, (): void => {
      const record: ManagedTransferRecord = new ManagedTransferRecord();
      record.stage = 'paused'; record.evidence = 'offered';
      expect(recoverManagedTransferRecord(record).stage).assertEqual('handedOff');
      record.evidence = 'none'; record.stage = 'transferring';
      expect(recoverManagedTransferRecord(record).stage).assertEqual('interrupted');
      expect(managedTransferTerminal('interrupted')).assertTrue();
      expect(managedTransferSettled('commitUnknown')).assertTrue();
      expect(managedTransferSettled('transferring')).assertFalse();
    });
  });
}
