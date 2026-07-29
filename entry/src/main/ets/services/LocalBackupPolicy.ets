import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CLOUD_SYNC_TABLES } from './CloudSyncPolicy';
import {
  BackupManifestV3,
  BackupRestorePreview,
  BackupSectionManifestV3,
  backupManifestV3IsStructurallyValid,
  backupSectionOwners,
  backupSectionSha256,
  backupSectionState,
  backupSectionTombstones,
  PortableBackupData,
  PortableBackupRedactionResult,
  redactPortableBackupData
} from './BackupManifestV3';
import {
  vncRecordFromCloudRow,
  vncRecordIsValid
} from './VncRecordPolicy';

export const LOCAL_BACKUP_FORMAT: string = 'remotedesktop-local-backup';
export const LOCAL_BACKUP_VERSION: number = 3;
export const LOCAL_BACKUP_MAX_BYTES: number = 32 * 1024 * 1024;
const DISTRIBUTED_SYSTEM_COLUMNS: string[] = ['#_deleted_flag'];
const LOCAL_EXTENSION_TABLES: string[] = [
  'remotehosts', 'rdpcredentials', 'sshkeys', 'rdprestrictedadminsecrets'
];
const LOCAL_BACKUP_LOCAL_TABLES: string[] = ['vnclocalrecords'];
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
  'rustdeskprolastseenat', 'rustdeskprosyncerror', 'rustdesktargetdevice',
  'rustdeskadaptiveorientation', 'rustdesktotpentryid',
  'rustdesktotpautosubmit'
];

export interface LocalBackupDocument {
  format: string;
  version: number;
  createdAt: number;
  appVersion: string;
  tables: Record<string, Array<Record<string, string>>>;
  extensions?: Array<Record<string, string>>;
  localTables?: Record<string, Array<Record<string, string>>>;
  manifest?: BackupManifestV3;
  sha256: string;
}

