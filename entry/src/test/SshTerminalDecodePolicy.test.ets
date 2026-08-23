import { describe, expect, it } from '@ohos/hypium';
import { sshTerminalDecodeStateNeedsReset } from
  '../main/ets/services/ssh/terminal/SshTerminalDecodePolicy';

export default function sshTerminalDecodePolicyTest(): void {
  describe('SshTerminalDecodePolicy', (): void => {
    it('should_keep_utf8_remainder_for_the_same_session_generation', 0, (): void => {
      expect(sshTerminalDecodeStateNeedsReset(41, 7, 41, 7)).assertFalse();
    });

    it('should_reset_remainder_when_generation_or_session_changes', 0, (): void => {
      expect(sshTerminalDecodeStateNeedsReset(41, 7, 41, 8)).assertTrue();
      expect(sshTerminalDecodeStateNeedsReset(41, 7, 42, 1)).assertTrue();
    });

    it('should_reset_before_reconnect_publishes_the_next_identity', 0, (): void => {
      expect(sshTerminalDecodeStateNeedsReset(41, 7, -1, 0)).assertTrue();
      expect(sshTerminalDecodeStateNeedsReset(0, 0, -1, 0)).assertFalse();
    });
  });
}
