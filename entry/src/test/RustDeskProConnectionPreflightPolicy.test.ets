import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen
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
  });
}
