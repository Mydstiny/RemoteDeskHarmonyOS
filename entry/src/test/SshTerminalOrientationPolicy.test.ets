import { describe, it, expect } from '@ohos/hypium';
import {
  defaultSshTerminalOrientation,
  toggleSshTerminalOrientation
} from '../main/ets/services/SshTerminalOrientationPolicy';

export default function sshTerminalOrientationPolicyTest(): void {
  describe('SshTerminalOrientationPolicy', (): void => {
    it('uses_portrait_as_mobile_default_and_system_on_desktop', 0, (): void => {
      expect(defaultSshTerminalOrientation(false)).assertEqual('portrait');
      expect(defaultSshTerminalOrientation(true)).assertEqual('system');
    });

    it('toggles_between_portrait_and_landscape', 0, (): void => {
      expect(toggleSshTerminalOrientation('portrait')).assertEqual('landscape');
      expect(toggleSshTerminalOrientation('landscape')).assertEqual('portrait');
      expect(toggleSshTerminalOrientation('system')).assertEqual('landscape');
    });
  });
}
