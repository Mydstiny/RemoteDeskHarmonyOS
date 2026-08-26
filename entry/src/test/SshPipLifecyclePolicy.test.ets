import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_PIP_EXIT_GRACE_MS,
  matchesSshPipExitFence,
  shouldCoordinateSshPipExit
} from '../main/ets/services/ssh/pip/SshPipLifecyclePolicy';

export default function sshPipLifecyclePolicyTest(): void {
  describe('SshPipLifecyclePolicy', (): void => {
    it('should_coordinate_only_a_main_window_with_owned_pip', 0, (): void => {
      expect(shouldCoordinateSshPipExit('', true)).assertTrue();
      expect(shouldCoordinateSshPipExit('session-window', true)).assertFalse();
      expect(shouldCoordinateSshPipExit('', false)).assertFalse();
      expect(SSH_PIP_EXIT_GRACE_MS > 0 && SSH_PIP_EXIT_GRACE_MS <= 1000).assertTrue();
    });

    it('should_reject_late_or_non_explicit_exit_callbacks', 0, (): void => {
      expect(matchesSshPipExitFence(7, 7, true, false)).assertTrue();
      expect(matchesSshPipExitFence(7, 8, true, false)).assertFalse();
      expect(matchesSshPipExitFence(7, 7, false, false)).assertFalse();
      expect(matchesSshPipExitFence(7, 7, true, true)).assertFalse();
      expect(matchesSshPipExitFence(0, 0, true, false)).assertFalse();
    });
  });
}
