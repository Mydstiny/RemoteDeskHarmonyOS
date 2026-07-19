import { describe, it, expect } from '@ohos/hypium';
import {
  nextConnectionAttemptGeneration,
  shouldBeginConnectionAttempt,
  shouldApplyConnectionAttempt
} from '../main/ets/services/ConnectionAttemptPolicy';

export default function connectionAttemptPolicyTest(): void {
  describe('ConnectionAttemptPolicy', (): void => {
    it('blocks_a_second_connection_while_one_host_is_pending', 0, (): void => {
      expect(shouldBeginConnectionAttempt('')).assertTrue();
      expect(shouldBeginConnectionAttempt('host-a')).assertFalse();
    });

    it('accepts_only_the_current_host_and_generation', 0, (): void => {
      expect(nextConnectionAttemptGeneration(0)).assertEqual(1);
      expect(shouldApplyConnectionAttempt(4, 4, 'host-a', 'host-a')).assertTrue();
      expect(shouldApplyConnectionAttempt(4, 3, 'host-a', 'host-a')).assertFalse();
      expect(shouldApplyConnectionAttempt(4, 4, 'host-a', 'host-b')).assertFalse();
    });
  });
}
