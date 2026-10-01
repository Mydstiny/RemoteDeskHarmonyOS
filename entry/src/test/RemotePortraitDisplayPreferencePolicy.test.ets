import { describe, it, expect } from '@ohos/hypium';
import {
  applyRemotePortraitDisplayPreferenceUpdate,
  defaultRemotePortraitDisplayPreferences,
  migrateRemotePortraitDisplayPreferences,
  remotePortraitDisplayActionLabel,
  remotePortraitDisplayActionVisible,
  remotePortraitDisplayActive,
  remotePortraitDisplayPreference,
  remotePortraitDisplaySelectionSummary,
  RemotePortraitDisplayPreferencePresence,
  RemotePortraitDisplayPreferenceUpdate
} from '../main/ets/services/RemotePortraitDisplayPreferencePolicy';

function noPresence(): RemotePortraitDisplayPreferencePresence {
  return {
    rdpEnabled: false, rdpMode: false, rustdeskEnabled: false, rustdeskMode: false,
    vncEnabled: false, vncMode: false, moonlightEnabled: false, moonlightMode: false
  };
}

export default function remotePortraitDisplayPreferencePolicyTest(): void {
  describe('RemotePortraitDisplayPreferencePolicy', (): void => {
    it('defaults_all_four_protocols_to_off_and_keeps_ssh_out', 0, (): void => {
      const values = defaultRemotePortraitDisplayPreferences();
      expect(remotePortraitDisplaySelectionSummary(values)).assertEqual('未选择协议');
      expect(remotePortraitDisplayPreference(values, 'ssh').enabled).assertFalse();
      expect(remotePortraitDisplayActionVisible(values, 'ssh', false, false)).assertFalse();
    });

    it('migrates_missing_keys_without_enabling_or_locking_a_window', 0, (): void => {
      const values = migrateRemotePortraitDisplayPreferences(
        defaultRemotePortraitDisplayPreferences(), noPresence(), 0);
      expect(values.rdp.enabled).assertFalse();
      expect(values.rdp.mode).assertEqual('default');
      expect(values.moonlight.enabled).assertFalse();
    });

    it('keeps_touched_fields_and_does_not_revert_other_protocols', 0, (): void => {
      const current = defaultRemotePortraitDisplayPreferences();
      current.rdp.enabled = true;
      current.rdp.mode = 'portrait';
      const stale: RemotePortraitDisplayPreferenceUpdate = {
        values: defaultRemotePortraitDisplayPreferences(),
        touched: {
          rdpEnabled: false, rdpMode: false,
          rustdeskEnabled: true, rustdeskMode: true,
          vncEnabled: false, vncMode: false,
          moonlightEnabled: false, moonlightMode: false
        }
      };
      stale.values.rustdesk.enabled = true;
      stale.values.rustdesk.mode = 'portrait';
      const merged = applyRemotePortraitDisplayPreferenceUpdate(current, stale);
      expect(merged.rdp.enabled).assertTrue();
      expect(merged.rdp.mode).assertEqual('portrait');
      expect(merged.rustdesk.mode).assertEqual('portrait');
      expect(remotePortraitDisplaySelectionSummary(merged)).assertEqual('已开启：RDP、RustDesk');
    });

    it('shows_the_action_only_for_enabled_phone_protocols', 0, (): void => {
      const values = defaultRemotePortraitDisplayPreferences();
      values.vnc.enabled = true;
      values.vnc.mode = 'portrait';
      expect(remotePortraitDisplayActionVisible(values, 'vnc', false, false)).assertTrue();
      expect(remotePortraitDisplayActionVisible(values, 'vnc', true, false)).assertFalse();
      expect(remotePortraitDisplayActive(values, 'vnc', false, false)).assertTrue();
      expect(remotePortraitDisplayActive(values, 'vnc', false, true)).assertFalse();
      expect(remotePortraitDisplayActionLabel(true)).assertEqual('翻转：恢复横屏');
      expect(remotePortraitDisplayActionLabel(false)).assertEqual('翻转：竖屏显示');
    });
  });
}
