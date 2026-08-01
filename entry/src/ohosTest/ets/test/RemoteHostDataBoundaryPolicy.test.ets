import { describe, it, expect } from '@ohos/hypium';
import {
  decodeRemoteHostDisplayPayload,
  encodeRemoteHostDisplayPayload,
  projectRemoteHostCloudExtension
} from '../../../main/ets/services/CloudTableAdapter';
import {
  extractLegacyRemoteHostDeviceTrust,
  mergeRemoteHostDeviceTrust
} from '../../../main/ets/services/RemoteHostDeviceTrustPolicy';

export default function remoteHostDataBoundaryPolicyTest(): void {
  describe('RemoteHostDataBoundaryPolicy', (): void => {
    it('cloud_extension_keeps_totp_reference_but_not_device_trust',
      0, (): void => {
        const projected = projectRemoteHostCloudExtension({
          rustdesktotpentryid: 'totp-1',
          rustdesktotpautosubmit: '1',
          sshhostkeyfingerprintsha256: 'SHA256:local',
          rdpcertificateallowhostmismatch: '1'
        });
        const decoded = decodeRemoteHostDisplayPayload(
          encodeRemoteHostDisplayPayload('{}', projected));
        expect(decoded.extension['rustdesktotpentryid'])
          .assertEqual('totp-1');
        expect(decoded.extension['rustdesktotpautosubmit'])
          .assertEqual('1');
        expect(decoded.extension[
          'sshhostkeyfingerprintsha256']).assertUndefined();
        expect(decoded.extension[
          'rdpcertificateallowhostmismatch']).assertUndefined();
      });

    it('legacy_trust_migration_prefers_the_local_overlay',
      0, (): void => {
        const extracted = extractLegacyRemoteHostDeviceTrust(
          '{"_remoteDeskExtensionV1":{' +
          '"sshhostkeyfingerprintsha256":"cloud-old"}}');
        const merged = mergeRemoteHostDeviceTrust(
          { sshhostkeyfingerprintsha256: 'physical-old' },
          extracted,
          { sshhostkeyfingerprintsha256: 'local-new' });
        expect(merged['sshhostkeyfingerprintsha256'])
          .assertEqual('local-new');
      });
  });
}
