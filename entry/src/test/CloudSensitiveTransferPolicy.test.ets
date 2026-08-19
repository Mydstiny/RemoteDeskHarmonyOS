import { describe, expect, it } from '@ohos/hypium';
import {
  cloudSelectionAfterLocalCryptoTransition,
  cloudTableRowsAreDownloadCompatible,
  cloudTableRowsAreUploadSafe,
  vncSelectionAfterLocalCryptoTransition
} from '../main/ets/services/CloudSensitiveTransferPolicy';

function encrypted(value: string): boolean {
  return value.indexOf('enc-v3:') === 0;
}

export default function cloudSensitiveTransferPolicyTest(): void {
  describe('CloudSensitiveTransferPolicy', (): void => {
    it('uploads_sensitive_rows_as_stored_when_crypto_is_disabled', 0,
      (): void => {
        // Encryption is the user's explicit choice; without a configured
        // crypto contract the data uploads as stored (plaintext by choice).
        expect(cloudTableRowsAreUploadSafe(
          'remotehosts', [], false, encrypted)).assertTrue();
        expect(cloudTableRowsAreUploadSafe(
          'cryptoparams', [], false, encrypted)).assertTrue();
        expect(cloudTableRowsAreUploadSafe(
          'usersettings', [], false, encrypted)).assertTrue();
      });

    it('requires_every_scalar_and_nested_secret_to_be_ciphertext', 0,
      (): void => {
        expect(cloudTableRowsAreUploadSafe('remotehosts', [{
          id: 'host-1', passward: 'enc-v3:password'
        }], true, encrypted)).assertTrue();
        expect(cloudTableRowsAreUploadSafe('remotehosts', [{
          id: 'host-1', passward: 'plaintext'
        }], true, encrypted)).assertFalse();
        expect(cloudTableRowsAreUploadSafe('rustdeskrelays', [{
          id: 'relay-1', apipassword: 'enc-v3:api',
          key: 'enc-v3:key',
          accountsjson: '[{"id":"a","password":"enc-v3:account"}]'
        }], true, encrypted)).assertTrue();
        expect(cloudTableRowsAreUploadSafe('rustdeskrelays', [{
          id: 'relay-1',
          accountsjson: '[{"id":"a","password":"plaintext"}]'
        }], true, encrypted)).assertFalse();
      });

    it('accepts_legacy_plaintext_download_only_without_an_active_crypto_contract',
      0, (): void => {
        const rows: Array<Record<string, string>> = [{
          id: 'credential-1', password: 'legacy-plaintext'
        }];
        expect(cloudTableRowsAreDownloadCompatible(
          'rdpcredentials', rows, false, encrypted)).assertTrue();
        expect(cloudTableRowsAreDownloadCompatible(
          'rdpcredentials', rows, true, encrypted)).assertFalse();
      });

    it('pauses_remote_secret_paths_for_disable_and_all_vnc_for_reset',
      0, (): void => {
        const selected: string[] = [
          'usersettings', 'remotehosts', 'sshkeys', 'vncrecordv2',
          'moonlightrecordv1'
        ];
        expect(cloudSelectionAfterLocalCryptoTransition(
          selected, false).join(','))
          .assertEqual(
            'usersettings,vncrecordv2,moonlightrecordv1');
        expect(cloudSelectionAfterLocalCryptoTransition(
          selected, true).join(','))
          .assertEqual('usersettings,moonlightrecordv1');
        expect(vncSelectionAfterLocalCryptoTransition(
          ['hosts', 'secrets', 'trust'], false).join(','))
          .assertEqual('hosts,trust');
        expect(vncSelectionAfterLocalCryptoTransition(
          ['hosts', 'secrets'], true).length).assertEqual(0);
      });
  });
}
