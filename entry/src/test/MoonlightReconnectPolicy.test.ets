import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  createMoonlightReconnectWindow,
  moonlightReconnectAfterFailure,
  moonlightReconnectAttemptTimeoutMs,
  moonlightReconnectDecision,
  moonlightReconnectWindowIsCurrent
} from '../main/ets/services/MoonlightReconnectPolicy';

export default function moonlightReconnectPolicyTest(): void {
  describe('MoonlightReconnectPolicy', (): void => {
    it('uses_a_finite_budget_and_deterministic_backoff', 0, (): void => {
      let window = createMoonlightReconnectWindow(true, 15500, 1000, 7);
      let decision = moonlightReconnectDecision(window, 1000, true);
      expect(decision.action).assertEqual('attempt');
      expect(decision.attemptNumber).assertEqual(1);
      expect(moonlightReconnectAttemptTimeoutMs(decision)).assertEqual(5000);
      window = moonlightReconnectAfterFailure(window, 1100);
      decision = moonlightReconnectDecision(window, 1200, true);
      expect(decision.action).assertEqual('wait_backoff');
      expect(decision.delayMs).assertEqual(150);
      decision = moonlightReconnectDecision(window, 1350, true);
      expect(decision.action).assertEqual('attempt');
      expect(decision.attemptNumber).assertEqual(2);
    });

    it('waits_for_network_without_extending_the_deadline', 0, (): void => {
      const window = createMoonlightReconnectWindow(true, 1000, 5000, 3);
      expect(moonlightReconnectDecision(window, 5200, false).action)
        .assertEqual('wait_network');
      expect(moonlightReconnectDecision(window, 6000, true).action)
        .assertEqual('give_up');
    });

    it('rejects_disabled_invalid_and_stale_windows', 0, (): void => {
      const disabled = createMoonlightReconnectWindow(false, 15500, 1, 1);
      expect(moonlightReconnectDecision(disabled, 1, true).action).assertEqual('give_up');
      const invalid = createMoonlightReconnectWindow(true, -1, 1, 1);
      expect(invalid.enabled).assertFalse();
      const active = createMoonlightReconnectWindow(true, 500, 1, 9);
      expect(moonlightReconnectWindowIsCurrent(active, 9)).assertTrue();
      expect(moonlightReconnectWindowIsCurrent(active, 10)).assertFalse();
    });
  });
}
