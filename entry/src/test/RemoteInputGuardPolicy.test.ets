import { describe, it, expect } from '@ohos/hypium';
import {
  remoteInputBlockedReason,
  shouldBlockRemoteInputForBrowseMode
} from '../main/ets/services/RemoteInputGuardPolicy';

export default function remoteInputGuardPolicyTest(): void {
  describe('RemoteInputGuardPolicy_browseMode', (): void => {
    it('should_block_only_rustdesk_input_when_browse_mode_is_enabled', 0, (): void => {
      expect(shouldBlockRemoteInputForBrowseMode('rustdesk', true)).assertTrue();
      expect(shouldBlockRemoteInputForBrowseMode('rustdesk', false)).assertFalse();
      expect(shouldBlockRemoteInputForBrowseMode('rdp', true)).assertFalse();
      expect(shouldBlockRemoteInputForBrowseMode('ssh', true)).assertFalse();
    });

    it('should_explain_why_input_is_blocked', 0, (): void => {
      const reason = remoteInputBlockedReason('rustdesk', true);
      expect(reason.length > 0).assertTrue();
      expect(remoteInputBlockedReason('rustdesk', false)).assertEqual('');
      expect(remoteInputBlockedReason('rdp', true)).assertEqual('');
    });
  });
}
