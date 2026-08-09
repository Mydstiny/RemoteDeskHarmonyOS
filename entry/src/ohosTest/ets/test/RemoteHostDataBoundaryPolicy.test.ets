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
    it('cloud_extension_strips_peer_totp_reference_and_device_trust',
      0, (): void => {
        const source: Record<string, string> = {} as Record<string, string>;
        source['rustdesktotpentryid'] = 'totp-1';
        source['rustdesktotpautosubmit'] = '1';
        source['sshhostkeyfingerprintsha256'] = 'SHA256:local';
        source['rdpcertificateallowhostmismatch'] = '1';
        const projected: Record<string, string> = projectRemoteHostCloudExtension(source);
        const decoded = decodeRemoteHostDisplayPayload(
          encodeRemoteHostDisplayPayload('{}', projected));
        expect(decoded.extension['rustdesktotpentryid']).assertUndefined();
        expect(decoded.extension['rustdesktotpautosubmit']).assertUndefined();
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
        const physical: Record<string, string> = {} as Record<string, string>;
        physical['sshhostkeyfingerprintsha256'] = 'physical-old';
        const local: Record<string, string> = {} as Record<string, string>;
        local['sshhostkeyfingerprintsha256'] = 'local-new';
        const merged = mergeRemoteHostDeviceTrust(physical, extracted, local);
        expect(merged['sshhostkeyfingerprintsha256'])
          .assertEqual('local-new');
      });
  });
}
