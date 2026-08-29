import { describe, it, expect } from '@ohos/hypium';
import {
  MOONLIGHT_REVERSE_WHEEL_KEY,
  RDP_REVERSE_WHEEL_KEY,
  REMOTE_WHEEL_PREFERENCE_VERSION,
  RUSTDESK_REVERSE_WHEEL_KEY,
  SSH_REVERSE_WHEEL_KEY,
  VNC_REVERSE_WHEEL_KEY,
  RemoteWheelPreferencePresence,
  RemoteWheelPreferenceUpdate,
  RemoteWheelPreferences,
  applyRemoteWheelPreferenceUpdate,
  defaultRemoteWheelPreferences,
  migrateRemoteWheelPreferences,
  remoteWheelPreference,
  remoteWheelPreferenceKey,
  remoteWheelSelectionSummary,
  withRemoteWheelPreference
} from '../main/ets/services/RemoteWheelPreferencePolicy';

function noPreferencesPresent(): RemoteWheelPreferencePresence {
  return { rdp: false, rustdesk: false, ssh: false, vnc: false, moonlight: false };
}

export default function remoteWheelPreferencePolicyTest(): void {
  describe('RemoteWheelPreferencePolicy', (): void => {
    it('maps_each_protocol_to_one_device_local_key', 0, (): void => {
      expect(remoteWheelPreferenceKey('rdp')).assertEqual(RDP_REVERSE_WHEEL_KEY);
      expect(remoteWheelPreferenceKey('rustdesk')).assertEqual(RUSTDESK_REVERSE_WHEEL_KEY);
      expect(remoteWheelPreferenceKey('ssh')).assertEqual(SSH_REVERSE_WHEEL_KEY);
      expect(remoteWheelPreferenceKey('vnc')).assertEqual(VNC_REVERSE_WHEEL_KEY);
      expect(remoteWheelPreferenceKey('moonlight')).assertEqual(MOONLIGHT_REVERSE_WHEEL_KEY);
    });

    it('splits_the_explicit_legacy_shared_value_only_across_its_old_protocols', 0,
      (): void => {
        const current: RemoteWheelPreferences = defaultRemoteWheelPreferences();
        current.rustdesk = true;
        const present: RemoteWheelPreferencePresence = noPreferencesPresent();
        present.rustdesk = true;
        const migration = migrateRemoteWheelPreferences(current, present, 0, false);
        expect(migration.values.rdp).assertTrue();
        expect(migration.values.rustdesk).assertTrue();
        expect(migration.values.vnc).assertTrue();
        expect(migration.values.ssh).assertFalse();
        expect(migration.values.moonlight).assertFalse();
        expect(migration.shouldPersist).assertTrue();
        expect(migration.version).assertEqual(REMOTE_WHEEL_PREFERENCE_VERSION);
      });

    it('uses_the_old_vnc_payload_only_when_the_shared_key_was_absent', 0, (): void => {
      const migration = migrateRemoteWheelPreferences(
        defaultRemoteWheelPreferences(), noPreferencesPresent(), 0, true);
      expect(migration.values.vnc).assertTrue();
      expect(migration.values.rdp).assertFalse();
      expect(migration.values.rustdesk).assertFalse();
    });

    it('never_overwrites_existing_protocol_specific_choices', 0, (): void => {
      const current: RemoteWheelPreferences = {
        rdp: false, rustdesk: true, ssh: true, vnc: false, moonlight: true
      };
      const present: RemoteWheelPreferencePresence = {
        rdp: true, rustdesk: true, ssh: true, vnc: true, moonlight: true
      };
      const migration = migrateRemoteWheelPreferences(
        current, present, REMOTE_WHEEL_PREFERENCE_VERSION, true);
      expect(migration.values.rdp).assertFalse();
      expect(migration.values.rustdesk).assertTrue();
      expect(migration.values.ssh).assertTrue();
      expect(migration.values.vnc).assertFalse();
      expect(migration.values.moonlight).assertTrue();
      expect(migration.shouldPersist).assertFalse();
    });

    it('updates_only_the_selected_protocol_and_reports_a_stable_summary', 0, (): void => {
      let values: RemoteWheelPreferences = defaultRemoteWheelPreferences();
      expect(remoteWheelSelectionSummary(values)).assertEqual('全部协议正常');
      values = withRemoteWheelPreference(values, 'rdp', true);
      values = withRemoteWheelPreference(values, 'vnc', true);
      expect(remoteWheelPreference(values, 'rdp')).assertTrue();
      expect(remoteWheelPreference(values, 'rustdesk')).assertFalse();
      expect(remoteWheelSelectionSummary(values)).assertEqual('已反转：RDP、VNC');
      values = { rdp: true, rustdesk: true, ssh: true, vnc: true, moonlight: true };
      expect(remoteWheelSelectionSummary(values)).assertEqual('全部协议反转');
      expect(remoteWheelPreference(values, 'unknown')).assertFalse();
    });

    it('merges_a_stale_editor_draft_without_reverting_untouched_protocols', 0,
      (): void => {
        const latest: RemoteWheelPreferences = {
          rdp: true, rustdesk: false, ssh: true, vnc: false, moonlight: false
        };
        const staleUpdate: RemoteWheelPreferenceUpdate = {
          values: {
            rdp: false, rustdesk: false, ssh: false, vnc: true, moonlight: false
          },
          touched: {
            rdp: false, rustdesk: false, ssh: false, vnc: true, moonlight: false
          }
        };
        const merged: RemoteWheelPreferences =
          applyRemoteWheelPreferenceUpdate(latest, staleUpdate);
        expect(merged.rdp).assertTrue();
        expect(merged.ssh).assertTrue();
        expect(merged.vnc).assertTrue();
        expect(merged.rustdesk).assertFalse();
        expect(merged.moonlight).assertFalse();
      });
  });
}
