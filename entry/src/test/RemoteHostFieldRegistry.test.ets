import { describe, expect, it } from '@ohos/hypium';
import {
  remoteHostDisplayConfigWithForwardFields,
  remoteHostFieldIsKnown,
  remoteHostKnownFieldKeys,
  withForwardRemoteHostFields
} from '../main/ets/services/RemoteHostFieldRegistry';
import { remoteHostCloudExtensionColumns } from '../main/ets/services/CloudTableAdapter';
import { remoteHostDeviceTrustKeys } from '../main/ets/services/RemoteHostDeviceTrustPolicy';
import { localBackupRemoteHostExtensionPayloadKeys } from '../main/ets/services/LocalBackupPolicy';

export default function remoteHostFieldRegistryTest(): void {
  describe('RemoteHostFieldRegistry', (): void => {
    it('knows_every_cloud_trust_secret_and_device_local_field', 0, (): void => {
      const cloud: string[] = remoteHostCloudExtensionColumns();
      for (let i = 0; i < cloud.length; i++) {
        expect(remoteHostFieldIsKnown(cloud[i])).assertTrue();
      }
      const trust: string[] = remoteHostDeviceTrustKeys();
      for (let i = 0; i < trust.length; i++) {
        expect(remoteHostFieldIsKnown(trust[i])).assertTrue();
        // Trust never rides in the cloud extension.
        expect(cloud.indexOf(trust[i])).assertEqual(-1);
      }
      expect(remoteHostFieldIsKnown('password')).assertTrue();
      expect(remoteHostFieldIsKnown('sshKeyPassphrase')).assertTrue();
      expect(remoteHostFieldIsKnown('rustdeskTotpEntryId')).assertTrue();
      expect(remoteHostFieldIsKnown('futureFeatureFlag')).assertFalse();
      // Every key a backup may carry is known, so a save never forwards it.
      const payload: string[] = localBackupRemoteHostExtensionPayloadKeys();
      for (let i = 0; i < payload.length; i++) {
        expect(remoteHostFieldIsKnown(payload[i])).assertTrue();
      }
      expect(remoteHostKnownFieldKeys().length > cloud.length).assertTrue();
    });

    it('keeps_fields_written_by_a_newer_version_when_saving', 0, (): void => {
      // Raw JSON keeps the test free of untyped object literals.
      const stored: string = '{"width":1280,"futureTopLevel":"kept",' +
        '"rustdeskTotpEntryId":"device-entry","_remoteDeskExtensionV1":{' +
        '"sshkeyid":"old-key","futureExtensionKey":"kept-too",' +
        '"sshhostkeyfingerprintsha256":"legacy-trust","password":"legacy-secret"}}';
      const next: string = '{"width":1920,"height":1080,' +
        '"_remoteDeskExtensionV1":{"sshkeyid":"new-key"}}';
      const merged: Record<string, Object> =
        JSON.parse(remoteHostDisplayConfigWithForwardFields(stored, next)) as Record<string, Object>;
      expect(merged['width'] as number).assertEqual(1920);
      expect(merged['futureTopLevel'] as string).assertEqual('kept');
      // Known fields this version keeps out are never resurrected.
      expect(merged['rustdeskTotpEntryId'] === undefined).assertTrue();
      const extension: Record<string, Object> =
        merged['_remoteDeskExtensionV1'] as Record<string, Object>;
      expect(extension['sshkeyid'] as string).assertEqual('new-key');
      expect(extension['futureExtensionKey'] as string).assertEqual('kept-too');
      expect(extension['sshhostkeyfingerprintsha256'] === undefined).assertTrue();
      expect(extension['password'] === undefined).assertTrue();
    });

    it('falls_back_to_the_new_value_when_the_stored_one_is_unreadable', 0, (): void => {
      const next: string = '{"width":1920}';
      expect(remoteHostDisplayConfigWithForwardFields('not json', next)).assertEqual(next);
      expect(remoteHostDisplayConfigWithForwardFields('[]', next)).assertEqual(next);
    });

    it('bounds_forwarded_values_and_never_forwards_display_settings', 0, (): void => {
      const stored: Record<string, Object> = {};
      stored['futureKey'] = 'kept';
      stored['oversized'] = 'x'.repeat(5000);
      stored['monitorCount'] = 3;
      const next: Record<string, Object> = {};
      next['width'] = 1920;
      const merged: Record<string, Object> = withForwardRemoteHostFields(stored, next, []);
      expect(merged['futureKey'] as string).assertEqual('kept');
      expect(merged['oversized'] === undefined).assertTrue();
      // Display settings are known even when a save leaves one out.
      expect(merged['monitorCount'] === undefined).assertTrue();
      expect(remoteHostFieldIsKnown('dynamicResolution')).assertTrue();
    });
  });
}
