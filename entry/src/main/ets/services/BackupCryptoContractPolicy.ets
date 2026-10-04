/**
 * What a full-backup restore may take from the backup's crypto parameters.
 *
 * A full backup from an encrypted source carries its cryptoparams (salt,
 * verifier, status, reset epoch) so the source's master password can unlock
 * its ciphertext on a fresh device. Merging them into a device that has its
 * own master password would replace that device's salt/verifier and make its
 * existing ciphertext permanently undecryptable; a later "upload this device"
 * would spread the damage to the cloud. A device's own crypto contract is
 * therefore never overwritten by a restore.
 */

/**
 * adopt: the target has no master password and the backup carries a complete
 *   contract; take the backup's cryptoparams (unlock afterwards with the
 *   backup's master password).
 * keep_target: keep the target's parameters and merge the secrets; the
 *   backup has no contract (plaintext secrets, encrypted by the next unlock's
 *   migration when the target has a master password) or the same contract.
 * secrets_withheld: the contracts differ (every master-password setup draws a
 *   new salt, so this also happens when the same password was set on both
 *   devices), or a file without a contract carries ciphertext; keep the
 *   target's parameters and do not import the encrypted fields, which no key
 *   on this device can open.
 */
export type BackupCryptoRestoreDecision = 'adopt' | 'keep_target' | 'secrets_withheld';

export interface BackupCryptoContract {
  configured: boolean;
  salt: string;
  verifier: string;
}

export function backupCryptoContract(salt: string, verifier: string): BackupCryptoContract {
  return { configured: salt !== '' && verifier !== '', salt: salt, verifier: verifier };
}

/** Contract described by cryptoparams rows ({id, key, value}). */
export function backupCryptoContractFromRows(
  rows: Array<Record<string, string>>
): BackupCryptoContract {
  let salt: string = '';
  let verifier: string = '';
  for (let i = 0; i < rows.length; i++) {
    const key: string = rows[i]['key'] || '';
    if (key === 'crypto_salt') { salt = rows[i]['value'] || ''; }
    if (key === 'crypto_verifier') { verifier = rows[i]['value'] || ''; }
  }
  return backupCryptoContract(salt, verifier);
}

export function decideBackupCryptoRestore(
  backup: BackupCryptoContract,
  target: BackupCryptoContract
): BackupCryptoRestoreDecision {
  if (!target.configured) { return backup.configured ? 'adopt' : 'keep_target'; }
  if (!backup.configured) { return 'keep_target'; }
  return backup.salt === target.salt && backup.verifier === target.verifier ?
    'keep_target' : 'secrets_withheld';
}

/** cryptoparams rows a restore may merge; only an unconfigured target adopts them. */
export function backupCryptoRowsToMerge(
  rows: Array<Record<string, string>>,
  decision: BackupCryptoRestoreDecision
): Array<Record<string, string>> {
  return decision === 'adopt' ? rows.slice() : [];
}

/** Message shown when a restore withholds encrypted fields (preview and result). */
export const BACKUP_CRYPTO_SECRETS_WITHHELD_MESSAGE: string =
  '备份与本机的加密参数不同（两台设备各自设置过主密码时，即使密码相同也不同）：' +
  '只恢复主机等普通配置，密码、私钥、2FA 等加密数据不会导入，本机现有数据不受影响。' +
  '如需导入加密数据，请在尚未设置主密码的设备上恢复';

/** Message for a full backup without crypto parameters that still carries ciphertext. */
export const BACKUP_CRYPTO_UNREADABLE_WITHHELD_MESSAGE: string =
  '备份缺少加密参数却包含加密数据（文件可能已损坏或被修改）：只恢复主机等普通配置，' +
  '加密数据不会导入，本机现有数据不受影响';

/** Message for a withheld restore, by whether the backup carried a contract. */
export function backupCryptoWithheldMessage(backupConfigured: boolean): string {
  return backupConfigured ? BACKUP_CRYPTO_SECRETS_WITHHELD_MESSAGE :
    BACKUP_CRYPTO_UNREADABLE_WITHHELD_MESSAGE;
}

/** Restore preview line; '' when nothing needs saying (redacted backups carry no secrets). */
export function backupCryptoRestoreNotice(
  decision: BackupCryptoRestoreDecision,
  backupConfigured: boolean,
  targetConfigured: boolean,
  fullBackup: boolean
): string {
  if (!fullBackup) { return ''; }
  if (decision === 'secrets_withheld') {
    return '；' + backupCryptoWithheldMessage(backupConfigured);
  }
  if (decision === 'adopt' && backupConfigured) {
    return '；备份带有主密码加密，恢复后需输入备份时的主密码解锁';
  }
  if (decision === 'keep_target' && !backupConfigured && targetConfigured) {
    return '；备份中的密码未加密，解锁后会自动用本机主密码加密';
  }
  return '';
}
