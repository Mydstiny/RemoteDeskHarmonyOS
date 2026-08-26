import { describe, it, expect } from '@ohos/hypium';
import { resolveHostAddSheetHeightMode } from '../main/ets/services/HostAddSheetLayoutPolicy';

export default function hostAddSheetLayoutPolicyTest(): void {
  describe('HostAddSheetLayoutPolicy', (): void => {
    it('keeps_phone_vnc_and_ssh_sheets_intrinsic', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('vnc', 'sm')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('ssh', 'sm')).assertEqual('fit');
    });

    it('keeps_long_flows_large_on_pad_and_pc', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('vnc', 'md')).assertEqual('large');
      expect(resolveHostAddSheetHeightMode('ssh', 'lg')).assertEqual('large');
      expect(resolveHostAddSheetHeightMode('vnc', 'xl')).assertEqual('large');
    });

    it('keeps_other_host_add_flows_intrinsic', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('', 'sm')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('rdp', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('rustdesk', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('moonlight', 'xl')).assertEqual('fit');
    });
  });
}
