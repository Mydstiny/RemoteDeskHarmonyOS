import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen,
  rustDeskProPeerIdForConnection
} from '../main/ets/services/RustDeskProConnectionPreflightPolicy';

export default function rustDeskProConnectionPreflightPolicyTest(): void {
  describe('RustDeskProConnectionPreflightPolicy', (): void => {
    it('routes_only_after_real_authentication_succeeds', 0, (): void => {
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.IDLE)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.CONNECTING)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.ERROR)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.AUTHENTICATED)).assertTrue();
    });

    it('keeps_portrait_sheet_available_after_authentication_failure', 0, (): void => {
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.CONNECTING)).assertTrue();
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.ERROR)).assertTrue();
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.AUTHENTICATED)).assertFalse();
    });

    it('passes_the_stable_pro_peer_id_to_native_connection', 0, (): void => {
      expect(rustDeskProPeerIdForConnection('123456789', '')).assertEqual('123456789');
      expect(rustDeskProPeerIdForConnection('', '987654321')).assertEqual('987654321');
    });
  });
}
