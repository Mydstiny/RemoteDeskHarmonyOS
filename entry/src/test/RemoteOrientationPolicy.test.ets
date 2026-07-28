import { describe, it, expect } from '@ohos/hypium';
import { rustDeskOrientationPolicy } from '../main/ets/services/RemoteOrientationPolicy';

export default function remoteOrientationPolicyTest(): void {
  describe('RemoteOrientationPolicy', (): void => {
    it('follows orientation for a foreground mobile RustDesk session', 0, (): void => {
      expect(rustDeskOrientationPolicy('rustdesk', false, true, false)).assertEqual('auto-rotate');
    });

    it('keeps the existing policy for RDP, desktop and PIP', 0, (): void => {
      expect(rustDeskOrientationPolicy('rdp', false, true, false)).assertEqual('preserve-window');
      expect(rustDeskOrientationPolicy('rustdesk', true, true, false)).assertEqual('preserve-window');
      expect(rustDeskOrientationPolicy('rustdesk', false, true, true)).assertEqual('preserve-window');
    });
  });
}
