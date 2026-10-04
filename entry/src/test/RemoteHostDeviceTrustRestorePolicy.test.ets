import { describe, expect, it } from '@ohos/hypium';
import {
  demoteRemoteHostDeviceTrust,
  mergeRestoredRemoteHostDeviceTrust,
  remoteHostDeviceTrustKeys,
  withoutRemoteHostDeviceTrust
} from '../main/ets/services/RemoteHostDeviceTrustPolicy';

function trustedPayload(): Record<string, string> {
  const values: Record<string, string> = {};
  values['sshkeyid'] = 'key-1';
  values['sshhostkeyfingerprintsha256'] = 'SHA256:attacker';
  values['sshhostkeyrawbase64'] = 'AAAA';
  values['sshhostkeytrustmode'] = '1';
  values['sshhostkeytrustedat'] = '99';
  values['sshjumphostkeyfingerprintsha256'] = 'SHA256:jump';
  values['sshjumphostkeytrustmode'] = '1';
  values['rdpcertificatefingerprintsha256'] = 'AB:CD';
  values['rdpcertificatetrustmode'] = '2';
  values['rdpcertificateallowuntrustedroot'] = '1';
  values['rdpcertificateallowhostmismatch'] = '1';
  values['rdpgatewaycertificatetrustmode'] = '2';
  values['sshhostkeyrouteidentity'] = 'route-ssh';
  values['rdpcertificaterouteidentity'] = 'route-rdp';
  values['rdpgatewaycertificaterouteidentity'] = 'route-gateway';
  return values;
}

export default function remoteHostDeviceTrustRestorePolicyTest(): void {
  describe('RemoteHostDeviceTrustRestorePolicy', (): void => {
    it('strips_every_trust_key_and_keeps_configuration', 0, (): void => {
      const stripped: Record<string, string> = withoutRemoteHostDeviceTrust(trustedPayload());
      expect(Object.keys(stripped).length).assertEqual(1);
      expect(stripped['sshkeyid']).assertEqual('key-1');
      expect(remoteHostDeviceTrustKeys().indexOf('sshjumphostkeytrustmode') >= 0).assertTrue();
      expect(remoteHostDeviceTrustKeys().indexOf('rdpgatewaycertificaterouteidentity') >= 0)
        .assertTrue();
    });

    it('demotes_restored_trust_to_a_candidate_with_its_fingerprint', 0, (): void => {
      const demoted: Record<string, string> = demoteRemoteHostDeviceTrust(trustedPayload());
      expect(demoted['sshhostkeytrustmode']).assertEqual('0');
      expect(demoted['sshhostkeytrustedat']).assertEqual('0');
      expect(demoted['sshhostkeyfingerprintsha256']).assertEqual('SHA256:attacker');
      expect(demoted['sshjumphostkeytrustmode']).assertEqual('0');
      expect(demoted['rdpcertificatetrustmode']).assertEqual('0');
      expect(demoted['rdpcertificateallowuntrustedroot']).assertEqual('0');
      expect(demoted['rdpcertificateallowhostmismatch']).assertEqual('0');
      expect(demoted['rdpgatewaycertificatetrustmode']).assertEqual('0');
      // An RDP connection pins any fingerprint whose route matches, so a
      // candidate keeps no route binding.
      expect(demoted['sshhostkeyrouteidentity']).assertEqual('');
      expect(demoted['rdpcertificaterouteidentity']).assertEqual('');
      expect(demoted['rdpgatewaycertificaterouteidentity']).assertEqual('');
      expect(demoted['sshkeyid']).assertEqual('key-1');
      // Groups that were absent stay absent.
      const sshOnly: Record<string, string> = {};
      sshOnly['sshhostkeyfingerprintsha256'] = 'SHA256:x';
      expect(demoteRemoteHostDeviceTrust(sshOnly)['rdpcertificatetrustmode'] === undefined)
        .assertTrue();
      expect(demoteRemoteHostDeviceTrust(sshOnly)['sshhostkeytrustmode']).assertEqual('0');
    });

    it('never_weakens_trust_this_device_already_established', 0, (): void => {
      const existing: Record<string, string> = {};
      existing['sshhostkeyfingerprintsha256'] = 'SHA256:local';
      existing['sshhostkeytrustmode'] = '1';
      existing['rdpcertificatetrustmode'] = '0';
      const incoming: Record<string, string> = demoteRemoteHostDeviceTrust(trustedPayload());
      const merged: Record<string, string> = mergeRestoredRemoteHostDeviceTrust(existing, incoming);
      expect(merged['sshhostkeytrustmode'] === undefined).assertTrue();
      expect(merged['sshhostkeyfingerprintsha256'] === undefined).assertTrue();
      expect(merged['rdpcertificatetrustmode']).assertEqual('0');
      expect(merged['rdpcertificatefingerprintsha256']).assertEqual('AB:CD');
      expect(merged['sshkeyid']).assertEqual('key-1');
      // A corrupt stored mode must not abort the restore.
      const corrupt: Record<string, string> = JSON.parse('{"sshhostkeytrustmode":2}') as Record<string, string>;
      expect(mergeRestoredRemoteHostDeviceTrust(corrupt, incoming)['sshhostkeytrustmode'] === undefined)
        .assertTrue();
    });
  });
}
