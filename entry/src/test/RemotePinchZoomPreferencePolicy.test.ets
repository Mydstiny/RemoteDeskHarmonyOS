import { describe, it, expect } from '@ohos/hypium';
import {
  MOONLIGHT_PINCH_ZOOM_ENABLED_KEY,
  RDP_PINCH_ZOOM_ENABLED_KEY,
  REMOTE_PINCH_ZOOM_PREFERENCE_VERSION,
  RUSTDESK_PINCH_ZOOM_ENABLED_KEY,
  SSH_PINCH_ZOOM_ENABLED_KEY,
  VNC_PINCH_ZOOM_ENABLED_KEY,
  RemotePinchZoomPreferencePresence,
  RemotePinchZoomPreferenceUpdate,
  RemotePinchZoomPreferences,
  applyRemotePinchZoomPreferenceUpdate,
  defaultRemotePinchZoomPreferences,
  migrateRemotePinchZoomPreferences,
  remotePinchZoomPreference,
  remotePinchZoomPreferenceKey,
  remotePinchZoomSelectionSummary,
  withRemotePinchZoomPreference
} from '../main/ets/services/RemotePinchZoomPreferencePolicy';

function noPreferencesPresent(): RemotePinchZoomPreferencePresence {
  return { rdp: false, rustdesk: false, ssh: false, vnc: false, moonlight: false };
}

export default function remotePinchZoomPreferencePolicyTest(): void {
  describe('RemotePinchZoomPreferencePolicy', (): void => {
    it('maps_each_protocol_to_one_device_local_key', 0, (): void => {
      expect(remotePinchZoomPreferenceKey('rdp')).assertEqual(RDP_PINCH_ZOOM_ENABLED_KEY);
      expect(remotePinchZoomPreferenceKey('rustdesk')).assertEqual(RUSTDESK_PINCH_ZOOM_ENABLED_KEY);
      expect(remotePinchZoomPreferenceKey('ssh')).assertEqual(SSH_PINCH_ZOOM_ENABLED_KEY);
      expect(remotePinchZoomPreferenceKey('vnc')).assertEqual(VNC_PINCH_ZOOM_ENABLED_KEY);
      expect(remotePinchZoomPreferenceKey('moonlight')).assertEqual(MOONLIGHT_PINCH_ZOOM_ENABLED_KEY);
    });

    it('preserves_graphical_legacy_behavior_and_existing_ssh_behavior', 0, (): void => {
      const migration = migrateRemotePinchZoomPreferences(
        defaultRemotePinchZoomPreferences(), noPreferencesPresent(), 0, true);
      expect(migration.values.rdp).assertTrue();
      expect(migration.values.rustdesk).assertTrue();
      expect(migration.values.vnc).assertTrue();
      expect(migration.values.ssh).assertTrue();
      expect(migration.values.moonlight).assertFalse();
      expect(migration.shouldPersist).assertTrue();
      expect(migration.version).assertEqual(REMOTE_PINCH_ZOOM_PREFERENCE_VERSION);
    });

    it('keeps_remote_app_touch_scale_as_the_single_rustdesk_owner', 0, (): void => {
      const current: RemotePinchZoomPreferences = {
        rdp: true, rustdesk: true, ssh: false, vnc: true, moonlight: true
      };
      const present: RemotePinchZoomPreferencePresence = {
        rdp: true, rustdesk: true, ssh: true, vnc: true, moonlight: true
      };
      const migration = migrateRemotePinchZoomPreferences(
        current, present, REMOTE_PINCH_ZOOM_PREFERENCE_VERSION, true, true);
      expect(migration.values.rustdesk).assertFalse();
      expect(migration.values.rdp).assertTrue();
      expect(migration.values.vnc).assertTrue();
      expect(migration.shouldPersist).assertTrue();
    });

    it('never_overwrites_existing_protocol_specific_choices', 0, (): void => {
      const current: RemotePinchZoomPreferences = {
        rdp: false, rustdesk: true, ssh: false, vnc: false, moonlight: true
      };
      const present: RemotePinchZoomPreferencePresence = {
        rdp: true, rustdesk: true, ssh: true, vnc: true, moonlight: true
      };
      const migration = migrateRemotePinchZoomPreferences(
        current, present, REMOTE_PINCH_ZOOM_PREFERENCE_VERSION, true, false);
      expect(migration.values.rdp).assertFalse();
      expect(migration.values.rustdesk).assertTrue();
      expect(migration.values.ssh).assertFalse();
      expect(migration.values.vnc).assertFalse();
      expect(migration.values.moonlight).assertTrue();
      expect(migration.shouldPersist).assertFalse();
    });

    it('updates_only_the_selected_protocol_and_reports_a_stable_summary', 0, (): void => {
      let values: RemotePinchZoomPreferences = defaultRemotePinchZoomPreferences(false);
      expect(remotePinchZoomSelectionSummary(values)).assertEqual('已开启：SSH');
      values = withRemotePinchZoomPreference(values, 'rdp', true);
      values = withRemotePinchZoomPreference(values, 'vnc', true);
      expect(remotePinchZoomPreference(values, 'rdp')).assertTrue();
      expect(remotePinchZoomPreference(values, 'rustdesk')).assertFalse();
      expect(remotePinchZoomSelectionSummary(values)).assertEqual('已开启：RDP、SSH、VNC');
      values = { rdp: true, rustdesk: true, ssh: true, vnc: true, moonlight: true };
      expect(remotePinchZoomSelectionSummary(values)).assertEqual('全部协议开启');
      expect(remotePinchZoomPreference(values, 'unknown')).assertFalse();
    });

    it('merges_a_stale_editor_without_reverting_untouched_protocols', 0, (): void => {
      const latest: RemotePinchZoomPreferences = {
        rdp: true, rustdesk: false, ssh: true, vnc: false, moonlight: false
      };
      const staleUpdate: RemotePinchZoomPreferenceUpdate = {
        values: { rdp: false, rustdesk: false, ssh: false, vnc: true, moonlight: false },
        touched: { rdp: false, rustdesk: false, ssh: false, vnc: true, moonlight: false }
      };
      const merged: RemotePinchZoomPreferences =
        applyRemotePinchZoomPreferenceUpdate(latest, staleUpdate);
      expect(merged.rdp).assertTrue();
      expect(merged.ssh).assertTrue();
      expect(merged.vnc).assertTrue();
      expect(merged.rustdesk).assertFalse();
      expect(merged.moonlight).assertFalse();
    });
  });
}
