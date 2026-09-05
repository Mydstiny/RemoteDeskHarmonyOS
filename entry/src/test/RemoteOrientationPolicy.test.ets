import { describe, it, expect } from '@ohos/hypium';
import {
  canUseRustDeskAdaptiveOrientation,
  isRustDeskPhoneSessionForPeer,
  remoteOrientationRequestIsCurrent,
  rustDeskOrientationPolicy
} from '../main/ets/services/RemoteOrientationPolicy';

export default function remoteOrientationPolicyTest(): void {
  describe('RemoteOrientationPolicy', (): void => {
    it('defaults mobile RustDesk sessions to landscape until adaptive rotation is enabled', 0, (): void => {
      expect(rustDeskOrientationPolicy('rustdesk', false, true, false, false))
        .assertEqual('landscape');
      expect(rustDeskOrientationPolicy('rustdesk', false, true, false, true))
        .assertEqual('auto-rotate');
      expect(rustDeskOrientationPolicy('rustdesk', false, false, false, false, true))
        .assertEqual('landscape');
      expect(rustDeskOrientationPolicy('rustdesk', false, false, false, true, true))
        .assertEqual('auto-rotate');
    });

    it('keeps the existing policy for RDP, desktop and PIP', 0, (): void => {
      expect(rustDeskOrientationPolicy('rdp', false, true, false)).assertEqual('preserve-window');
      expect(rustDeskOrientationPolicy('rustdesk', true, true, false)).assertEqual('preserve-window');
      expect(rustDeskOrientationPolicy('rustdesk', false, true, true)).assertEqual('preserve-window');
    });

    it('accepts phone targets but rejects desktop Pro platforms', 0, (): void => {
      expect(canUseRustDeskAdaptiveOrientation('rustdesk', 'phone', true)).assertTrue();
      expect(canUseRustDeskAdaptiveOrientation('rustdesk', 'computer', true)).assertFalse();
      expect(canUseRustDeskAdaptiveOrientation('rustdesk', 'phone', true,
        'rustdesk_pro', true, 'Windows')).assertFalse();
      expect(canUseRustDeskAdaptiveOrientation('rustdesk', 'phone', true,
        'rustdesk_pro', true, 'Android')).assertTrue();
      expect(canUseRustDeskAdaptiveOrientation('vnc', 'phone', true)).assertFalse();
    });

    it('uses authenticated peer platform before the local phone fallback', 0, (): void => {
      expect(isRustDeskPhoneSessionForPeer('computer', 'android')).assertTrue();
      expect(isRustDeskPhoneSessionForPeer('phone', 'windows')).assertFalse();
      expect(isRustDeskPhoneSessionForPeer('phone', 'unknown')).assertTrue();
      expect(isRustDeskPhoneSessionForPeer('computer', 'other')).assertFalse();
    });

    it('lets only the newest asynchronous orientation request publish state', 0, (): void => {
      expect(remoteOrientationRequestIsCurrent(7, 8)).assertFalse();
      expect(remoteOrientationRequestIsCurrent(8, 8)).assertTrue();
      expect(remoteOrientationRequestIsCurrent(0, 0)).assertFalse();
    });
  });
}