export function localBackupColumnsForTable(table: string): string[] {
  if (table === 'cryptoparams') { return ['id', 'key', 'value']; }
  if (table === 'usersettings') { return ['id', 'userid', 'key', 'value', 'payload', 'schemaversion', 'updatedat']; }
  if (table === 'remotehosts') {
    return ['id', 'userid', 'label', 'protocol', 'host', 'port', 'username', 'password', 'passward', 'customhostname', 'sshusekey', 'sshkeypath', 'sshkeydata', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject', 'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'proxyhost', 'proxyport', 'proxyusername', 'gatewayhost', 'gatewayport', 'displayconfig', 'locked', 'locktype', 'isfavorite', 'groupid', 'sortorder', 'icon', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskrelayid', 'rustdeskaccountid', 'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled', 'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'sourcetype', 'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror', 'createdat', 'updatedat'];
  }
  if (table === 'rdpcredentials') {
    return ['id', 'userid', 'label', 'username', 'password',
      'createdat', 'updatedat'];
  }
  if (table === 'rustdeskrelays') { return ['id', 'userid', 'idserver', 'idserverport', 'relayserver', 'relayport', 'apiserver', 'apiusername', 'apipassword', 'key', 'healthstatus', 'healthlatency', 'healthcheckedat', 'apiloginstatus', 'accountsjson', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['id', 'userid', 'label', 'keytype', 'publickey', 'privatekey', 'fingerprint', 'comment', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['id', 'userid', 'issuer', 'account', 'secret', 'algorithm', 'digits', 'period', 'iconurl', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'vncrecord') {
    return ['id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext', 'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256', 'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'];
  }
  return [];
}

export function localBackupLocalExtensionColumns(): string[] {
  return ['id', 'tablename', 'recordid', 'payload', 'updatedat'];
}

export function localBackupLocalTableNames(): string[] {
  return LOCAL_BACKUP_LOCAL_TABLES.slice();
}

export function localBackupLocalTableColumns(table: string): string[] {
  if (table === 'vnclocalrecords') {
    return ['id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
      'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
      'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat', 'localonly'];
  }
  return [];
}

function localBackupIntegerColumns(table: string): string[] {
  if (table === 'usersettings') { return ['schemaversion', 'updatedat']; }
  if (table === 'remotehosts') { return ['port', 'sshusekey', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'proxyport', 'gatewayport', 'locked', 'locktype', 'isfavorite', 'sortorder', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskpasswordmode', 'rustdeskdirectenabled', 'rustdeskdirectport', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'createdat', 'updatedat']; }
  if (table === 'rdpcredentials') { return ['createdat', 'updatedat']; }
  if (table === 'rustdeskrelays') { return ['idserverport', 'relayport', 'healthlatency', 'healthcheckedat', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['keytype', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['algorithm', 'digits', 'period', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'vncrecord') { return ['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat']; }
  return [];
}

function localBackupLocalTableIntegerColumns(table: string): string[] {
  if (table === 'vnclocalrecords') {
    return ['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion',
      'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat', 'localonly'];
  }
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

export function localBackupCanonicalPayload(
  createdAt: number, appVersion: string, tables: Record<string, Array<Record<string, string>>>,
  extensions?: Array<Record<string, string>>, version: number = LOCAL_BACKUP_VERSION,
  localTables?: Record<string, Array<Record<string, string>>>,
  manifest?: BackupManifestV3,
  tableInventory?: string[]
): string {
  const ordered: Record<string, Array<Record<string, string>>> = {};
  const inventory: string[] = tableInventory === undefined
    ? CLOUD_SYNC_TABLES : tableInventory;
  const presentNames: string[] = Object.keys(tables);
  for (let i = 0; i < inventory.length; i++) {
    const table: string = inventory[i];
    if (version < 3 || presentNames.indexOf(table) >= 0) {
      ordered[table] = tables[table] || [];
    }
  }
  const base: Record<string, Object> = {};
  base['format'] = LOCAL_BACKUP_FORMAT;
  base['version'] = version;
  base['createdAt'] = createdAt;
  base['appVersion'] = appVersion;
  if (version >= 3) { base['manifest'] = manifest as Object; }
  base['tables'] = ordered;
  if (version >= 2) { base['extensions'] = extensions || []; }
  if (localTables !== undefined) {
    const orderedLocal: Record<string, Array<Record<string, string>>> = {};
    const presentLocalNames: string[] = Object.keys(localTables);
    for (let i = 0; i < LOCAL_BACKUP_LOCAL_TABLES.length; i++) {
      const table: string = LOCAL_BACKUP_LOCAL_TABLES[i];
      if (version < 3 || presentLocalNames.indexOf(table) >= 0) {
        orderedLocal[table] = localTables[table] || [];
      }
    }
    base['localTables'] = orderedLocal;
  }
  return JSON.stringify(base);
}

function sectionManifest(
  id: string, kind: 'cloud_table' | 'local_extensions' |
    'local_table',
  table: string, present: boolean,
  rows: Array<Record<string, string>>, columns: string[]
): BackupSectionManifestV3 {
  return {
    id,
    kind,
    table,
    state: backupSectionState(present, rows.length),
    columns: columns.slice(),
    rowCount: rows.length,
    ownerCount: backupSectionOwners(rows),
    tombstoneCount: backupSectionTombstones(rows),
    sha256: backupSectionSha256(rows)
  };
}

function createBackupManifestV3(
  data: PortableBackupRedactionResult, createdAt: number,
  appVersion: string, accountScope: string, rdbSchemaVersion: number,
  sourceCryptoConfigured: boolean
): BackupManifestV3 {
  const sections: BackupSectionManifestV3[] = [];
  const tableNames: string[] = Object.keys(data.tables);
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    const present: boolean = tableNames.indexOf(table) >= 0;
    sections.push(sectionManifest(
      'cloud:' + table, 'cloud_table', table, present,
      present ? data.tables[table] : [],
      localBackupColumnsForTable(table)));
  }
  sections.push(sectionManifest(
    'local:extensions', 'local_extensions', 'localextensions',
    true, data.extensions, localBackupLocalExtensionColumns()));
  const localNames: string[] = Object.keys(data.localTables);
  for (let i = 0; i < LOCAL_BACKUP_LOCAL_TABLES.length; i++) {
    const table: string = LOCAL_BACKUP_LOCAL_TABLES[i];
    const present: boolean = localNames.indexOf(table) >= 0;
    sections.push(sectionManifest(
      'local:' + table, 'local_table', table, present,
      present ? data.localTables[table] : [],
      localBackupLocalTableColumns(table)));
  }
  return {
    formatVersion: LOCAL_BACKUP_VERSION,
    rdbSchemaVersion: Math.max(1, Math.floor(rdbSchemaVersion)),
    sourceAppVersion: appVersion,
    accountScope,
    createdAt,
    restoreMode: 'merge',
    sections,
    crypto: {
      mode: 'redacted',
      sourceCryptoConfigured,
      sourceEnvelopeVersion: 3,
      verifierIncluded: false
    },
    trust: {
      deviceTrustIncluded: false,
      plaintextConsentIncluded: false,
      loginTokensIncluded: false
    }
  };
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
  extensions: Array<Record<string, string>> = [],
  localTables: Record<string, Array<Record<string, string>>> = {},
  accountScope: string = 'legacy-unbound',
  rdbSchemaVersion: number = 3,
  sourceCryptoConfigured: boolean = false
): LocalBackupDocument {
  const redacted: PortableBackupRedactionResult =
    redactPortableBackupData(tables, extensions, localTables);
  const manifest: BackupManifestV3 = createBackupManifestV3(
    redacted, createdAt, appVersion, accountScope,
    rdbSchemaVersion, sourceCryptoConfigured);
  const payload: string = localBackupCanonicalPayload(
    createdAt, appVersion, redacted.tables, redacted.extensions,
    LOCAL_BACKUP_VERSION, redacted.localTables, manifest);
  const parsed = JSON.parse(payload) as Record<string, Object>;
  return {
    format: LOCAL_BACKUP_FORMAT,
    version: LOCAL_BACKUP_VERSION,
    createdAt,
    appVersion,
    tables: parsed['tables'] as
      Record<string, Array<Record<string, string>>>,
    extensions: parsed['extensions'] as
      Array<Record<string, string>>,
    localTables: parsed['localTables'] as
      Record<string, Array<Record<string, string>>>,
    manifest,
    sha256: localBackupSha256(payload)
  };
}

export function validateLocalBackupDocument(text: string): LocalBackupDocument | null {
  try {
    const document = JSON.parse(text) as LocalBackupDocument;
    if (document.format !== LOCAL_BACKUP_FORMAT ||
      (document.version !== 1 && document.version !== 2 &&
        document.version !== LOCAL_BACKUP_VERSION) || !document.tables ||
      !Number.isFinite(document.createdAt) || typeof document.appVersion !== 'string' ||
      typeof document.sha256 !== 'string') { return null; }
    const names: string[] = Object.keys(document.tables);
    const inventory: string[] = [];
    for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
      const table: string = CLOUD_SYNC_TABLES[i];
      if (names.indexOf(table) >= 0) { inventory.push(table); }
    }
    if (inventory.length !== names.length) { return null; }
    for (let i = 0; i < inventory.length; i++) {
      const table: string = inventory[i];
      const rows: Array<Record<string, string>> =
        document.tables[table];
      if (!Array.isArray(rows) ||
        !backupRowsContainOnlyKnownColumns(table, rows)) {
        return null;
      }
    }
    if (document.version === 1 && document.extensions !== undefined) {
      return null;
    }
    if (document.version >= 3 &&
      !validateBackupManifestV3(document, inventory)) {
      return null;
    }
    const canonical: string = localBackupCanonicalPayload(
      document.createdAt, document.appVersion,
      document.tables, document.extensions, document.version,
      document.localTables, document.manifest, inventory);
    // Hash the source shape before dropping ResultSet system columns. Existing
    // backups created by older builds legitimately include #_deleted_flag.
    if (localBackupSha256(canonical) !== document.sha256) { return null; }
    const normalizedTables: Record<string, Array<Record<string, string>>> = {};
    for (let i = 0; i < inventory.length; i++) {
      const table: string = inventory[i];
      normalizedTables[table] = normalizeLocalBackupRows(table, document.tables[table]);
      if (!validateLocalBackupRows(table, normalizedTables[table])) { return null; }
    }
    if (document.version >= 2 && !validateLocalExtensions(
      document.extensions || [], normalizedTables)) {
      return null;
    }
    if (document.localTables !== undefined &&
      !validateLocalTables(document.localTables, true)) {
      return null;
    }
    if (document.version >= 3 &&
      !validateRedactedV3Rows(
        document, normalizedTables)) {
      return null;
    }
    document.tables = normalizedTables;
    return document;
  } catch (_e) { return null; }
}

function manifestSection(
  manifest: BackupManifestV3, id: string
): BackupSectionManifestV3 | null {
  for (let i = 0; i < manifest.sections.length; i++) {
    if (manifest.sections[i].id === id) { return manifest.sections[i]; }
  }
  return null;
}

function sectionMatchesRows(
  section: BackupSectionManifestV3,
  present: boolean, rows: Array<Record<string, string>>,
  columns: string[]
): boolean {
  if (section.state !== backupSectionState(present, rows.length) ||
    section.rowCount !== rows.length ||
    section.ownerCount !== backupSectionOwners(rows) ||
    section.tombstoneCount !== backupSectionTombstones(rows) ||
    section.sha256 !== backupSectionSha256(rows) ||
    JSON.stringify(section.columns) !== JSON.stringify(columns)) {
    return false;
  }
  return true;
}

function validateBackupManifestV3(
  document: LocalBackupDocument, inventory: string[]
): boolean {
  const manifest: BackupManifestV3 | undefined = document.manifest;
  if (manifest === undefined ||
    !backupManifestV3IsStructurallyValid(manifest) ||
    manifest.sourceAppVersion !== document.appVersion ||
    manifest.createdAt !== document.createdAt ||
    manifest.restoreMode !== 'merge' ||
    manifest.sections.length !==
      CLOUD_SYNC_TABLES.length + LOCAL_BACKUP_LOCAL_TABLES.length + 1) {
    return false;
  }
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    const section: BackupSectionManifestV3 | null =
      manifestSection(manifest, 'cloud:' + table);
    const present: boolean = inventory.indexOf(table) >= 0;
    if (section === null || section.kind !== 'cloud_table' ||
      section.table !== table ||
      !sectionMatchesRows(
        section, present, present ? document.tables[table] : [],
        localBackupColumnsForTable(table))) {
      return false;
    }
  }
  const extensions: Array<Record<string, string>> =
    document.extensions || [];
  const extensionSection: BackupSectionManifestV3 | null =
    manifestSection(manifest, 'local:extensions');
  if (extensionSection === null ||
    extensionSection.kind !== 'local_extensions' ||
    extensionSection.table !== 'localextensions' ||
    !sectionMatchesRows(
      extensionSection, true, extensions,
      localBackupLocalExtensionColumns())) {
    return false;
  }
  const localTables: Record<string, Array<Record<string, string>>> =
    document.localTables || {};
  const localNames: string[] = Object.keys(localTables);
  for (let i = 0; i < LOCAL_BACKUP_LOCAL_TABLES.length; i++) {
    const table: string = LOCAL_BACKUP_LOCAL_TABLES[i];
    const present: boolean = localNames.indexOf(table) >= 0;
    const section: BackupSectionManifestV3 | null =
      manifestSection(manifest, 'local:' + table);
    if (section === null || section.kind !== 'local_table' ||
      section.table !== table ||
      !sectionMatchesRows(
        section, present, present ? localTables[table] : [],
        localBackupLocalTableColumns(table))) {
      return false;
    }
  }
  return manifestSection(manifest, 'cloud:cryptoparams')?.state ===
    'absent';
}

function rowsUseOnlyOwner(
  rows: Array<Record<string, string>>, owner: string
): boolean {
  for (let i = 0; i < rows.length; i++) {
    if ((rows[i]['userid'] || '') !== owner) { return false; }
  }
  return true;
}

function validateVncBackupRows(
  rows: Array<Record<string, string>>, owner: string
): boolean {
  for (let i = 0; i < rows.length; i++) {
    if ((rows[i]['userid'] || '') !== owner ||
      rows[i]['recordtype'] === 'secret' ||
      rows[i]['recordtype'] === 'trust' ||
      Number(rows[i]['deletedat'] || '0') > 0 ||
      !vncRecordIsValid(vncRecordFromCloudRow(rows[i]))) {
      return false;
    }
  }
  return true;
}

function validateRedactedV3Rows(
  document: LocalBackupDocument,
  normalizedTables: Record<string, Array<Record<string, string>>>
): boolean {
  const manifest: BackupManifestV3 = document.manifest as BackupManifestV3;
  const redacted: PortableBackupRedactionResult =
    redactPortableBackupData(
      normalizedTables, document.extensions || [],
      document.localTables || {});
  if (JSON.stringify(redacted.tables) !==
      JSON.stringify(normalizedTables) ||
    JSON.stringify(redacted.extensions) !==
      JSON.stringify(document.extensions || []) ||
    JSON.stringify(redacted.localTables) !==
      JSON.stringify(document.localTables || {})) {
    return false;
  }
  const owner: string = manifest.accountScope;
  const ownerTables: string[] = [
    'usersettings', 'remotehosts', 'rdpcredentials',
    'rustdeskrelays', 'sshkeys', 'totpentries'
  ];
  for (let i = 0; i < ownerTables.length; i++) {
    const table: string = ownerTables[i];
    if (normalizedTables[table] !== undefined &&
      !rowsUseOnlyOwner(normalizedTables[table], owner)) {
      return false;
    }
  }
  if (normalizedTables['vncrecord'] !== undefined &&
    !validateVncBackupRows(normalizedTables['vncrecord'], owner)) {
    return false;
  }
  const localVnc: Array<Record<string, string>> =
    (document.localTables || {})['vnclocalrecords'] || [];
  return validateVncBackupRows(localVnc, owner);
}

export interface PortableBackupRestorePlan extends PortableBackupData {
  sourceFormatVersion: number;
  sourceAccountScope: string;
  targetAccountScope: string;
  legacyOwnerAdopted: boolean;
  restoreMode: 'merge';
  presentTables: string[];
  presentLocalTables: string[];
  extensionsPresent: boolean;
  quarantinedRows: number;
}

function reboundRows(
  table: string, rows: Array<Record<string, string>>,
  targetOwner: string
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  const ownerTables: string[] = [
    'usersettings', 'remotehosts', 'rdpcredentials',
    'rustdeskrelays', 'sshkeys', 'totpentries', 'vncrecord',
    'vnclocalrecords'
  ];
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = {};
    const keys: string[] = Object.keys(rows[i]);
    for (let k = 0; k < keys.length; k++) {
      row[keys[k]] = rows[i][keys[k]];
    }
    if (ownerTables.indexOf(table) >= 0) {
      row['userid'] = targetOwner;
    }
    if ((table === 'vncrecord' || table === 'vnclocalrecords') &&
      row['ownertype'] === 'account') {
      row['ownerid'] = targetOwner;
    }
    result.push(row);
  }
  return result;
}

function validPortableVncRows(
  rows: Array<Record<string, string>>, owner: string
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    if (validateVncBackupRows([rows[i]], owner)) {
      result.push(rows[i]);
    }
  }
  return result;
}

export function createLocalBackupRestorePreview(
  document: LocalBackupDocument
): BackupRestorePreview {
  const presentTables: string[] = Object.keys(document.tables);
  const absentTables: string[] = [];
  let rowCount: number = 0;
  let tombstoneCount: number = 0;
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    if (presentTables.indexOf(table) < 0) {
      absentTables.push(table);
      continue;
    }
    const rows: Array<Record<string, string>> =
      document.tables[table] || [];
    rowCount += rows.length;
    tombstoneCount += backupSectionTombstones(rows);
  }
  return {
    formatVersion: document.version,
    sourceAppVersion: document.appVersion,
    sourceAccountScope: document.manifest?.accountScope || '',
    legacyOwnerUnbound: document.version < 3,
    restoreMode: 'merge',
    presentTables,
    absentTables,
    rowCount,
    tombstoneCount,
    secretsIncluded: false,
    deviceTrustIncluded: false
  };
}

/**
 * Convert v1/v2/v3 input to one current redacted merge plan. Legacy owner
 * adoption is explicit because old formats had no trustworthy account scope.
 */
export function adaptLocalBackupDocumentForRestore(
  document: LocalBackupDocument, targetOwner: string,
  allowLegacyOwnerAdoption: boolean
): PortableBackupRestorePlan | null {
  const owner: string = targetOwner.trim();
  if (owner === '') { return null; }
  const sourceOwner: string = document.manifest?.accountScope || '';
  const legacy: boolean = document.version < 3;
  if ((legacy && !allowLegacyOwnerAdoption) ||
    (!legacy && sourceOwner !== owner)) {
    return null;
  }
  const redacted: PortableBackupRedactionResult =
    redactPortableBackupData(
      document.tables, document.extensions || [],
      document.localTables || {});
  const tables: Record<string, Array<Record<string, string>>> = {};
  const presentTables: string[] = Object.keys(redacted.tables);
  let quarantinedRows: number = redacted.excludedRows;
  for (let i = 0; i < presentTables.length; i++) {
    const table: string = presentTables[i];
    const rebound: Array<Record<string, string>> =
      reboundRows(table, redacted.tables[table], owner);
    if (table === 'vncrecord') {
      const valid: Array<Record<string, string>> =
        validPortableVncRows(rebound, owner);
      quarantinedRows += rebound.length - valid.length;
      tables[table] = valid;
    } else {
      tables[table] = rebound;
    }
  }
  const localTables: Record<string, Array<Record<string, string>>> = {};
  const presentLocalTables: string[] =
    Object.keys(redacted.localTables);
  for (let i = 0; i < presentLocalTables.length; i++) {
    const table: string = presentLocalTables[i];
    const rebound: Array<Record<string, string>> =
      reboundRows(table, redacted.localTables[table], owner);
    if (table === 'vnclocalrecords') {
      const valid: Array<Record<string, string>> =
        validPortableVncRows(rebound, owner);
      quarantinedRows += rebound.length - valid.length;
      localTables[table] = valid;
    } else {
      localTables[table] = rebound;
    }
  }
  return {
    sourceFormatVersion: document.version,
    sourceAccountScope: sourceOwner,
    targetAccountScope: owner,
    legacyOwnerAdopted: legacy,
    restoreMode: 'merge',
    tables,
    extensions: redacted.extensions,
    localTables,
    presentTables,
    presentLocalTables,
    extensionsPresent: document.version >= 2 &&
      document.extensions !== undefined,
    quarantinedRows
  };
}

/** Validates a pre-parsed snapshot before an RDB transaction begins. */
export function validateLocalBackupSnapshot(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>> = [],
  localTables?: Record<string, Array<Record<string, string>>>
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
  return validateLocalExtensions(extensions, tables) &&
    (localTables === undefined || validateLocalTables(localTables));
}

function validateLocalTables(
  localTables: Record<string, Array<Record<string, string>>>,
  allowPartial: boolean = false
): boolean {
  const names: string[] = Object.keys(localTables);
  if (!allowPartial &&
    names.length !== LOCAL_BACKUP_LOCAL_TABLES.length) {
    return false;
  }
  for (let i = 0; i < names.length; i++) {
    if (LOCAL_BACKUP_LOCAL_TABLES.indexOf(names[i]) < 0) {
      return false;
    }
  }
  for (let i = 0; i < LOCAL_BACKUP_LOCAL_TABLES.length; i++) {
    const table: string = LOCAL_BACKUP_LOCAL_TABLES[i];
    if (allowPartial && names.indexOf(table) < 0) { continue; }
    const rows: Array<Record<string, string>> = localTables[table];
    if (!Array.isArray(rows) || names.indexOf(table) < 0) { return false; }
    const allowed: string[] = localBackupLocalTableColumns(table);
    const integerColumns: string[] = localBackupLocalTableIntegerColumns(table);
    const ids: Set<string> = new Set<string>();
    for (let r = 0; r < rows.length; r++) {
      const row: Record<string, string> = rows[r];
      if (!row || typeof row !== 'object' || typeof row['id'] !== 'string' ||
        row['id'] === '' || ids.has(row['id'])) { return false; }
      const keys: string[] = Object.keys(row);
      for (let k = 0; k < keys.length; k++) {
        const key: string = keys[k];
        if (allowed.indexOf(key) < 0 || typeof row[key] !== 'string') { return false; }
        if (integerColumns.indexOf(key) >= 0 && !isStrictIntegerText(row[key])) { return false; }
      }
      ids.add(row['id']);
    }
  }
  return true;
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
    if (!ownerFound &&
      Object.keys(tables).indexOf(ownerTable) >= 0) {
      return false;
    }
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
  if (table === 'vnclocalrecords') {
    return ['userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
      'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
      'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'];
  }
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
