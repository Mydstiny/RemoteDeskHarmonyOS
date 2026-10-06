import { describe, it, expect } from '@ohos/hypium';
import { rustDeskRelayDirectoryBottomClearance } from '../main/ets/services/RustDeskRelayLayoutPolicy';
import {
  resolveHostAddSheetContentMode,
  resolveHostAddSheetKeyboardAvoidMode
} from '../main/ets/services/HostAddSheetLayoutPolicy';

export default function rustDeskRelayLayoutPolicyTest(): void {
  describe('RustDeskRelayLayoutPolicy', (): void => {
    it('keeps_the_phone_list_clear_of_the_fab', 0, (): void => {
      expect(rustDeskRelayDirectoryBottomClearance('sm')).assertEqual(200);
      expect(rustDeskRelayDirectoryBottomClearance('md')).assertEqual(120);
    });

    it('vnc_gateway_add_follows_the_vnc_host_add_sheet', 0, (): void => {
      // The relay page asks the host-add policy for 'vnc', so the two VNC add sheets cannot drift apart again.
      for (const breakpoint of ['sm', 'md', 'xl']) {
        expect(resolveHostAddSheetContentMode('vnc', breakpoint)).assertEqual('fitContent');
        expect(resolveHostAddSheetKeyboardAvoidMode('vnc', breakpoint)).assertEqual('translateAndScroll');
      }
    });
  });
}
