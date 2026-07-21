import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CLOUD_SYNC_TABLES } from './CloudSyncPolicy';

export const LOCAL_BACKUP_FORMAT: string = 'remotedesktop-local-backup';
export const LOCAL_BACKUP_VERSION: number = 2;
export const LOCAL_BACKUP_MAX_BYTES: number = 32 * 1024 * 1024;
const DISTRIBUTED_SYSTEM_COLUMNS: string[] = ['#_deleted_flag'];
const LOCAL_EXTENSION_TABLES: string[] = [
  'remotehosts', 'rdpcredentials', 'sshkeys', 'rdprestrictedadminsecrets'
];
const REMOTE_HOST_EXTENSION_PAYLOAD_COLUMNS: string[] = [
  // `password` is a legacy shadow that migration may still need to recover.
  'password', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm',
  'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat',
  'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
  'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatetrustedat',
  'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot',
  'rdpcertificateallowhostmismatch', 'rustdeskrelayid', 'rustdeskaccountid',
  'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled',
  'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'rdpauthmode',
  'rdprestrictedadminsecretsource', 'sourcetype', 'rustdeskproaccountid',
  'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged',
  'rustdeskprolastseenat', 'rustdeskprosyncerror'
];

export interface LocalBackupDocument {
  format: string;
  version: number;
  createdAt: number;
  appVersion: string;
  tables: Record<string, Array<Record<string, string>>>;
  extensions?: Array<Record<string, string>>;
  sha256: string;
}

