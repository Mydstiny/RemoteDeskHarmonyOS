/**
 * DataCrypto.test.ets — 加密底层与 CloudStore raw 密文验证
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { DataCrypto } from '../../../main/ets/services/DataCrypto';
import { CloudStore } from '../../../main/ets/services/CloudStore';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';
import { RdpCredential } from '../../../main/ets/model/RdpCredential';
import { SshKey } from '../../../main/ets/model/SshKey';
import { TotpEntry } from '../../../main/ets/model/TotpEntry';

function getTestContext(): common.Context | undefined {
  try {
    return getContext() as common.Context;
  } catch (_e) {
    return undefined;
  }
}

export default function dataCryptoTest() {
  let cloud: CloudStore;
  let crypto: DataCrypto;
  let ctx: common.Context | undefined;
  const password: string = 'Crypto-test-Password!2026';

  beforeAll(async () => {
    cloud = CloudStore.getInstance();
    ctx = getTestContext();
    if (ctx && !cloud.isReady()) {
      await cloud.init(ctx);
    }
    crypto = DataCrypto.getInstance();
    crypto.init(cloud);
    await crypto.setMasterPassword(password);
  });

  describe('DataCrypto_GCM', () => {
    it('encrypt_decrypt_short_password_should_restore_plaintext', 0, () => {
      const plaintext = 'testpass';
      const encrypted = crypto.encrypt(plaintext);
      expect(encrypted.startsWith('1:')).assertTrue();
      expect(crypto.decrypt(encrypted)).assertEqual(plaintext);
    });

    it('encrypt_decrypt_roundtrip_should_restore_plaintext', 0, () => {
      const plaintext = 'rdp密码-SSH私钥-TOTP secret';
      const encrypted = crypto.encrypt(plaintext);
      expect(encrypted.startsWith('1:')).assertTrue();
      expect(encrypted === plaintext).assertFalse();
      expect(crypto.decrypt(encrypted)).assertEqual(plaintext);
    });

    it('tampered_ciphertext_should_not_decrypt', 0, () => {
      const encrypted = crypto.encrypt('must fail after tamper');
      const tampered = encrypted.substring(0, encrypted.length - 2) + 'AA';
      let failed = false;
      try {
        crypto.decrypt(tampered);
      } catch (_e) {
        failed = true;
      }
      expect(failed).assertTrue();
    });
  });

  describe('DataCrypto_CloudStore_RawFields', () => {
    it('cloudstore_raw_sensitive_fields_should_be_encrypted', 0, () => {
      const host = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.label = 'test_crypto_host';
      host.protocol = 'ssh';
      host.host = '10.0.0.8';
      host.port = 22;
      host.username = 'crypto_user';
      host.password = 'host_secret';
      host.sshKeyData = 'private_key_blob';
      expect(cloud.insertHost(host)).assertTrue();

      const credential = new RdpCredential();
      credential.id = RdpCredential.generateId();
      credential.label = 'test_crypto_rdp';
      credential.username = 'rdp_user';
      credential.password = 'rdp_secret';
      expect(cloud.insertRdpCredential(credential)).assertTrue();

      const key = new SshKey();
      key.id = SshKey.generateId();
      key.label = 'test_crypto_key';
      key.privateKey = 'ssh_private_secret';
      expect(cloud.insertSshKey(key)).assertTrue();

      const entry = new TotpEntry();
      entry.id = TotpEntry.generateId();
      entry.issuer = 'test_crypto_totp';
      entry.account = 'crypto@example.com';
      entry.secret = 'JBSWY3DPEHPK3PXP';
      expect(cloud.insertTotpEntry(entry)).assertTrue();

      const rawHost = cloud.loadAllHostsRaw().find((h: RemoteHost) => h.id === host.id);
      const rawCredential = cloud.loadAllRdpCredentialsRaw().find((c: RdpCredential) => c.id === credential.id);
      const rawKey = cloud.loadAllSshKeysRaw().find((k: SshKey) => k.id === key.id);
      const rawTotp = cloud.loadAllTotpEntriesRaw().find((t: TotpEntry) => t.id === entry.id);

      expect(rawHost !== undefined).assertTrue();
      expect(rawCredential !== undefined).assertTrue();
      expect(rawKey !== undefined).assertTrue();
      expect(rawTotp !== undefined).assertTrue();
      if (rawHost) {
        expect(rawHost.password.startsWith('1:')).assertTrue();
        expect(rawHost.sshKeyData.startsWith('1:')).assertTrue();
      }
      if (rawCredential) {
        expect(rawCredential.password.startsWith('1:')).assertTrue();
      }
      if (rawKey) {
        expect(rawKey.privateKey.startsWith('1:')).assertTrue();
      }
      if (rawTotp) {
        expect(rawTotp.secret.startsWith('1:')).assertTrue();
      }

      cloud.deleteHost(host.id);
      cloud.deleteRdpCredential(credential.id);
      cloud.deleteSshKey(key.id);
      cloud.deleteTotpEntry(entry.id);
    });
  });
}
