/**
 * FileTransferProgressModel.test.ets — RDP/RustDesk 传输进度模型测试
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  clampTransferProgress,
  createTransferSnapshot,
  makeTransferStatusText,
  makeTransferTitle
} from '../../../main/ets/services/FileTransferProgressModel';

export default function fileTransferProgressModelTest() {
  describe('FileTransferProgressModel', () => {
    it('clamp_progress_should_stay_between_zero_and_one_hundred', 0, () => {
      expect(clampTransferProgress(0, 100)).assertEqual(0);
      expect(clampTransferProgress(1, 3)).assertEqual(33);
      expect(clampTransferProgress(999, 1000)).assertEqual(99);
      expect(clampTransferProgress(1000, 1000)).assertEqual(100);
      expect(clampTransferProgress(1200, 1000)).assertEqual(100);
      expect(clampTransferProgress(1, 0)).assertEqual(0);
    });

    it('snapshot_status_should_use_protocol_and_state', 0, () => {
      const snap = createTransferSnapshot('t1', 'rustdesk', 'demo.zip', 50, 100, 'transferring');
      expect(snap.progressValue).assertEqual(50);
      expect(makeTransferTitle('rustdesk', 'transferring')).assertEqual('RustDesk 文件传输');
      expect(makeTransferStatusText(snap)).assertEqual('正在传输 demo.zip 50%');
      expect(makeTransferTitle('rdp', 'completed')).assertEqual('RDP 文件传输完成');
    });
  });
}