export function localBackupColumnsForTable(table: string): string[] {
  if (table === 'cryptoparams') { return ['id', 'key', 'value']; }
  if (table === 'usersettings') { return ['id', 'userid', 'key', 'value', 'payload', 'schemaversion', 'updatedat']; }
  if (table === 'remotehosts') {
    return ['id', 'userid', 'label', 'protocol', 'host', 'port', 'username', 'password', 'passward', 'customhostname', 'sshusekey', 'sshkeypath', 'sshkeydata', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject', 'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'proxyhost', 'proxyport', 'proxyusername', 'gatewayhost', 'gatewayport', 'displayconfig', 'locked', 'locktype', 'isfavorite', 'groupid', 'sortorder', 'icon', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskrelayid', 'rustdeskaccountid', 'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled', 'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'sourcetype', 'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror', 'createdat', 'updatedat'];
  }
  if (table === 'rdpcredentials') { return ['id', 'label', 'username', 'password', 'createdat', 'updatedat']; }
  if (table === 'rustdeskrelays') { return ['id', 'userid', 'idserver', 'idserverport', 'relayserver', 'relayport', 'apiserver', 'apiusername', 'apipassword', 'key', 'healthstatus', 'healthlatency', 'healthcheckedat', 'apiloginstatus', 'accountsjson', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['id', 'userid', 'label', 'keytype', 'publickey', 'privatekey', 'fingerprint', 'comment', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['id', 'userid', 'issuer', 'account', 'secret', 'algorithm', 'digits', 'period', 'iconurl', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  return [];
}

export function localBackupLocalExtensionColumns(): string[] {
  return ['id', 'tablename', 'recordid', 'payload', 'updatedat'];
}

function localBackupIntegerColumns(table: string): string[] {
  if (table === 'usersettings') { return ['schemaversion', 'updatedat']; }
  if (table === 'remotehosts') { return ['port', 'sshusekey', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'proxyport', 'gatewayport', 'locked', 'locktype', 'isfavorite', 'sortorder', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskpasswordmode', 'rustdeskdirectenabled', 'rustdeskdirectport', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'createdat', 'updatedat']; }
  if (table === 'rdpcredentials') { return ['createdat', 'updatedat']; }
  if (table === 'rustdeskrelays') { return ['idserverport', 'relayport', 'healthlatency', 'healthcheckedat', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['keytype', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['algorithm', 'digits', 'period', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  return [];
}

function isDistributedSystemColumn(column: string): boolean {
  return DISTRIBUTED_SYSTEM_COLUMNS.indexOf(column) >= 0;
}

function backupRowsContainOnlyKnownColumns(table: string, rows: Array<Record<string, string>>): boolean {
  const allowed: string[] = localBackupColumnsForTable(table);
  for (let i = 0; i < rows.length; i++) {
    const keys: string[] = Object.keys(rows[i]);
    for (let k = 0; k < keys.length; k++) {
      if (allowed.indexOf(keys[k]) < 0 && !isDistributedSystemColumn(keys[k])) { return false; }
    }
  }
  return true;
}

/** Strips distributed ResultSet helper columns before local validation/restore. */
export function normalizeLocalBackupRows(table: string,
  rows: Array<Record<string, string>>): Array<Record<string, string>> {
  const allowed: string[] = localBackupColumnsForTable(table);
  const normalized: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = {};
    for (let k = 0; k < allowed.length; k++) {
      const key: string = allowed[k];
      if (rows[i][key] !== undefined) { row[key] = rows[i][key]; }
    }
    normalized.push(row);
  }
  return normalized;
}

function legacyLocalBackupColumns(table: string): string[] {
  const columns: string[] = localBackupColumnsForTable(table);
  if (table !== 'remotehosts') { return columns; }
  const legacy: string[] = [];
  for (let i = 0; i < columns.length; i++) {
    if (columns[i] !== 'rustdeskauthmode') { legacy.push(columns[i]); }
  }
  return legacy;
}

export function localBackupCanonicalPayload(
  createdAt: number, appVersion: string, tables: Record<string, Array<Record<string, string>>>,
  extensions?: Array<Record<string, string>>, version: number = LOCAL_BACKUP_VERSION
): string {
  const ordered: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    ordered[table] = tables[table] || [];
  }
  const base: Record<string, Object> = {};
  base['format'] = LOCAL_BACKUP_FORMAT;
  base['version'] = version;
  base['createdAt'] = createdAt;
  base['appVersion'] = appVersion;
  base['tables'] = ordered;
  if (version >= 2) { base['extensions'] = extensions || []; }
  return JSON.stringify(base);
}

export function localBackupSha256(text: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(text) });
  const bytes: Uint8Array = md.digestSync().data;
  let hex: string = '';
  for (let i = 0; i < bytes.length; i++) { hex += bytes[i].toString(16).padStart(2, '0'); }
  return hex;
}

export function createLocalBackupDocument(
  tables: Record<string, Array<Record<string, string>>>, createdAt: number, appVersion: string,
  extensions: Array<Record<string, string>> = []
): LocalBackupDocument {
  const payload: string = localBackupCanonicalPayload(createdAt, appVersion, tables, extensions);
  const parsed = JSON.parse(payload) as Record<string, Object>;
  return {
    format: LOCAL_BACKUP_FORMAT,
    version: LOCAL_BACKUP_VERSION,
    createdAt,
    appVersion,
    tables: parsed['tables'] as Record<string, Array<Record<string, string>>>,
    extensions,
    sha256: localBackupSha256(payload)
  };
}

export function validateLocalBackupDocument(text: string): LocalBackupDocument | null {
  try {
    const document = JSON.parse(text) as LocalBackupDocument;
    if (document.format !== LOCAL_BACKUP_FORMAT ||
      (document.version !== 1 && document.version !== LOCAL_BACKUP_VERSION) || !document.tables ||
      !Number.isFinite(document.createdAt) || typeof document.appVersion !== 'string' ||
      typeof document.sha256 !== 'string') { return null; }
    const names: string[] = Object.keys(document.tables);
    if (names.length !== CLOUD_SYNC_TABLES.length) { return null; }
    for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
      const table: string = CLOUD_SYNC_TABLES[i];
      const rows: Array<Record<string, string>> = document.tables[table];
      if (!Array.isArray(rows) || names.indexOf(table) < 0 ||
        !backupRowsContainOnlyKnownColumns(table, rows)) { return null; }
    }
    const canonical: string = localBackupCanonicalPayload(document.createdAt, document.appVersion,
      document.tables, document.extensions, document.version);
    // Hash the source shape before dropping ResultSet system columns. Existing
    // backups created by older builds legitimately include #_deleted_flag.
    if (localBackupSha256(canonical) !== document.sha256) { return null; }
    const normalizedTables: Record<string, Array<Record<string, string>>> = {};
    for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
      const table: string = CLOUD_SYNC_TABLES[i];
      normalizedTables[table] = normalizeLocalBackupRows(table, document.tables[table]);
      if (!validateLocalBackupRows(table, normalizedTables[table])) { return null; }
    }
    if (document.version === 1 && document.extensions !== undefined) { return null; }
    if (document.version >= 2 && !validateLocalExtensions(document.extensions || [], normalizedTables)) { return null; }
    document.tables = normalizedTables;
    return document;
  } catch (_e) { return null; }
}

/** Validates a pre-parsed snapshot before an RDB transaction begins. */
export function validateLocalBackupSnapshot(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>> = []
): boolean {
  const names: string[] = Object.keys(tables);
  if (names.length !== CLOUD_SYNC_TABLES.length) { return false; }
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    const rows: Array<Record<string, string>> = tables[table];
    if (!Array.isArray(rows) || names.indexOf(table) < 0 ||
      !backupRowsContainOnlyKnownColumns(table, rows) || !validateLocalBackupRows(table, rows)) {
      return false;
    }
  }
  return validateLocalExtensions(extensions, tables);
}

function validateLocalExtensions(rows: Array<Record<string, string>>,
  tables: Record<string, Array<Record<string, string>>>): boolean {
  const allowed: string[] = localBackupLocalExtensionColumns();
  const extensionIds: Set<string> = new Set<string>();
  const extensionBindings: Set<string> = new Set<string>();
  for (let i = 0; i < rows.length; i++) {
    const keys: string[] = Object.keys(rows[i]);
    if ((rows[i]['id'] || '') === '' || (rows[i]['tablename'] || '') === '' ||
      (rows[i]['recordid'] || '') === '' || (rows[i]['payload'] || '') === '') { return false; }
    if (LOCAL_EXTENSION_TABLES.indexOf(rows[i]['tablename']) < 0 ||
      rows[i]['id'] !== rows[i]['tablename'] + ':' + rows[i]['recordid'] ||
      extensionIds.has(rows[i]['id']) ||
      extensionBindings.has(rows[i]['tablename'] + ':' + rows[i]['recordid'])) { return false; }
    for (let k = 0; k < keys.length; k++) {
      if (allowed.indexOf(keys[k]) < 0 || typeof rows[i][keys[k]] !== 'string') { return false; }
    }
    if (rows[i]['updatedat'] !== undefined && !isStrictIntegerText(rows[i]['updatedat'])) { return false; }
    const ownerTable: string = rows[i]['tablename'] === 'rdprestrictedadminsecrets'
      ? 'remotehosts' : rows[i]['tablename'];
    const owners: Array<Record<string, string>> = tables[ownerTable] || [];
    let ownerFound: boolean = false;
    for (let ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
      if (owners[ownerIndex]['id'] === rows[i]['recordid']) { ownerFound = true; break; }
    }
    if (!ownerFound) { return false; }
    try {
      const payload: Object = JSON.parse(rows[i]['payload']) as Object;
      if (!payload || Array.isArray(payload)) { return false; }
      const values: Record<string, string> = payload as Record<string, string>;
      const payloadKeys: string[] = Object.keys(values);
      const payloadColumns: string[] = localExtensionPayloadColumns(rows[i]['tablename']);
      for (let k = 0; k < payloadKeys.length; k++) {
        const key: string = payloadKeys[k];
        if (payloadColumns.indexOf(key) < 0 || typeof values[key] !== 'string') { return false; }
        if ((key === 'formatversion' || key === 'privatekeyencrypted') && !isStrictIntegerText(values[key])) {
          return false;
        }
      }
    } catch (_e) { return false; }
    extensionIds.add(rows[i]['id']);
    extensionBindings.add(rows[i]['tablename'] + ':' + rows[i]['recordid']);
  }
  return true;
}

function localExtensionPayloadColumns(table: string): string[] {
  if (table === 'remotehosts') { return REMOTE_HOST_EXTENSION_PAYLOAD_COLUMNS; }
  if (table === 'rdpcredentials') { return ['username']; }
  if (table === 'sshkeys') { return ['formatversion', 'privatekeyencrypted']; }
  if (table === 'rdprestrictedadminsecrets') { return ['hash', 'binding']; }
  return [];
}

function validateLocalBackupRows(table: string, rows: Array<Record<string, string>>): boolean {
  const allowed: string[] = localBackupColumnsForTable(table);
  const integerColumns: string[] = localBackupIntegerColumns(table);
  const ids: Set<string> = new Set<string>();
  if (allowed.length === 0) { return false; }
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = rows[i];
    if (!row || typeof row !== 'object' || row['id'] === undefined ||
      typeof row['id'] !== 'string' || row['id'].length === 0 || ids.has(row['id'])) { return false; }
    const keys: string[] = Object.keys(row);
    // 备份格式采用向前兼容的行结构：后续版本新增的列可以缺失，
    // 恢复时由 RDB 保留 NULL/默认值；未知列仍然拒绝。这样旧备份不会
    // 因为 RustDesk/证书等后来新增字段而被误判为无效。
    const keySet: string[] = allowed;
    for (let k = 0; k < keys.length; k++) {
      const key: string = keys[k];
      if (keySet.indexOf(key) < 0 || typeof row[key] !== 'string') { return false; }
      if (integerColumns.indexOf(key) >= 0 && !isStrictIntegerText(row[key])) { return false; }
    }
    ids.add(row['id']);
  }
  return true;
}

function isStrictIntegerText(value: string): boolean {
  if (value.length === 0) { return false; }
  let index: number = value.charAt(0) === '-' ? 1 : 0;
  if (index === value.length) { return false; }
  for (; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code < 48 || code > 57) { return false; }
  }
  return true;
}
