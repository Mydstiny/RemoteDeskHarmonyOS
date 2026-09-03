import { describe, it, expect } from '@ohos/hypium';
import {
  RDP_PREFLIGHT_DRAIN_POLL_INTERVAL_MS,
  rdpPreflightDrainMaximumPolls
} from '../main/ets/services/RdpPreflightScopeTransitionPolicy';

export default function rdpPreflightScopeTransitionPolicyTest(): void {
  describe('RdpPreflightScopeTransitionPolicy', (): void => {
    it('uses_a_fixed_poll_budget_that_wall_clock_rollback_cannot_extend', 0,
      (): void => {
        expect(rdpPreflightDrainMaximumPolls(10000)).assertEqual(501);
        expect(rdpPreflightDrainMaximumPolls(
          21, RDP_PREFLIGHT_DRAIN_POLL_INTERVAL_MS)).assertEqual(3);
        expect(rdpPreflightDrainMaximumPolls(0)).assertEqual(0);
        expect(rdpPreflightDrainMaximumPolls(-1)).assertEqual(0);
      });
  });
}
