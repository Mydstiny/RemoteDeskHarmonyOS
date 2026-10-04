/**
 * What a forgotten-master-password reset removes (user decision 2026-10-04):
 * only the encrypted secrets, which no key can open any more. Hosts,
 * addresses, ports, user names, groups, display settings, device-local LAN
 * hosts, device trust and key/credential/relay links stay. The reset stays a
 * local operation; it is not published as a remote wipe.
 */

const RESET_SECRET_COLUMNS: Record<string, string[]> = {
  'remotehosts': ['password', 'passward', 'sshkeydata', 'sshkeypassphrase'],
  'rdpcredentials': ['password'],
  'rustdeskrelays': ['apipassword', 'key'],
  'sshkeys': ['privatekey'],
  'totpentries': ['secret']
};

/** Secret keys inside device-local extension payloads, by extension table. */
const RESET_EXTENSION_SECRET_KEYS: Record<string, string[]> = {
  'remotehosts': ['password', 'sshkeypassphrase', 'sshproxypassword', 'sshproxykeypassphrase'],
  'dynamiclanhosts': [
    'password', 'sshkeydata', 'sshkeypassphrase', 'sshproxypassword', 'sshproxykeypassphrase'
  ]
};

/** Extension tables that hold nothing but a secret; their rows are removed. */
const RESET_SECRET_ONLY_EXTENSION_TABLES: string[] = ['rdprestrictedadminsecrets'];

// Table names come from stored rows; look them up among own keys only, so a
// corrupt name such as `constructor` cannot resolve to an Object member.
const RESET_SECRET_TABLES: string[] = Object.keys(RESET_SECRET_COLUMNS);
const RESET_EXTENSION_TABLES: string[] = Object.keys(RESET_EXTENSION_SECRET_KEYS);

export function cryptoResetSecretColumns(table: string): string[] {
  return RESET_SECRET_TABLES.indexOf(table) >= 0 ? RESET_SECRET_COLUMNS[table].slice() : [];
}

export function cryptoResetSecretTables(): string[] {
  return RESET_SECRET_TABLES.slice();
}

/**
 * Relay account lists keep each account's name and settings; only the
 * password is cleared. An unreadable list cannot be partially cleared, so it
 * is removed as a whole.
 */
export function cryptoResetRelayAccountsJson(raw: string): string {
  if (raw === '') { return ''; }
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) { return ''; }
    const accounts: Array<Record<string, Object>> = parsed as Array<Record<string, Object>>;
    for (let i = 0; i < accounts.length; i++) {
      const account: Record<string, Object> = accounts[i];
      if (account === null || typeof account !== 'object' || Array.isArray(account)) { return ''; }
      if (account['password'] !== undefined) { account['password'] = ''; }
    }
    return JSON.stringify(accounts);
  } catch (_e) {
    return '';
  }
}

/** Cleared copy of one extension payload, or null when the row must be removed. */
export function cryptoResetExtensionPayload(
  table: string,
  payload: Record<string, string>
): Record<string, string> | null {
  if (RESET_SECRET_ONLY_EXTENSION_TABLES.indexOf(table) >= 0) { return null; }
  const secretKeys: string[] | undefined = RESET_EXTENSION_TABLES.indexOf(table) >= 0 ?
    RESET_EXTENSION_SECRET_KEYS[table] : undefined;
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(payload);
  for (let i = 0; i < keys.length; i++) {
    result[keys[i]] = secretKeys !== undefined && secretKeys.indexOf(keys[i]) >= 0 ?
      '' : payload[keys[i]];
  }
  return result;
}

/**
 * Tables whose pending local-mutation journal a reset discards. A reset is a
 * local operation: none of its changes may become a pending upload, so when a
 * table is turned back on its cloud-first download wins instead of the reset
 * (a journal entry would make the re-enable restore the local before-image
 * and push it). Pending edits made before the reset are discarded with it.
 */
export function cryptoResetJournalTables(vncCloudTable: string, vncLocalTable: string): string[] {
  return RESET_SECRET_TABLES.concat([vncCloudTable, vncLocalTable, 'cryptoparams']);
}

/**
 * Tables whose uploads stay blocked after a reset until the user explicitly
 * makes this device authoritative. The platform keeps its own record of
 * local changes on distributed tables, and a cloud-first pull need not
 * replace rows the cloud did not change, so dropping the app journal alone
 * cannot prove the reset will never be uploaded.
 */
export function cryptoResetUploadBlockTables(vncCloudTable: string): string[] {
  return RESET_SECRET_TABLES.concat([vncCloudTable, 'cryptoparams']);
}

/** VNC secret records are removed; host, gateway, settings and trust records stay. */
export function cryptoResetKeepsVncRecord(recordType: string): boolean {
  return recordType !== 'secret';
}
