import { describe, expect, it } from '@ohos/hypium';
import {
  BackupCryptoContract,
  backupCryptoContract,
  backupCryptoContractFromRows,
  backupCryptoRestoreNotice,
  backupCryptoRowsToMerge,
  decideBackupCryptoRestore
} from '../main/ets/services/BackupCryptoContractPolicy';

function paramRow(key: string, value: string): Record<string, string> {
  const row: Record<string, string> = {};
  row['id'] = 'owner:' + key;
  row['key'] = key;
  row['value'] = value;
  return row;
}

export default function backupCryptoContractPolicyTest(): void {
  describe('BackupCryptoContractPolicy', (): void => {
    it('never_replaces_a_configured_target_contract', 0, (): void => {
      const backupRows: Array<Record<string, string>> = [
        paramRow('crypto_status', 'active'), paramRow('crypto_salt', 'salt-a'),
        paramRow('crypto_verifier', 'verifier-a'), paramRow('vnc_reset_epoch', '3')
      ];
      const backup: BackupCryptoContract = backupCryptoContractFromRows(backupRows);
      expect(backup.configured).assertTrue();
      const other: BackupCryptoContract = backupCryptoContract('salt-b', 'verifier-b');
      const same: BackupCryptoContract = backupCryptoContract('salt-a', 'verifier-a');
      expect(decideBackupCryptoRestore(backup, other)).assertEqual('secrets_withheld');
      expect(decideBackupCryptoRestore(backup, same)).assertEqual('keep_target');
      expect(backupCryptoRowsToMerge(backupRows, 'secrets_withheld').length).assertEqual(0);
      expect(backupCryptoRowsToMerge(backupRows, 'keep_target').length).assertEqual(0);
    });

    it('lets_only_a_target_without_a_master_password_adopt_the_backup', 0, (): void => {
      const backupRows: Array<Record<string, string>> = [
        paramRow('crypto_salt', 'salt-a'), paramRow('crypto_verifier', 'verifier-a')
      ];
      const none: BackupCryptoContract = backupCryptoContract('', '');
      const decision = decideBackupCryptoRestore(backupCryptoContractFromRows(backupRows), none);
      expect(decision).assertEqual('adopt');
      expect(backupCryptoRowsToMerge(backupRows, decision).length).assertEqual(2);
      // A half-written contract (salt without verifier) is not a contract,
      // and an unconfigured target never adopts parameters without one.
      expect(backupCryptoContract('salt-only', '').configured).assertFalse();
      const statusOnly: Array<Record<string, string>> = [paramRow('crypto_status', 'active')];
      expect(decideBackupCryptoRestore(backupCryptoContractFromRows(statusOnly), none))
        .assertEqual('keep_target');
    });

    it('keeps_the_target_contract_for_an_unencrypted_full_backup', 0, (): void => {
      const disabledRows: Array<Record<string, string>> = [paramRow('crypto_status', 'disabled')];
      const target: BackupCryptoContract = backupCryptoContract('salt-b', 'verifier-b');
      expect(decideBackupCryptoRestore(backupCryptoContractFromRows(disabledRows), target))
        .assertEqual('keep_target');
    });

    it('explains_the_decision_only_for_full_backups', 0, (): void => {
      const withheld: string = backupCryptoRestoreNotice('secrets_withheld', true, true, true);
      expect(withheld.indexOf('加密参数不同') >= 0).assertTrue();
      expect(withheld.indexOf('即使密码相同') >= 0).assertTrue();
      expect(backupCryptoRestoreNotice('adopt', true, false, true).indexOf('备份时的主密码') >= 0)
        .assertTrue();
      expect(backupCryptoRestoreNotice('keep_target', false, true, true).indexOf('自动用本机主密码加密') >= 0)
        .assertTrue();
      expect(backupCryptoRestoreNotice('secrets_withheld', false, true, true).indexOf('缺少加密参数') >= 0)
        .assertTrue();
      // Plain backup into a device without a master password: nothing to say.
      expect(backupCryptoRestoreNotice('keep_target', false, false, true)).assertEqual('');
      expect(backupCryptoRestoreNotice('keep_target', true, true, true)).assertEqual('');
      expect(backupCryptoRestoreNotice('keep_target', false, true, false)).assertEqual('');
    });
  });
}
