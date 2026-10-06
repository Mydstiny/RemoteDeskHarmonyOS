/**
 * 密钥保险库 form rules shared by the classic and the modern add flows: 2FA secrets, imports and the SSH key states
 * the cards explain.
 */

/** A 2FA secret as stored: Base32 upper case, no spaces. */
export function normalizeTotpSecret(input: string): string {
  return input.trim().replace(/\s+/g, '').toUpperCase();
}

/** Why a normalized secret cannot be saved, or '' when it can. */
export function totpSecretProblem(normalized: string, existingSecrets: string[]): string {
  if (normalized.length === 0) { return '请填写密钥（Secret）'; }
  if (!/^[A-Z2-7]+=*$/.test(normalized)) { return '密钥（Secret）只能包含字母 A–Z 和数字 2–7'; }
  if (existingSecrets.indexOf(normalized) >= 0) { return '这个 2FA 账户已经添加过了'; }
  return '';
}

/** The toast after importing a file of 2FA accounts. */
export function totpImportSummary(imported: number, skipped: number): string {
  if (imported === 0 && skipped > 0) { return '文件里的 ' + skipped.toString() + ' 个账户都已存在或无效'; }
  if (skipped === 0) { return '已导入 ' + imported.toString() + ' 个 2FA 账户'; }
  return '已导入 ' + imported.toString() + ' 个，跳过 ' + skipped.toString() + ' 个已存在或无效的账户';
}

/** A key saved with a passphrase before its public key could be derived has none until the passphrase is given. */
export function sshPublicKeyMissingHint(): string {
  return '这把密钥设有口令，还没有生成公钥。请在「密钥管理 → 私钥内容」里输入口令后保存。';
}

/** Batch delete wording, with the locked keys called out. */
export function keyVaultBatchDeleteMessage(count: number, lockedCount: number, ssh: boolean): string {
  const noun: string = ssh ? '把 SSH 密钥' : '个 2FA 账户';
  let message: string = '确定删除选中的 ' + count.toString() + ' ' + noun + '吗？此操作不可恢复。';
  if (lockedCount > 0) { message += '其中 ' + lockedCount.toString() + ' 把已锁定，删除前需要验证身份。'; }
  return message;
}
