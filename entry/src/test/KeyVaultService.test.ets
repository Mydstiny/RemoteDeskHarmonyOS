/**
 * KeyVaultService.test.ets — KeyVaultService unit tests (hypium)
 *
 * Test scope:
 *   1. Singleton pattern
 *   2. SSH key CRUD (add/update/remove/getAll/get/count)
 *   3. TOTP entry CRUD (add/update/remove/getAll/get/count)
 *   4. Sort order (desc by createdAt)
 *   5. Edge cases (empty vault, nonexistent ID, duplicate add)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { KeyVaultService } from '../main/ets/services/KeyVaultService';
import { SshKey, SshKeyType } from '../main/ets/model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../main/ets/model/TotpEntry';

function makeSshKey(label: string, keyType: SshKeyType): SshKey {
  const key = new SshKey();
  key.id = SshKey.generateId();
  key.label = label;
  key.keyType = keyType;
  key.publicKey = `mock-public-key-${label}`;
  key.privateKey = `mock-private-key-${label}`;
  key.fingerprint = `SHA256:mock-${label}`;
  key.createdAt = Date.now();
  return key;
}

function makeTotpEntry(issuer: string, account: string): TotpEntry {
  const entry = new TotpEntry();
  entry.id = TotpEntry.generateId();
  entry.issuer = issuer;
  entry.account = account;
  entry.secret = 'JBSWY3DPEHPK3PXP';
  entry.algorithm = TotpAlgorithm.SHA1;
  entry.digits = 6;
  entry.period = 30;
  entry.createdAt = Date.now();
  return entry;
}

export default function keyVaultServiceTest() {
  let srv: KeyVaultService;

  beforeEach(() => {
    srv = KeyVaultService.getInstance();
    const sshKeys = srv.getAllSshKeys();
    for (let i = 0; i < sshKeys.length; i++) {
      srv.removeSshKey(sshKeys[i].id);
    }
    const totps = srv.getAllTotpEntries();
    for (let i = 0; i < totps.length; i++) {
      srv.removeTotpEntry(totps[i].id);
    }
  });

  describe('KeyVaultService_Singleton', () => {
    it('getInstance_should_return_same_instance', 0, () => {
      const a = KeyVaultService.getInstance();
      const b = KeyVaultService.getInstance();
      expect(a === b).assertTrue();
    });
  });

  describe('KeyVaultService_SSH_addSshKey', () => {
    it('count_should_be_1_after_add', 0, () => {
      const key = makeSshKey('prod_key', SshKeyType.ED25519);
      srv.addSshKey(key);
      expect(srv.getSshKeyCount()).assertEqual(1);
    });

    it('should_auto_generate_id_if_empty', 0, () => {
      const key = makeSshKey('no_id_key', SshKeyType.RSA);
      key.id = '';
      srv.addSshKey(key);
      expect(key.id.length > 0).assertTrue();
      expect(key.id.startsWith('sshkey_')).assertTrue();
    });

    it('should_retrieve_by_getSshKey', 0, () => {
      const key = makeSshKey('retrieve_test', SshKeyType.ECDSA);
      srv.addSshKey(key);
      const retrieved = srv.getSshKey(key.id);
      expect(retrieved !== undefined).assertTrue();
      if (retrieved) {
        expect(retrieved.label).assertEqual('retrieve_test');
        expect(retrieved.keyType).assertEqual(SshKeyType.ECDSA);
      }
    });

    it('createdAt_should_be_set', 0, () => {
      const key = makeSshKey('ts_test', SshKeyType.RSA);
      key.createdAt = 0;
      srv.addSshKey(key);
      expect(key.createdAt > 0).assertTrue();
    });

    it('count_should_increment_with_multiple_adds', 0, () => {
      srv.addSshKey(makeSshKey('keyA', SshKeyType.RSA));
      srv.addSshKey(makeSshKey('keyB', SshKeyType.ED25519));
      srv.addSshKey(makeSshKey('keyC', SshKeyType.ECDSA));
      expect(srv.getSshKeyCount()).assertEqual(3);
    });

    it('all_key_types_should_work', 0, () => {
      srv.addSshKey(makeSshKey('rsa_key', SshKeyType.RSA));
      srv.addSshKey(makeSshKey('ed_key', SshKeyType.ED25519));
      srv.addSshKey(makeSshKey('ec_key', SshKeyType.ECDSA));
      srv.addSshKey(makeSshKey('dsa_key', SshKeyType.DSA));
      expect(srv.getSshKeyCount()).assertEqual(4);
    });
  });

  describe('KeyVaultService_SSH_updateSshKey', () => {
    it('update_existing_should_succeed', 0, () => {
      const key = makeSshKey('original_name', SshKeyType.RSA);
      srv.addSshKey(key);
      key.label = 'new_name';
      key.keyType = SshKeyType.ED25519;
      const result = srv.updateSshKey(key);
      expect(result).assertTrue();
      const updated = srv.getSshKey(key.id);
      if (updated) {
        expect(updated.label).assertEqual('new_name');
        expect(updated.keyType).assertEqual(SshKeyType.ED25519);
      }
    });

    it('update_nonexistent_should_return_false', 0, () => {
      const ghost = makeSshKey('ghost', SshKeyType.RSA);
      ghost.id = 'nonexistent-ssh-id';
      expect(srv.updateSshKey(ghost)).assertFalse();
    });

    it('update_should_not_change_count', 0, () => {
      const key = makeSshKey('count_test', SshKeyType.RSA);
      srv.addSshKey(key);
      key.label = 'renamed';
      srv.updateSshKey(key);
      expect(srv.getSshKeyCount()).assertEqual(1);
    });
  });

  describe('KeyVaultService_SSH_removeSshKey', () => {
    it('remove_existing_should_return_true', 0, () => {
      const key = makeSshKey('to_delete', SshKeyType.RSA);
      srv.addSshKey(key);
      expect(srv.removeSshKey(key.id)).assertTrue();
      expect(srv.getSshKeyCount()).assertEqual(0);
    });

    it('remove_nonexistent_should_return_false', 0, () => {
      expect(srv.removeSshKey('nonexistent-id')).assertFalse();
    });

    it('getSshKey_should_return_undefined_after_remove', 0, () => {
      const key = makeSshKey('temp', SshKeyType.RSA);
      srv.addSshKey(key);
      srv.removeSshKey(key.id);
      expect(srv.getSshKey(key.id) === undefined).assertTrue();
    });
  });

  describe('KeyVaultService_SSH_getAllSshKeys', () => {
    it('empty_vault_should_return_empty_array', 0, () => {
      expect(srv.getAllSshKeys().length).assertEqual(0);
    });

    it('should_return_all_added_keys', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 5; i++) {
        const k = makeSshKey(`key${i}`, SshKeyType.RSA);
        srv.addSshKey(k);
        ids.add(k.id);
      }
      const all = srv.getAllSshKeys();
      expect(all.length).assertEqual(5);
      for (let i = 0; i < all.length; i++) {
        expect(ids.has(all[i].id)).assertTrue();
      }
    });

    it('should_sort_desc_by_createdAt', 0, () => {
      const k1 = makeSshKey('old', SshKeyType.RSA);
      k1.createdAt = 1000;
      const k2 = makeSshKey('new', SshKeyType.ED25519);
      k2.createdAt = 3000;
      const k3 = makeSshKey('mid', SshKeyType.ECDSA);
      k3.createdAt = 2000;

      srv.addSshKey(k1);
      srv.addSshKey(k2);
      srv.addSshKey(k3);

      const all = srv.getAllSshKeys();
      expect(all.length).assertEqual(3);
      expect(all[0].createdAt).assertEqual(3000);
      expect(all[1].createdAt).assertEqual(2000);
      expect(all[2].createdAt).assertEqual(1000);
    });
  });

  describe('KeyVaultService_TOTP_addTotpEntry', () => {
    it('count_should_be_1_after_add', 0, () => {
      const entry = makeTotpEntry('GitHub', 'user@example.com');
      srv.addTotpEntry(entry);
      expect(srv.getTotpCount()).assertEqual(1);
    });

    it('should_auto_generate_id_if_empty', 0, () => {
      const entry = makeTotpEntry('GitLab', 'admin@gitlab.com');
      entry.id = '';
      srv.addTotpEntry(entry);
      expect(entry.id.length > 0).assertTrue();
      expect(entry.id.startsWith('totp_')).assertTrue();
    });

    it('should_retrieve_by_getTotpEntry', 0, () => {
      const entry = makeTotpEntry('AWS', 'root@aws');
      srv.addTotpEntry(entry);
      const retrieved = srv.getTotpEntry(entry.id);
      expect(retrieved !== undefined).assertTrue();
      if (retrieved) {
        expect(retrieved.issuer).assertEqual('AWS');
        expect(retrieved.account).assertEqual('root@aws');
      }
    });

    it('createdAt_should_be_set', 0, () => {
      const entry = makeTotpEntry('TestIssuer', 'test@test.com');
      entry.createdAt = 0;
      srv.addTotpEntry(entry);
      expect(entry.createdAt > 0).assertTrue();
    });

    it('count_should_increment_with_multiple_adds', 0, () => {
      srv.addTotpEntry(makeTotpEntry('GitHub', 'a@b.com'));
      srv.addTotpEntry(makeTotpEntry('GitLab', 'c@d.com'));
      srv.addTotpEntry(makeTotpEntry('AWS', 'e@f.com'));
      expect(srv.getTotpCount()).assertEqual(3);
    });

    it('batch_add_should_emit_once_and_return_all_ids', 0, () => {
      let notifications = 0;
      const unsubscribe = srv.onDataChange((): void => { notifications++; });
      const result = srv.addTotpEntries([
        makeTotpEntry('GitHub', 'batch-a@example.com'),
        makeTotpEntry('GitLab', 'batch-b@example.com')
      ]);
      unsubscribe();
      expect(result.savedIds.length).assertEqual(2);
      expect(result.failedCount).assertEqual(0);
      expect(srv.getTotpCount()).assertEqual(2);
      expect(notifications).assertEqual(1);
    });
  });

  describe('KeyVaultService_TOTP_updateTotpEntry', () => {
    it('update_existing_should_succeed', 0, () => {
      const entry = makeTotpEntry('OldIssuer', 'orig@acct.com');
      srv.addTotpEntry(entry);
      entry.issuer = 'NewIssuer';
      entry.digits = 8;
      const result = srv.updateTotpEntry(entry);
      expect(result).assertTrue();
      const updated = srv.getTotpEntry(entry.id);
      if (updated) {
        expect(updated.issuer).assertEqual('NewIssuer');
        expect(updated.digits).assertEqual(8);
      }
    });

    it('update_nonexistent_should_return_false', 0, () => {
      const ghost = makeTotpEntry('Ghost', 'ghost@ghost.com');
      ghost.id = 'nonexistent-totp-id';
      expect(srv.updateTotpEntry(ghost)).assertFalse();
    });

    it('update_should_not_change_count', 0, () => {
      const entry = makeTotpEntry('CountTest', 'ct@test.com');
      srv.addTotpEntry(entry);
      entry.issuer = 'Renamed';
      srv.updateTotpEntry(entry);
      expect(srv.getTotpCount()).assertEqual(1);
    });
  });

  describe('KeyVaultService_TOTP_removeTotpEntry', () => {
    it('remove_existing_should_return_true', 0, () => {
      const entry = makeTotpEntry('ToDelete', 'del@test.com');
      srv.addTotpEntry(entry);
      expect(srv.removeTotpEntry(entry.id)).assertTrue();
      expect(srv.getTotpCount()).assertEqual(0);
    });

    it('remove_nonexistent_should_return_false', 0, () => {
      expect(srv.removeTotpEntry('nonexistent-id')).assertFalse();
    });

    it('getTotpEntry_should_return_undefined_after_remove', 0, () => {
      const entry = makeTotpEntry('Temp', 'tmp@test.com');
      srv.addTotpEntry(entry);
      srv.removeTotpEntry(entry.id);
      expect(srv.getTotpEntry(entry.id) === undefined).assertTrue();
    });
  });

  describe('KeyVaultService_TOTP_getAllTotpEntries', () => {
    it('empty_vault_should_return_empty_array', 0, () => {
      expect(srv.getAllTotpEntries().length).assertEqual(0);
    });

    it('should_return_all_added_entries', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 5; i++) {
        const e = makeTotpEntry(`Issuer${i}`, `acct${i}@test.com`);
        srv.addTotpEntry(e);
        ids.add(e.id);
      }
      const all = srv.getAllTotpEntries();
      expect(all.length).assertEqual(5);
      for (let i = 0; i < all.length; i++) {
        expect(ids.has(all[i].id)).assertTrue();
      }
    });

    it('should_sort_desc_by_createdAt', 0, () => {
      const e1 = makeTotpEntry('Old', 'old@test.com');
      e1.createdAt = 1000;
      const e2 = makeTotpEntry('New', 'new@test.com');
      e2.createdAt = 3000;
      const e3 = makeTotpEntry('Mid', 'mid@test.com');
      e3.createdAt = 2000;

      srv.addTotpEntry(e1);
      srv.addTotpEntry(e2);
      srv.addTotpEntry(e3);

      const all = srv.getAllTotpEntries();
      expect(all.length).assertEqual(3);
      expect(all[0].createdAt).assertEqual(3000);
      expect(all[1].createdAt).assertEqual(2000);
      expect(all[2].createdAt).assertEqual(1000);
    });
  });

  describe('KeyVaultService_Edge_Cases', () => {
    it('empty_vault_getSshKeyCount_should_be_0', 0, () => {
      expect(srv.getSshKeyCount()).assertEqual(0);
    });

    it('empty_vault_getTotpCount_should_be_0', 0, () => {
      expect(srv.getTotpCount()).assertEqual(0);
    });

    it('empty_vault_getSshKey_should_return_undefined', 0, () => {
      expect(srv.getSshKey('any-id') === undefined).assertTrue();
    });

    it('empty_vault_getTotpEntry_should_return_undefined', 0, () => {
      expect(srv.getTotpEntry('any-id') === undefined).assertTrue();
    });

    it('locked_field_should_serialize_correctly', 0, () => {
      const key = makeSshKey('locked_key', SshKeyType.RSA);
      key.locked = true;
      key.lockType = 3;
      srv.addSshKey(key);
      const retrieved = srv.getSshKey(key.id);
      if (retrieved) {
        expect(retrieved.locked).assertTrue();
        expect(retrieved.lockType).assertEqual(3);
      }
    });

    it('algorithm_config_should_serialize_correctly', 0, () => {
      const entry = makeTotpEntry('SHA256Test', 'sha256@test.com');
      entry.algorithm = TotpAlgorithm.SHA256;
      entry.digits = 8;
      entry.period = 60;
      srv.addTotpEntry(entry);
      const retrieved = srv.getTotpEntry(entry.id);
      if (retrieved) {
        expect(retrieved.algorithm).assertEqual(TotpAlgorithm.SHA256);
        expect(retrieved.digits).assertEqual(8);
        expect(retrieved.period).assertEqual(60);
      }
    });

    it('typeLabel_should_return_correct_names', 0, () => {
      expect(SshKey.typeLabel(SshKeyType.RSA)).assertEqual('RSA');
      expect(SshKey.typeLabel(SshKeyType.ED25519)).assertEqual('ED25519');
      expect(SshKey.typeLabel(SshKeyType.ECDSA)).assertEqual('ECDSA');
      expect(SshKey.typeLabel(SshKeyType.DSA)).assertEqual('DSA');
    });

    it('algoLabel_should_return_correct_names', 0, () => {
      expect(TotpEntry.algoLabel(TotpAlgorithm.SHA1)).assertEqual('SHA1');
      expect(TotpEntry.algoLabel(TotpAlgorithm.SHA256)).assertEqual('SHA256');
      expect(TotpEntry.algoLabel(TotpAlgorithm.SHA512)).assertEqual('SHA512');
    });

    it('displayLabel_should_format_correctly', 0, () => {
      const e1 = makeTotpEntry('GitHub', 'user@github.com');
      expect(e1.displayLabel()).assertEqual('GitHub (user@github.com)');

      const e2 = makeTotpEntry('GenericIssuer', '');
      e2.account = '';
      expect(e2.displayLabel()).assertEqual('GenericIssuer');
    });
  });
}
