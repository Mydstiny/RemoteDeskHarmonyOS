import { describe, it, expect } from '@ohos/hypium';
import { defaultRemotePortraitDisplayPreferences } from '../main/ets/services/RemotePortraitDisplayPreferencePolicy';
import {
  remotePortraitSidebarPlacement,
  remotePortraitSidebarProtocol
} from '../main/ets/services/RemotePortraitSidebarPolicy';

export default function remotePortraitSidebarPolicyTest(): void {
  describe('RemotePortraitSidebarPolicy', (): void => {
    it('keeps_the_action_hidden_for_disabled_protocols_and_non_phone_devices', 0, (): void => {
      const values = defaultRemotePortraitDisplayPreferences();
      values.rdp.enabled = true;
      const phone = remotePortraitSidebarPlacement(values, 'rdp', false, false);
      expect(phone.visible).assertTrue();
      expect(phone.side).assertEqual('right');
      expect(phone.safeAreaAware).assertTrue();
      expect(remotePortraitSidebarPlacement(values, 'rdp', false, true).visible).assertFalse();
      expect(remotePortraitSidebarPlacement(values, 'ssh', false, false).actionId).assertEqual('');
    });

    it('binds_the_layout_key_and_label_to_the_selected_mode', 0, (): void => {
      const values = defaultRemotePortraitDisplayPreferences();
      values.vnc.enabled = true;
      values.vnc.mode = 'portrait';
      const placement = remotePortraitSidebarPlacement(values, 'vnc', false, false);
      expect(placement.active).assertTrue();
      expect(placement.actionLabel).assertEqual('翻转：恢复横屏');
      expect(placement.layoutKey).assertEqual('remote-portrait-sidebar:vnc:portrait');
    });

    it('accepts_only_supported_portrait_protocols', 0, (): void => {
      expect(remotePortraitSidebarProtocol('moonlight')).assertEqual('moonlight');
      expect(remotePortraitSidebarProtocol('ssh')).assertEqual(null);
    });
  });
}
