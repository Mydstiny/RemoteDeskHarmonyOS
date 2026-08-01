/**
 * Pure safety policy for ordinary distributed tables.
 *
 * HarmonyOS cloudSync operates on a physical table, not on one projected row.
 * A native-first transfer is therefore allowed only when every non-empty
 * secret in the selected physical table is already an authenticated
 * ciphertext. This prevents a local crypto disable/reset or a legacy
 * plaintext row from being published by an unrelated later table sync.
 */

export type CloudCiphertextProbe = (value: string) => boolean;

const SENSITIVE_BUSINESS_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

const SENSITIVE_COLUMNS: Record<string, string[]> = {
  'remotehosts': ['passward', 'sshkeydata'],
  'rdpcredentials': ['password'],
  'rustdeskrelays': ['apipassword', 'key'],
  'sshkeys': ['privatekey'],
  'totpentries': ['secret']
};

export function cloudSensitiveBusinessTables(): string[] {
  return SENSITIVE_BUSINESS_TABLES.slice();
}

export function cloudTableRequiresConfiguredCrypto(table: string): boolean {
  return table === 'cryptoparams' ||
    SENSITIVE_BUSINESS_TABLES.indexOf(table) >= 0;
}

function scalarSecretsAreSafe(
  table: string,
  row: Record<string, string>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  const columns: string[] = SENSITIVE_COLUMNS[table] || [];
  for (let i = 0; i < columns.length; i++) {
    const value: string = row[columns[i]] || '';
    if (value !== '' && !ciphertextProbe(value)) { return false; }
  }
  return true;
}

function relayAccountSecretsAreSafe(
  row: Record<string, string>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  const raw: string = row['accountsjson'] || '';
  if (raw === '') { return true; }
  try {
    const accounts: Array<Record<string, Object>> =
      JSON.parse(raw) as Array<Record<string, Object>>;
    if (!Array.isArray(accounts)) { return false; }
    for (let i = 0; i < accounts.length; i++) {
      if (!accounts[i] || typeof accounts[i] !== 'object' ||
        Array.isArray(accounts[i])) {
        return false;
      }
      const password: Object | undefined = accounts[i]['password'];
      if (password !== undefined && typeof password !== 'string') {
        return false;
      }
      const value: string =
        typeof password === 'string' ? password as string : '';
      if (value !== '' && !ciphertextProbe(value)) { return false; }
    }
    return true;
  } catch (_e) {
    return false;
  }
}

function encryptedRowsAreSafe(
  table: string,
  rows: Array<Record<string, string>>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  for (let i = 0; i < rows.length; i++) {
    if (!scalarSecretsAreSafe(table, rows[i], ciphertextProbe)) {
      return false;
    }
    if (table === 'rustdeskrelays' &&
      !relayAccountSecretsAreSafe(rows[i], ciphertextProbe)) {
      return false;
    }
  }
  return true;
}

/**
 * Native-first is stricter than download compatibility. Even an empty
 * sensitive table remains blocked while crypto is disabled, because it may
 * carry local reset/delete intent that must not become a remote wipe.
 */
export function cloudTableRowsAreUploadSafe(
  table: string,
  rows: Array<Record<string, string>>,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  if (!cloudTableRequiresConfiguredCrypto(table)) { return true; }
  // Encryption configuration is the user's explicit choice, never a
  // presumption. Without a configured crypto contract the secrets upload as
  // stored (plaintext, chosen by the user); with a configured contract every
  // secret in the snapshot must be ciphertext.
  if (!cryptoConfigured) { return true; }
  if (table === 'cryptoparams') { return true; }
  return encryptedRowsAreSafe(table, rows, ciphertextProbe);
}

/**
 * Legacy cloud rows created before encryption remain readable when the cloud
 * account has no crypto contract. Once cryptoparams declare active encryption,
 * every non-empty secret in the same snapshot must be ciphertext.
 */
export function cloudTableRowsAreDownloadCompatible(
  table: string,
  rows: Array<Record<string, string>>,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  if (table === 'cryptoparams' ||
    SENSITIVE_BUSINESS_TABLES.indexOf(table) < 0 ||
    !cryptoConfigured) {
    return true;
  }
  return encryptedRowsAreSafe(table, rows, ciphertextProbe);
}

/**
 * A local crypto disable pauses ordinary secret-bearing tables but can keep
 * settings and VNC metadata selected. A forgotten-password reset also pauses
 * the VNC physical table so its local deletes cannot become a remote wipe.
 */
export function cloudSelectionAfterLocalCryptoTransition(
  selected: string[],
  reset: boolean
): string[] {
  const result: string[] = [];
  for (let i = 0; i < selected.length; i++) {
    const table: string = selected[i];
    if (SENSITIVE_BUSINESS_TABLES.indexOf(table) >= 0) { continue; }
    if (reset && table === 'vncrecordv2') { continue; }
    result.push(table);
  }
  return result;
}

export function vncSelectionAfterLocalCryptoTransition(
  selected: string[],
  reset: boolean
): string[] {
  if (reset) { return []; }
  return selected.filter((scope: string): boolean => scope !== 'secrets');
}
