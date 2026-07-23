import { describe, it, expect } from '@ohos/hypium';
import {
  shouldAcceptHostAddSave,
  pendingHostIdForHostAddSave,
  shouldStartHostAddConnectionAfterDisappear
} from '../main/ets/services/HostAddConnectionHandoffPolicy';

export default function hostAddConnectionHandoffPolicyTest(): void {
  describe('HostAddConnectionHandoffPolicy', (): void => {
    it('accepts_only_the_first_save_while_the_add_sheet_is_visible', 0, (): void => {
      expect(shouldAcceptHostAddSave(false, '')).assertTrue();
      expect(shouldAcceptHostAddSave(true, '')).assertFalse();
      expect(shouldAcceptHostAddSave(false, 'host-a')).assertFalse();
    });

    it('keeps_only_a_connect_now_host_id_for_sheet_handoff', 0, (): void => {
      expect(pendingHostIdForHostAddSave(true, 'host-a')).assertEqual('host-a');
      expect(pendingHostIdForHostAddSave(false, 'host-a')).assertEqual('');
      expect(pendingHostIdForHostAddSave(true, '')).assertEqual('');
    });

    it('starts_only_after_the_add_sheet_has_disappeared', 0, (): void => {
      expect(shouldStartHostAddConnectionAfterDisappear(true, false, 'host-a')).assertTrue();
      expect(shouldStartHostAddConnectionAfterDisappear(true, true, 'host-a')).assertFalse();
      expect(shouldStartHostAddConnectionAfterDisappear(false, false, 'host-a')).assertFalse();
      expect(shouldStartHostAddConnectionAfterDisappear(true, false, '')).assertFalse();
    });
  });
}
