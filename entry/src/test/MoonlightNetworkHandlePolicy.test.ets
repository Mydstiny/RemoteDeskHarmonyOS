import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightNetworkBinding,
  moonlightNetworkCallbackSessionId,
  moonlightNetIdIsValid,
  moonlightNetworkAvailableMatchesDefault,
  moonlightNetworkLostMatches,
  shouldResumeMoonlightInputAfterNetworkAvailable
} from '../main/ets/services/MoonlightNetworkHandlePolicy';

export default function moonlightNetworkHandlePolicyTest(): void {
  describe('MoonlightNetworkHandlePolicy', (): void => {
    it('matches_only_the_bound_harmony_network_and_native_session', 0, (): void => {
      const binding: MoonlightNetworkBinding = {
        ownerToken: 7001, nativeSessionId: 88, activeNetId: 100,
        unavailable: false
      };
      expect(moonlightNetIdIsValid(100)).assertTrue();
      expect(moonlightNetIdIsValid(0)).assertFalse();
      expect(moonlightNetworkLostMatches(binding, 100, 7001, 88)).assertTrue();
      expect(moonlightNetworkLostMatches(binding, 101, 7001, 88)).assertFalse();
      expect(moonlightNetworkLostMatches(binding, 100, 7002, 88)).assertFalse();
      expect(moonlightNetworkAvailableMatchesDefault(
        101, 101, 7001, 7001, 88, 88)).assertTrue();
      expect(moonlightNetworkAvailableMatchesDefault(
        100, 101, 7001, 7001, 88, 88)).assertFalse();
      expect(moonlightNetworkAvailableMatchesDefault(
        101, 101, 7002, 7001, 88, 88)).assertFalse();
      expect(moonlightNetworkCallbackSessionId(binding, 88, false)).assertEqual(88);
      expect(moonlightNetworkCallbackSessionId(binding, -1, true)).assertEqual(88);
      expect(moonlightNetworkCallbackSessionId(binding, -1, false)).assertEqual(-1);
      expect(moonlightNetworkLostMatches(
        binding, 100, 7001,
        moonlightNetworkCallbackSessionId(binding, -1, true))).assertTrue();
    });

    it('resumes_input_only_for_a_current_route_without_reconnect_work', 0, (): void => {
      expect(shouldResumeMoonlightInputAfterNetworkAvailable(
        true, false, false, true, true)).assertTrue();
      expect(shouldResumeMoonlightInputAfterNetworkAvailable(
        true, true, false, true, true)).assertFalse();
      expect(shouldResumeMoonlightInputAfterNetworkAvailable(
        true, false, false, true, false)).assertFalse();
    });
  });
}
