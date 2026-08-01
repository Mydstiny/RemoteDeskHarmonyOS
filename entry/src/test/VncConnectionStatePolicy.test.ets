import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_CONNECTION_STARTUP_GRACE_MS,
  shouldTreatVncConnectionStateAsTerminal
} from '../main/ets/services/VncConnectionStatePolicy';

export default function vncConnectionStatePolicyTest(): void {
  describe('VncConnectionStatePolicy', (): void => {
    it('does_not_treat_initial_disconnected_as_failure_during_startup', 0, (): void => {
      expect(shouldTreatVncConnectionStateAsTerminal(0, false,
        VNC_CONNECTION_STARTUP_GRACE_MS - 1)).assertFalse();
    });

    it('treats_disconnected_as_failure_after_connecting_was_seen', 0, (): void => {
      expect(shouldTreatVncConnectionStateAsTerminal(0, true, 1)).assertTrue();
    });

    it('treats_error_and_expired_startup_as_terminal', 0, (): void => {
      expect(shouldTreatVncConnectionStateAsTerminal(4, false, 0)).assertTrue();
      expect(shouldTreatVncConnectionStateAsTerminal(0, false,
        VNC_CONNECTION_STARTUP_GRACE_MS)).assertTrue();
    });
  });
}
