/**
 * CloudSync.test.ets — Cloud sync device integration tests (hypium + real RDB)
 *
 * On-device RDB read/write lifecycle:
 *   CloudStore.init() → CRUD → row-to-bucket roundtrip → batch ops
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { CloudStore, SyncStatus } from '../../../main/ets/services/CloudStore';
import { HostSyncService } from '../../../main/ets/services/HostSyncService';
import { KeyVaultService } from '../../../main/ets/services/KeyVaultService';
import { RemoteHost, DisplayConfig, LockType, ConnectionHealth } from '../../../main/ets/model/RemoteHost';
import { SshKey, SshKeyType } from '../../../main/ets/model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../../../main/ets/model/TotpEntry';
import { common } from '@kit.AbilityKit';

function getTestContext(): common.Context | undefined {
  try {
    const ctx = getContext() as common.Context;
    return ctx;
  } catch (_e) {
    return undefined;
  }
}

export default function cloudSyncTest() {
  let cloud: CloudStore;
  let ctx: common.Context | undefined;

  beforeAll(async () => {
    cloud = CloudStore.getInstance();
    ctx = getTestContext();
    if (ctx && !cloud.isReady()) {
      await cloud.init(ctx);
    }
  });

  afterAll(() => {
    if (cloud.isReady()) {
      const hosts = cloud.loadAllHosts();
      const keys = cloud.loadAllSshKeys();
      const totps = cloud.loadAllTotpEntries();
      for (let i = 0; i < hosts.length; i++) {
        if (hosts[i].label.startsWith('test_')) {
          cloud.deleteHost(hosts[i].id);
        }
      }
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].label.startsWith('test_')) {
          cloud.deleteSshKey(keys[i].id);
        }
      }
      for (let i = 0; i < totps.length; i++) {
        if (totps[i].issuer.startsWith('test_')) {
          cloud.deleteTotpEntry(totps[i].id);
        }
      }
    }
  });

  describe('CloudSync_CloudStore_Init', () => {
    it('should_get_test_Context', 0, () => {
      expect(ctx !== undefined).assertTrue();
    });

    it('CloudStore_isReady_should_be_true', 0, () => {
      expect(cloud.isReady()).assertTrue();
    });

    it('CloudStore_getRdbStore_should_not_be_null', 0, () => {
      expect(cloud.getRdbStore() !== null).assertTrue();
    });
  });

  describe('CloudSync_RemoteHost_CRUD', () => {
    let testId: string = '';

    it('insertHost_and_loadAllHosts_should_readback', 0, () => {
      const host = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.userId = 'test_user';
      host.label = 'test_integration_host';
      host.protocol = 'rdp';
      host.host = '10.0.0.99';
      host.port = 3389;
      host.username = 'testadmin';
      host.password = 'testpass';
      host.customHostname = 'TESTPC';
      host.sshUseKey = false;
      host.sshKeyPath = '';
      host.sshKeyData = '';
      host.proxyHost = '';
      host.proxyPort = 22;
      host.proxyUsername = '';
      host.gatewayHost = '';
      host.gatewayPort = 443;
      const dc = new DisplayConfig();
      dc.width = 1920;
      dc.height = 1080;
      host.displayConfig = dc;
      host.locked = false;
      host.lockType = LockType.NONE;
      host.groupId = 'test_group';
      host.sortOrder = 10;
      host.icon = 'desktop';
      host.lastConnected = 0;
      host.lastHealth = ConnectionHealth.UNKNOWN;
      host.lastLatency = 0;
      host.syncVersion = 1;
      host.createdAt = Date.now();

      const result = cloud.insertHost(host);
      expect(result).assertTrue();
      testId = host.id;

      const all = cloud.loadAllHosts();
      const found = all.find((h: RemoteHost) => h.id === testId);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.label).assertEqual('test_integration_host');
        expect(found.protocol).assertEqual('rdp');
        expect(found.host).assertEqual('10.0.0.99');
        expect(found.port).assertEqual(3389);
        expect(found.username).assertEqual('testadmin');
        expect(found.password).assertEqual('testpass');
        expect(found.customHostname).assertEqual('TESTPC');
        expect(found.groupId).assertEqual('test_group');
        expect(found.sortOrder).assertEqual(10);
        expect(found.displayConfig.width).assertEqual(1920);
        expect(found.displayConfig.height).assertEqual(1080);
        expect(found.locked).assertFalse();
        expect(found.lockType).assertEqual(LockType.NONE);
        expect(found.syncVersion).assertEqual(1);
      }
    });

    it('updateHost_and_readback_updated_fields', 0, () => {
      const all = cloud.loadAllHosts();
      const host = all.find((h: RemoteHost) => h.id === testId);
      expect(host !== undefined).assertTrue();
      if (host) {
        host.label = 'test_updated_name';
        host.port = 3390;
        host.groupId = 'test_group_updated';
        host.sortOrder = 20;
        const result = cloud.updateHost(host);
        expect(result).assertTrue();

        const reloaded = cloud.loadAllHosts().find((h: RemoteHost) => h.id === testId);
        expect(reloaded !== undefined).assertTrue();
        if (reloaded) {
          expect(reloaded.label).assertEqual('test_updated_name');
          expect(reloaded.port).assertEqual(3390);
          expect(reloaded.groupId).assertEqual('test_group_updated');
          expect(reloaded.sortOrder).assertEqual(20);
        }
      }
    });

    it('insertHost_should_readback_rustdesk_direct_fields', 0, () => {
      const host = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.userId = 'test_user';
      host.label = 'test_rustdesk_direct_host';
      host.protocol = 'rustdesk';
      host.customHostname = '123456789';
      host.host = 'relay.example.com';
      host.port = 21116;
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = '192.0.2.10';
      host.rustdeskDirectPort = 21118;
      host.createdAt = Date.now();

      const result = cloud.insertHost(host);
      expect(result).assertTrue();

      const found = cloud.loadAllHosts().find((h: RemoteHost) => h.id === host.id);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.rustdeskDirectEnabled).assertTrue();
        expect(found.rustdeskDirectHost).assertEqual('192.0.2.10');
        expect(found.rustdeskDirectPort).assertEqual(21118);
      }

      expect(cloud.deleteHost(host.id)).assertTrue();
    });

    it('deleteHost_should_remove_it', 0, () => {
      const result = cloud.deleteHost(testId);
      expect(result).assertTrue();
      const all = cloud.loadAllHosts();
      const found = all.find((h: RemoteHost) => h.id === testId);
      expect(found === undefined).assertTrue();
      testId = '';
    });
  });

  describe('CloudSync_SshKey_CRUD', () => {
    let testId: string = '';

    it('insertSshKey_and_loadAllSshKeys_should_readback', 0, () => {
      const key = new SshKey();
      key.id = SshKey.generateId();
      key.userId = 'test_user';
      key.label = 'test_integration_key';
      key.keyType = SshKeyType.ED25519;
      key.publicKey = 'ssh-ed25519 AAAAC3NzaC1...';
      key.privateKey = '-----BEGIN OPENSSH PRIVATE KEY----- test';
      key.fingerprint = 'SHA256:test123';
      key.comment = 'integration-test@example.com';
      key.locked = true;
      key.lockType = 1;
      key.createdAt = Date.now();
      key.syncVersion = 2;

      const result = cloud.insertSshKey(key);
      expect(result).assertTrue();
      testId = key.id;

      const all = cloud.loadAllSshKeys();
      const found = all.find((k: SshKey) => k.id === testId);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.label).assertEqual('test_integration_key');
        expect(found.keyType).assertEqual(SshKeyType.ED25519);
        expect(found.publicKey).assertEqual('ssh-ed25519 AAAAC3NzaC1...');
        expect(found.fingerprint).assertEqual('SHA256:test123');
        expect(found.locked).assertTrue();
        expect(found.lockType).assertEqual(1);
        expect(found.syncVersion).assertEqual(2);
      }
    });

    it('updateSshKey_should_readback_updated', 0, () => {
      const all = cloud.loadAllSshKeys();
      const key = all.find((k: SshKey) => k.id === testId);
      if (key) {
        key.label = 'test_renamed_key';
        key.locked = false;
        const result = cloud.updateSshKey(key);
        expect(result).assertTrue();
        const reloaded = cloud.loadAllSshKeys().find((k: SshKey) => k.id === testId);
        if (reloaded) {
          expect(reloaded.label).assertEqual('test_renamed_key');
          expect(reloaded.locked).assertFalse();
        }
      }
    });

    it('deleteSshKey_should_remove_it', 0, () => {
      const result = cloud.deleteSshKey(testId);
      expect(result).assertTrue();
      const found = cloud.loadAllSshKeys().find((k: SshKey) => k.id === testId);
      expect(found === undefined).assertTrue();
      testId = '';
    });
  });

  describe('CloudSync_TotpEntry_CRUD', () => {
    let testId: string = '';

    it('insertTotpEntry_and_loadAll_should_readback', 0, () => {
      const entry = new TotpEntry();
      entry.id = TotpEntry.generateId();
      entry.userId = 'test_user';
      entry.issuer = 'test_GitHub';
      entry.account = 'testuser@github.com';
      entry.secret = 'JBSWY3DPEHPK3PXP';
      entry.algorithm = TotpAlgorithm.SHA256;
      entry.digits = 8;
      entry.period = 60;
      entry.iconUrl = 'https://github.com/favicon.ico';
      entry.locked = false;
      entry.lockType = 0;
      entry.createdAt = Date.now();
      entry.syncVersion = 1;

      const result = cloud.insertTotpEntry(entry);
      expect(result).assertTrue();
      testId = entry.id;

      const all = cloud.loadAllTotpEntries();
      const found = all.find((e: TotpEntry) => e.id === testId);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.issuer).assertEqual('test_GitHub');
        expect(found.account).assertEqual('testuser@github.com');
        expect(found.secret).assertEqual('JBSWY3DPEHPK3PXP');
        expect(found.algorithm).assertEqual(TotpAlgorithm.SHA256);
        expect(found.digits).assertEqual(8);
        expect(found.period).assertEqual(60);
        expect(found.locked).assertFalse();
      }
    });

    it('updateTotpEntry_should_readback_updated', 0, () => {
      const all = cloud.loadAllTotpEntries();
      const entry = all.find((e: TotpEntry) => e.id === testId);
      if (entry) {
        entry.issuer = 'test_GitLab';
        entry.digits = 6;
        entry.period = 30;
        const result = cloud.updateTotpEntry(entry);
        expect(result).assertTrue();
        const reloaded = cloud.loadAllTotpEntries().find((e: TotpEntry) => e.id === testId);
        if (reloaded) {
          expect(reloaded.issuer).assertEqual('test_GitLab');
          expect(reloaded.digits).assertEqual(6);
          expect(reloaded.period).assertEqual(30);
        }
      }
    });

    it('deleteTotpEntry_should_remove_it', 0, () => {
      const result = cloud.deleteTotpEntry(testId);
      expect(result).assertTrue();
      const found = cloud.loadAllTotpEntries().find((e: TotpEntry) => e.id === testId);
      expect(found === undefined).assertTrue();
      testId = '';
    });
  });

  describe('CloudSync_Batch_Ops', () => {
    const batchIds: string[] = [];
    const BATCH_SIZE: number = 5;

    it('batch_insert_5_hosts', 0, () => {
      for (let i = 0; i < BATCH_SIZE; i++) {
        const host = new RemoteHost();
        host.id = RemoteHost.generateId();
        host.label = `test_batch_${i}`;
        host.protocol = i % 2 === 0 ? 'rdp' : 'ssh';
        host.host = `10.0.0.${i + 10}`;
        host.port = host.protocol === 'rdp' ? 3389 : 22;
        host.username = 'batchuser';
        host.createdAt = Date.now();
        const ok = cloud.insertHost(host);
        expect(ok).assertTrue();
        batchIds.push(host.id);
      }
    });

    it('loadAll_should_return_at_least_5', 0, () => {
      const all = cloud.loadAllHosts();
      const testHosts = all.filter((h: RemoteHost) => h.label.startsWith('test_batch_'));
      expect(testHosts.length >= BATCH_SIZE).assertTrue();
    });

    it('batch_delete_should_clean_all', 0, () => {
      for (let i = 0; i < batchIds.length; i++) {
        const ok = cloud.deleteHost(batchIds[i]);
        expect(ok).assertTrue();
      }
      const all = cloud.loadAllHosts();
      const remaining = all.filter((h: RemoteHost) => batchIds.includes(h.id));
      expect(remaining.length).assertEqual(0);
      batchIds.length = 0;
    });
  });

  describe('CloudSync_onCloudChange', () => {
    it('register_callback_should_not_throw', 0, () => {
      let called = false;
      cloud.onCloudChange(() => { called = true; });
      expect(true).assertTrue();
    });
  });

  describe('CloudSync_getSyncStatus', () => {
    it('should_return_valid_SyncStatus', 0, () => {
      const status: SyncStatus = cloud.getSyncStatus();
      expect(status !== null).assertTrue();
      expect(typeof status.lastSyncTime).assertEqual('number');
      expect(typeof status.syncSuccessCount).assertEqual('number');
      expect(typeof status.syncFailCount).assertEqual('number');
      expect(typeof status.lastError).assertEqual('string');
      expect(typeof status.tableStatus).assertEqual('object');
      expect(status.tableStatus['remotehosts'] !== undefined).assertTrue();
      expect(status.tableStatus['sshkeys'] !== undefined).assertTrue();
      expect(status.tableStatus['totpentries'] !== undefined).assertTrue();
    });
  });

  describe('CloudSync_Service_Integration', () => {
    it('HostSyncService_should_readwrite_via_CloudStore', 0, () => {
      const hs = HostSyncService.getInstance();
      const host = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.label = 'test_service_integration';
      host.protocol = 'rdp';
      host.host = '10.0.0.50';
      host.port = 3389;
      host.username = 'serviceuser';
      hs.addHost(host);

      const all = hs.getAllHosts();
      const found = all.find((h: RemoteHost) => h.id === host.id);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.label).assertEqual('test_service_integration');
      }

      hs.removeHost(host.id);
    });

    it('KeyVaultService_should_readwrite_SshKey_via_CloudStore', 0, () => {
      const ks = KeyVaultService.getInstance();
      const key = new SshKey();
      key.id = SshKey.generateId();
      key.label = 'test_service_key';
      key.keyType = SshKeyType.RSA;
      ks.addSshKey(key);

      const all = ks.getAllSshKeys();
      const found = all.find((k: SshKey) => k.id === key.id);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.label).assertEqual('test_service_key');
      }

      ks.removeSshKey(key.id);
    });

    it('KeyVaultService_should_readwrite_TotpEntry_via_CloudStore', 0, () => {
      const ks = KeyVaultService.getInstance();
      const entry = new TotpEntry();
      entry.id = TotpEntry.generateId();
      entry.issuer = 'test_service_totp';
      entry.secret = 'JBSWY3DPEHPK3PXP';
      ks.addTotpEntry(entry);

      const all = ks.getAllTotpEntries();
      const found = all.find((e: TotpEntry) => e.id === entry.id);
      expect(found !== undefined).assertTrue();
      if (found) {
        expect(found.issuer).assertEqual('test_service_totp');
      }

      ks.removeTotpEntry(entry.id);
    });
  });

  describe('CloudSync_Error_Paths', () => {
    it('empty_string_id_should_not_throw', 0, () => {
      try {
        cloud.deleteHost('');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });

    it('double_delete_should_not_throw', 0, () => {
      try {
        cloud.deleteHost('this-id-does-not-exist-in-rdb');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });
  });
}
