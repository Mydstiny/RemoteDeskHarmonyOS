/** SshKeyImportService.test.ets — SSH 私钥文件导入纯逻辑回归测试 */

import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeSshPrivateKeyText,
  sshKeyFileName,
  buildSshKeyFromInspection
} from '../../../main/ets/services/SshKeyImportService';
import { SshKeyType } from '../../../main/ets/model/SshKey';
import { SshPrivateKeyInfo } from '../../../main/ets/types/rdpnapi';

export default function sshKeyImportServiceTest() {
  describe('SshKeyImportService_Text', () => {
    it('normalize_should_remove_bom_and_outer_whitespace', 0, () => {
      const value: string = normalizeSshPrivateKeyText('\uFEFF\n  PRIVATE KEY\n ');
      expect(value).assertEqual('PRIVATE KEY');
    });

    it('fileName_should_extract_uri_tail_and_decode', 0, () => {
      expect(sshKeyFileName('file://local/Documents/id_rsa?open=1')).assertEqual('id_rsa');
    });
  });

  describe('SshKeyImportService_Metadata', () => {
    it('build_should_map_native_key_metadata', 0, () => {
      const info: SshPrivateKeyInfo = {
        ok: true,
        keyType: 'rsa',
        publicKeyOpenSsh: 'ssh-rsa AAAA comment',
        fingerprintSha256: 'SHA256:test',
        encrypted: false,
        error: ''
      };
      const key = buildSshKeyFromInspection('id_rsa', 'fixture-rsa-key-material', info);
      expect(key.label).assertEqual('id_rsa');
      expect(key.keyType).assertEqual(SshKeyType.RSA);
      expect(key.publicKey).assertEqual(info.publicKeyOpenSsh);
      expect(key.fingerprint).assertEqual(info.fingerprintSha256);
      expect(key.formatVersion).assertEqual(1);
      expect(key.privateKeyEncrypted).assertFalse();
    });

    it('build_should_keep_encrypted_private_key_metadata', 0, () => {
      const info: SshPrivateKeyInfo = {
        ok: false,
        keyType: 'ed25519',
        publicKeyOpenSsh: '',
        fingerprintSha256: '',
        encrypted: true,
        error: 'passphrase required'
      };
      const key = buildSshKeyFromInspection('encrypted_key', 'fixture-encrypted-key-material', info);
      expect(key.keyType).assertEqual(SshKeyType.ED25519);
      expect(key.privateKeyEncrypted).assertTrue();
      expect(key.publicKey).assertEqual('');
      expect(key.fingerprint).assertEqual('');
    });
  });
}
