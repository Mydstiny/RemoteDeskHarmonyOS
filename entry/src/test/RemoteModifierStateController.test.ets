import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import { RemoteModifierStateController } from '../main/ets/services/RemoteModifierStateController';

export default function remoteModifierStateControllerTest(): void {
  describe('RemoteModifierStateController_lifecycle_mirror', (): void => {
    it('focus_loss_disconnect_and_session_switch_clear_all_remote_mirror_bits', 0, (): void => {
      const mirror = new RemoteModifierStateController();
      mirror.setDown('ctrl', true);
      mirror.setDown('alt', true);
      expect(mirror.snapshot().ctrl).assertTrue();
      mirror.reset();
      expect(mirror.snapshot().ctrl).assertFalse();
      expect(mirror.snapshot().alt).assertFalse();
      mirror.setDown('ctrl', true);
      mirror.reset();
      expect(mirror.isDown('ctrl')).assertFalse();
    });
  });
}
