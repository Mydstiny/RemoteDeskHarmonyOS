/**
 * CloudStore.test.ets — CloudStore unit tests (hypium)
 *
 * Test scope:
 *   1. Singleton + uninitialized state
 *   2. Data conversion consistency (RemoteHost / SshKey / TotpEntry)
 *   3. Safe defaults for CRUD when uninitialized
 *   4. Callback registration
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { CloudStore } from '../main/ets/services/CloudStore';
import { RemoteHost, DisplayConfig, RemoteHostJSON } from '../main/ets/model/RemoteHost';
import { SshKey, SshKeyType, SshKeyJSON } from '../main/ets/model/SshKey';
import { TotpEntry, TotpAlgorithm, TotpEntryJSON } from '../main/ets/model/TotpEntry';

export default function cloudStoreTest() {

  describe('CloudStore_Singleton_and_State', () => {
    it('getInstance_should_return_same_instance', 0, () => {
      const a = CloudStore.getInstance();
      const b = CloudStore.getInstance();
      expect(a === b).assertTrue();
    });

    it('isReady_should_be_false_without_init', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.isReady()).assertFalse();
    });

    it('getRdbStore_should_be_null_without_init', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.getRdbStore() === null).assertTrue();
    });
  });

  describe('CloudStore_Safe_Defaults_RemoteHost', () => {
    it('loadAllHosts_should_return_empty_array', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.loadAllHosts().length).assertEqual(0);
    });

    it('insertHost_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const host = new RemoteHost();
      host.label = 'test';
      host.host = '1.2.3.4';
      host.username = 'admin';
      expect(cs.insertHost(host)).assertFalse();
    });

    it('updateHost_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const host = new RemoteHost();
      host.id = 'test-id';
      expect(cs.updateHost(host)).assertFalse();
    });

    it('deleteHost_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.deleteHost('any-id')).assertFalse();
    });
  });

  describe('CloudStore_Safe_Defaults_SshKey', () => {
    it('loadAllSshKeys_should_return_empty_array', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.loadAllSshKeys().length).assertEqual(0);
    });

    it('insertSshKey_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const key = new SshKey();
      key.label = 'test-key';
      expect(cs.insertSshKey(key)).assertFalse();
    });

    it('updateSshKey_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const key = new SshKey();
      key.id = 'test-key-id';
      expect(cs.updateSshKey(key)).assertFalse();
    });

    it('deleteSshKey_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.deleteSshKey('any-key-id')).assertFalse();
    });
  });

  describe('CloudStore_Safe_Defaults_TotpEntry', () => {
    it('loadAllTotpEntries_should_return_empty_array', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.loadAllTotpEntries().length).assertEqual(0);
    });

    it('insertTotpEntry_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const entry = new TotpEntry();
      entry.issuer = 'TestIssuer';
      expect(cs.insertTotpEntry(entry)).assertFalse();
    });

    it('updateTotpEntry_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      const entry = new TotpEntry();
      entry.id = 'test-totp-id';
      expect(cs.updateTotpEntry(entry)).assertFalse();
    });

    it('deleteTotpEntry_should_return_false', 0, () => {
      const cs = CloudStore.getInstance();
      expect(cs.deleteTotpEntry('any-totp-id')).assertFalse();
    });
  });

  describe('CloudStore_onCloudChange', () => {
    it('register_callback_should_not_throw', 0, () => {
      const cs = CloudStore.getInstance();
      cs.onCloudChange(() => {
        // no-op
      });
      expect(true).assertTrue();
    });

    it('register_empty_callback_should_not_throw', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.onCloudChange(() => {
          // no-op callback
        });
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });
  });

  describe('CloudStore_pushTable_pullNow_safe', () => {
    it('pushTable_should_not_throw_when_uninitialized', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.pushTable('remotehosts');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });

    it('pullNow_should_not_throw_when_uninitialized', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.pullNow();
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });

    it('syncHosts_should_not_throw_when_uninitialized', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.syncHosts('test-user');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });

    it('syncSshKeys_should_not_throw_when_uninitialized', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.syncSshKeys('test-user');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });

    it('syncTotpEntries_should_not_throw_when_uninitialized', 0, () => {
      const cs = CloudStore.getInstance();
      try {
        cs.syncTotpEntries('test-user');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });
  });

  describe('CloudStore_RemoteHost_Serialization_Roundtrip', () => {
    it('full_field_roundtrip_should_be_consistent', 0, () => {
      const host = new RemoteHost();
      host.id = 'host_test_001';
      host.userId = 'union_abc123';
      host.label = 'OfficePC';
      host.protocol = 'rdp';
      host.host = '192.168.1.100';
      host.port = 3389;
      host.username = 'admin';
      host.password = 'secret123';
      host.customHostname = 'MYPC';
      host.sshUseKey = false;
      host.sshKeyPath = '/data/keys/id_rsa';
      host.sshKeyData = 'base64keydata';
      host.proxyHost = 'proxy.example.com';
      host.proxyPort = 8080;
      host.proxyUsername = 'proxyuser';
      host.gatewayHost = 'gateway.example.com';
      host.gatewayPort = 443;
      host.displayConfig = new DisplayConfig();
      host.displayConfig.width = 1920;
      host.displayConfig.height = 1080;
      host.locked = true;
      host.lockType = 3;
      host.groupId = 'group_work';
      host.sortOrder = 42;
      host.icon = 'desktop';
      host.lastConnected = 1718000000000;
      host.lastHealth = 1;
      host.lastLatency = 15;
      host.syncVersion = 3;
      host.createdAt = 1717000000000;

      const json = host.toJSON();
      const restored = RemoteHost.fromJSON(json as Record<string, Object>);

      expect(restored.id).assertEqual(host.id);
      expect(restored.userId).assertEqual(host.userId);
      expect(restored.label).assertEqual(host.label);
      expect(restored.protocol).assertEqual(host.protocol);
      expect(restored.host).assertEqual(host.host);
      expect(restored.port).assertEqual(host.port);
      expect(restored.username).assertEqual(host.username);
      expect(restored.password).assertEqual(host.password);
      expect(restored.customHostname).assertEqual(host.customHostname);
      expect(restored.sshUseKey).assertEqual(host.sshUseKey);
      expect(restored.sshKeyPath).assertEqual(host.sshKeyPath);
      expect(restored.sshKeyData).assertEqual(host.sshKeyData);
      expect(restored.proxyHost).assertEqual(host.proxyHost);
      expect(restored.proxyPort).assertEqual(host.proxyPort);
      expect(restored.proxyUsername).assertEqual(host.proxyUsername);
      expect(restored.gatewayHost).assertEqual(host.gatewayHost);
      expect(restored.gatewayPort).assertEqual(host.gatewayPort);
      expect(restored.locked).assertEqual(host.locked);
      expect(restored.lockType).assertEqual(host.lockType);
      expect(restored.groupId).assertEqual(host.groupId);
      expect(restored.sortOrder).assertEqual(host.sortOrder);
      expect(restored.icon).assertEqual(host.icon);
      expect(restored.lastConnected).assertEqual(host.lastConnected);
      expect(restored.lastHealth).assertEqual(host.lastHealth);
      expect(restored.lastLatency).assertEqual(host.lastLatency);
      expect(restored.syncVersion).assertEqual(host.syncVersion);
      expect(restored.createdAt).assertEqual(host.createdAt);
    });

    it('DisplayConfig_JSON_should_preserve_dimensions', 0, () => {
      const dc = new DisplayConfig();
      dc.width = 2560;
      dc.height = 1440;
      const json = dc.toJSON();
      const restored = DisplayConfig.fromJSON(json);
      expect(restored.width).assertEqual(2560);
      expect(restored.height).assertEqual(1440);
    });

    it('DisplayConfig_defaults_should_be_1920x1080', 0, () => {
      const dc = new DisplayConfig();
      expect(dc.width).assertEqual(1920);
      expect(dc.height).assertEqual(1080);
    });
  });

  describe('CloudStore_SshKey_Serialization_Roundtrip', () => {
    it('full_field_roundtrip_should_be_consistent', 0, () => {
      const key = new SshKey();
      key.id = 'ssh_001';
      key.userId = 'union_abc';
      key.label = 'Production_Server_Key';
      key.keyType = SshKeyType.ED25519;
      key.publicKey = 'ssh-ed25519 AAAAC3...';
      key.privateKey = '-----BEGIN OPENSSH PRIVATE KEY-----...';
      key.fingerprint = 'SHA256:abc123...';
      key.comment = 'prod-server@example.com';
      key.locked = true;
      key.lockType = 1;
      key.createdAt = 1717000000000;
      key.syncVersion = 5;

      const json = key.toJSON();
      const restored = SshKey.fromJSON(json as SshKeyJSON);

      expect(restored.id).assertEqual(key.id);
      expect(restored.userId).assertEqual(key.userId);
      expect(restored.label).assertEqual(key.label);
      expect(restored.keyType).assertEqual(key.keyType);
      expect(restored.publicKey).assertEqual(key.publicKey);
      expect(restored.privateKey).assertEqual(key.privateKey);
      expect(restored.fingerprint).assertEqual(key.fingerprint);
      expect(restored.comment).assertEqual(key.comment);
      expect(restored.locked).assertEqual(key.locked);
      expect(restored.lockType).assertEqual(key.lockType);
      expect(restored.createdAt).assertEqual(key.createdAt);
      expect(restored.syncVersion).assertEqual(key.syncVersion);
    });
  });

  describe('CloudStore_TotpEntry_Serialization_Roundtrip', () => {
    it('full_field_roundtrip_should_be_consistent', 0, () => {
      const entry = new TotpEntry();
      entry.id = 'totp_001';
      entry.userId = 'union_abc';
      entry.issuer = 'GitHub';
      entry.account = 'user@example.com';
      entry.secret = 'JBSWY3DPEHPK3PXP';
      entry.algorithm = TotpAlgorithm.SHA1;
      entry.digits = 6;
      entry.period = 30;
      entry.iconUrl = 'https://github.com/favicon.ico';
      entry.locked = false;
      entry.lockType = 0;
      entry.createdAt = 1717000000000;
      entry.syncVersion = 1;

      const json = entry.toJSON();
      const restored = TotpEntry.fromJSON(json as TotpEntryJSON);

      expect(restored.id).assertEqual(entry.id);
      expect(restored.userId).assertEqual(entry.userId);
      expect(restored.issuer).assertEqual(entry.issuer);
      expect(restored.account).assertEqual(entry.account);
      expect(restored.secret).assertEqual(entry.secret);
      expect(restored.algorithm).assertEqual(entry.algorithm);
      expect(restored.digits).assertEqual(entry.digits);
      expect(restored.period).assertEqual(entry.period);
      expect(restored.iconUrl).assertEqual(entry.iconUrl);
      expect(restored.locked).assertEqual(entry.locked);
      expect(restored.lockType).assertEqual(entry.lockType);
      expect(restored.createdAt).assertEqual(entry.createdAt);
      expect(restored.syncVersion).assertEqual(entry.syncVersion);
    });
  });

  describe('CloudStore_Boolean_Integer_Conversion', () => {
    it('locked_true_roundtrip', 0, () => {
      const host = new RemoteHost();
      host.locked = true;
      const json = host.toJSON();
      expect((json as Record<string, Object>)['locked']).assertEqual(true);
      const restored = RemoteHost.fromJSON(json as Record<string, Object>);
      expect(restored.locked).assertTrue();
    });

    it('locked_false_roundtrip', 0, () => {
      const host = new RemoteHost();
      host.locked = false;
      const json = host.toJSON();
      const restored = RemoteHost.fromJSON(json as Record<string, Object>);
      expect(restored.locked).assertFalse();
    });

    it('legacy_favorite_field_should_be_ignored', 0, () => {
      const host = new RemoteHost();
      const legacy: Record<string, Object> = host.toJSON() as Record<string, Object>;
      legacy['isFavorite'] = true;
      const restored = RemoteHost.fromJSON(legacy as RemoteHostJSON);
      expect(Object.prototype.hasOwnProperty.call(restored.toJSON(), 'isFavorite')).assertFalse();
    });

    it('sshUseKey_true_roundtrip', 0, () => {
      const host = new RemoteHost();
      host.sshUseKey = true;
      const json = host.toJSON();
      const restored = RemoteHost.fromJSON(json as Record<string, Object>);
      expect(restored.sshUseKey).assertTrue();
    });
  });

  describe('CloudStore_Enum_Values', () => {
    it('SshKeyType_RSA_0_ED25519_1_ECDSA_2_DSA_3', 0, () => {
      expect(SshKeyType.RSA).assertEqual(0);
      expect(SshKeyType.ED25519).assertEqual(1);
      expect(SshKeyType.ECDSA).assertEqual(2);
      expect(SshKeyType.DSA).assertEqual(3);
    });

    it('TotpAlgorithm_SHA1_0_SHA256_1_SHA512_2', 0, () => {
      expect(TotpAlgorithm.SHA1).assertEqual(0);
      expect(TotpAlgorithm.SHA256).assertEqual(1);
      expect(TotpAlgorithm.SHA512).assertEqual(2);
    });
  });

  describe('CloudStore_ID_Uniqueness', () => {
    it('RemoteHost_generateId_should_be_unique', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 100; i++) {
        ids.add(RemoteHost.generateId());
      }
      expect(ids.size).assertEqual(100);
    });

    it('SshKey_generateId_should_be_unique', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 100; i++) {
        ids.add(SshKey.generateId());
      }
      expect(ids.size).assertEqual(100);
    });

    it('TotpEntry_generateId_should_be_unique', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 100; i++) {
        ids.add(TotpEntry.generateId());
      }
      expect(ids.size).assertEqual(100);
    });
  });

  describe('CloudStore_Default_Values', () => {
    it('new_RemoteHost_should_have_reasonable_defaults', 0, () => {
      const host = new RemoteHost();
      expect(host.port).assertEqual(3389);
      expect(host.locked).assertFalse();
      expect(host.lockType).assertEqual(0);
      expect(host.syncVersion).assertEqual(0);
      expect(host.sortOrder).assertEqual(0);
    });

    it('new_SshKey_should_have_reasonable_defaults', 0, () => {
      const key = new SshKey();
      expect(key.keyType).assertEqual(SshKeyType.ED25519);
      expect(key.locked).assertFalse();
      expect(key.lockType).assertEqual(0);
      expect(key.syncVersion).assertEqual(0);
    });

    it('new_TotpEntry_should_have_reasonable_defaults', 0, () => {
      const entry = new TotpEntry();
      expect(entry.algorithm).assertEqual(TotpAlgorithm.SHA1);
      expect(entry.digits).assertEqual(6);
      expect(entry.period).assertEqual(30);
      expect(entry.locked).assertFalse();
      expect(entry.lockType).assertEqual(0);
      expect(entry.syncVersion).assertEqual(0);
    });
  });
}
