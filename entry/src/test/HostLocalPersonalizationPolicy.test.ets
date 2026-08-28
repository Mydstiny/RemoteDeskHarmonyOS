import { describe, it, expect } from '@ohos/hypium';
import { DisplayConfig, RemoteHost } from '../main/ets/model/RemoteHost';
import {
  applyRemoteHostLocalPersonalization,
  applyVncHostLocalPersonalization,
  remoteHostCloudBaseChanged,
  remoteHostLocalPersonalizationValues,
  vncHostCloudValuesForSave,
  vncHostLocalPersonalizationPayload
} from '../main/ets/services/HostLocalPersonalizationPolicy';
import { VncHostValues } from '../main/ets/services/VncModelPolicy';

function vncHost(): VncHostValues {
  return {
    label: 'Desk', host: '192.0.2.10', port: 5900, username: 'user',
    gatewayId: '', transport: 'direct_tcp', repeaterMode: 'mode12',
    rememberPassword: true, viewOnly: false, displayOverrideEnabled: true,
    scalingMode: 'fit', clipboardEnabled: true, securityPolicy: 'secure_only',
    tls: true, locked: false, lockType: 0
  };
}

export default function hostLocalPersonalizationPolicyTest(): void {
  describe('HostLocalPersonalizationPolicy', (): void => {
    it('seeds_and_restores_remote_host_personalization_without_cloud_fields', 0, (): void => {
      const legacy = new RemoteHost();
      legacy.label = 'Legacy';
      legacy.displayConfig.width = 1280;
      legacy.lastConnected = 101;
      legacy.lastHealth = 3;
      legacy.lastLatency = 72;
      legacy.rustdeskAdaptiveOrientation = true;
      legacy.rustdeskDesktopFlipMode = 'image_only';
      legacy.rustdeskProLastSeenAt = 202;
      legacy.rustdeskProSyncError = 'not_seen';
      const values = remoteHostLocalPersonalizationValues(legacy);

      const cloud = new RemoteHost();
      cloud.label = 'Cloud Rename';
      cloud.displayConfig.width = 3840;
      cloud.lastConnected = 999;
      cloud.rustdeskAdaptiveOrientation = false;
      applyRemoteHostLocalPersonalization(cloud, values);

      expect(cloud.label).assertEqual('Cloud Rename');
      expect(cloud.displayConfig.width).assertEqual(1280);
      expect(cloud.lastConnected).assertEqual(101);
      expect(cloud.lastHealth).assertEqual(3);
      expect(cloud.lastLatency).assertEqual(72);
      expect(cloud.rustdeskAdaptiveOrientation).assertTrue();
      expect(cloud.rustdeskDesktopFlipMode).assertEqual('image_only');
      expect(cloud.rustdeskProLastSeenAt).assertEqual(202);
      expect(cloud.rustdeskProSyncError).assertEqual('not_seen');
    });

    it('falls_back_to_legacy_cloud_values_for_missing_corrupt_or_future_state', 0, (): void => {
      const cloud = new RemoteHost();
      cloud.displayConfig.width = 2560;
      cloud.lastLatency = 44;
      const corrupt: Record<string, string> = {
        localpersonalizationversion: '1', localdisplayconfig: '{bad',
        locallastlatency: '-1'
      };
      applyRemoteHostLocalPersonalization(cloud, corrupt);
      expect(cloud.displayConfig.width).assertEqual(2560);
      expect(cloud.lastLatency).assertEqual(44);

      const future = new RemoteHost();
      future.displayConfig = new DisplayConfig();
      future.displayConfig.width = 1920;
      applyRemoteHostLocalPersonalization(future, {
        localpersonalizationversion: '99', localdisplayconfig: '{"width":800}'
      });
      expect(future.displayConfig.width).assertEqual(1920);
    });

    it('classifies_display_health_orientation_and_device_trust_as_local_only', 0, (): void => {
      const before = new RemoteHost();
      before.id = 'host-1';
      before.label = 'Desk';
      const local = RemoteHost.fromJSON(before.toJSON());
      local.displayConfig.width = 1366;
      local.lastConnected = 123;
      local.lastLatency = 12;
      local.rustdeskAdaptiveOrientation = true;
      local.rustdeskDesktopFlipMode = 'image_and_controls';
      local.rustdeskProLastSeenAt = 456;
      local.rustdeskProSyncError = 'offline';
      local.sshHostKeyFingerprintSha256 = 'SHA256:local';
      expect(remoteHostCloudBaseChanged(before, local)).assertFalse();

      local.label = 'Desk renamed';
      expect(remoteHostCloudBaseChanged(before, local)).assertTrue();
    });

    it('keeps_vnc_cloud_legacy_values_while_local_override_wins', 0, (): void => {
      const legacy = vncHost();
      const phone = vncHost();
      phone.label = 'Desk renamed';
      phone.rememberPassword = false;
      phone.viewOnly = true;
      phone.scalingMode = 'pan';
      phone.clipboardEnabled = false;
      const cloudSave = vncHostCloudValuesForSave(phone, legacy);
      expect(cloudSave.label).assertEqual('Desk renamed');
      expect(cloudSave.viewOnly).assertFalse();
      expect(cloudSave.scalingMode).assertEqual('fit');
      expect(cloudSave.clipboardEnabled).assertTrue();

      const pad = applyVncHostLocalPersonalization(
        cloudSave, vncHostLocalPersonalizationPayload(phone));
      expect(pad.viewOnly).assertTrue();
      expect(pad.scalingMode).assertEqual('pan');
      expect(pad.clipboardEnabled).assertFalse();
      expect(pad.rememberPassword).assertFalse();
    });

    it('does_not_require_a_vnc_override_to_decode_an_old_host', 0, (): void => {
      const legacy = vncHost();
      expect(applyVncHostLocalPersonalization(legacy, '').scalingMode).assertEqual('fit');
      expect(applyVncHostLocalPersonalization(legacy, '{bad').clipboardEnabled).assertTrue();
      expect(applyVncHostLocalPersonalization(legacy, '{"version":2,"viewOnly":true}').viewOnly)
        .assertFalse();
    });
  });
}
