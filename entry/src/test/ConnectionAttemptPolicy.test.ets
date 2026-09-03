import { describe, it, expect } from '@ohos/hypium';
import {
  allocateConnectionAttemptGeneration,
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

    it('does_not_reuse_attempt_tokens_across_component_instances', 0, (): void => {
      const first: number = allocateConnectionAttemptGeneration();
      const second: number = allocateConnectionAttemptGeneration();
      expect(first > 0).assertTrue();
      expect(second > 0).assertTrue();
      expect(second === first).assertFalse();
    });
  });
}
