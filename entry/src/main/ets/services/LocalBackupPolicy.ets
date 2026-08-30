import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CLOUD_SYNC_TABLES } from './CloudSyncPolicy';
import {
  BackupManifestV3,
  BackupRestorePreview,
  BackupSensitivityMode,
  BackupSectionManifestV3,
  backupManifestV3IsStructurallyValid,
  backupSectionOwners,
  backupSectionSha256,
  backupSectionState,
  backupSectionTombstones,
  PortableBackupData,
  PortableBackupRedactionResult,
  fullPortableBackupData,
  redactPortableBackupData
} from './BackupManifestV3';
import {
  vncRecordFromCloudRow,
  vncRecordIsValid
} from './VncRecordPolicy';
import {
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS,
  MOONLIGHT_SCHEMA_VERSION
} from '../model/MoonlightRecord';
import {
  moonlightBackupRowsAreValid,
  moonlightBackupSourceRowsAreValid,
  MoonlightBackupRestoreResolution,
  resolveMoonlightBackupForRestore
} from './MoonlightBackupPolicy';
import {
  AccountScopeToken,
  AccountSessionLease
} from './AccountScopePolicy';
import { remoteHostEndpointIsDevicePrivateForTransfer } from './LanHostAddressPolicy';

export const LOCAL_BACKUP_FORMAT: string = 'remotedesktop-local-backup';
export const LOCAL_BACKUP_VERSION: number = 3;
export const LOCAL_BACKUP_MAX_BYTES: number = 32 * 1024 * 1024;
const DISTRIBUTED_SYSTEM_COLUMNS: string[] = ['#_deleted_flag'];
const LOCAL_EXTENSION_TABLES: string[] = [
  'remotehosts', 'rdpcredentials', 'sshkeys', 'rdprestrictedadminsecrets'
];
export const LOCAL_BACKUP_PORTABLE_TABLES: string[] =
  CLOUD_SYNC_TABLES.concat([MOONLIGHT_CLOUD_TABLE]);
const LEGACY_LOCAL_BACKUP_LOCAL_TABLES: string[] = ['vnclocalrecords'];
const LOCAL_BACKUP_LOCAL_TABLES: string[] =
  LEGACY_LOCAL_BACKUP_LOCAL_TABLES.concat([MOONLIGHT_LOCAL_TABLE]);

/**
 * Portable backup is a local-store capability, not a cloud-account
 * capability. Both the anonymous device-local store and a Huawei-account
 * store are eligible once the active scope and the opened RDB lease agree.
 * Transitional/blocked scopes remain fail-closed.
 */
export function portableBackupScopeLeaseAllowed(
  scope: AccountScopeToken,
  lease: AccountSessionLease | null
): boolean {
  if (lease === null ||
    (scope.kind !== 'device_local' && scope.kind !== 'huawei_account') ||
    (scope.sessionState !== 'offline' && scope.sessionState !== 'ready' &&
      scope.sessionState !== 'bound')) {
    return false;
  }
  return scope.ownerScopeId.trim() !== '' &&
    scope.storeIdentity.trim() !== '' && scope.generation > 0 &&
    lease.storeInstanceId > 0 &&
    lease.ownerScopeId === scope.ownerScopeId &&
    lease.storeIdentity === scope.storeIdentity &&
    lease.generation === scope.generation;
}
const REMOTE_HOST_EXTENSION_PAYLOAD_COLUMNS: string[] = [
  // `password` is a legacy shadow that migration may still need to recover.
  'password', 'sshkeypassphrase', 'sshproxypassword',
  'sshproxykeypassphrase', 'sshkeyid', 'sshproxytype',
  'sshproxyauthmethod', 'sshproxykeyid', 'sshhostkeyalgorithm',
  'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat',
  'sshhostkeytrustmode', 'sshhostkeyrouteidentity', 'sshjumphostkeyalgorithm',
  'sshjumphostkeyfingerprintsha256', 'sshjumphostkeyrawbase64',
  'sshjumphostkeytrustedat', 'sshjumphostkeytrustmode',
  'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
  'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatenotbeforems',
  'rdpcertificatenotafterms', 'rdpcertificatetrustedat',
  'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot',
  'rdpcertificateallowhostmismatch', 'rdpcertificaterouteidentity',
  'rdpgatewaycertificatefingerprintsha256', 'rdpgatewaycertificatesubject',
  'rdpgatewaycertificateissuer', 'rdpgatewaycertificatecommonname',
  'rdpgatewaycertificatenotbeforems', 'rdpgatewaycertificatenotafterms',
  'rdpgatewaycertificatetrustedat', 'rdpgatewaycertificatetrustmode',
  'rdpgatewaycertificateallowuntrustedroot',
  'rdpgatewaycertificateallowhostmismatch',
  'rdpgatewaycertificaterouteidentity', 'rustdeskrelayid', 'rustdeskaccountid',
  'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled',
  'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'rdpauthmode',
  'rdprestrictedadminsecretsource', 'rdpendpointmode',
  'rdpgatewaytransport', 'rdpgatewayservername', 'rdpclienthostname', 'sourcetype',
  'rustdeskproaccountid',
  'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged',
  'rustdeskprolastseenat', 'rustdeskprosyncerror', 'rustdesktargetdevice',
  'rustdeskadaptiveorientation', 'rustdesktotpentryid',
  'rustdesktotpautosubmit', 'rustdesktotpdeviceid', 'localpersonalizationversion',
  'localdisplayconfig', 'locallastconnected', 'locallasthealth',
  'locallastlatency', 'localrustdeskadaptiveorientation',
  'localrustdeskdesktopflipmode',
  'localrustdeskprolastseenat', 'localrustdeskprosyncerror'
];

const DEVICE_LOCAL_RUSTDESK_PEER_2FA_KEYS: string[] = [
  'rustdesktotpentryid', 'rustdesktotpautosubmit', 'rustdesktotpdeviceid'
];

function isDeviceLocalRustDeskPeerTwoFactorKey(key: string): boolean {
  return DEVICE_LOCAL_RUSTDESK_PEER_2FA_KEYS.indexOf(key.toLowerCase()) >= 0;
}

function scrubDeviceLocalRustDeskPeerTwoFactorDisplayConfig(raw: string): string {
  try {
    const source: Record<string, Object> =
      JSON.parse(raw || '{}') as Record<string, Object>;
    if (!source || Array.isArray(source)) { return raw; }
    const target: Record<string, Object> = {};
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (isDeviceLocalRustDeskPeerTwoFactorKey(key)) { continue; }
      if (key === '_remoteDeskExtensionV1' && source[key] &&
        typeof source[key] === 'object' && !Array.isArray(source[key])) {
        const extension: Record<string, Object> =
          source[key] as Record<string, Object>;
        const scrubbedExtension: Record<string, Object> = {};
        const extensionKeys: string[] = Object.keys(extension);
        for (let k = 0; k < extensionKeys.length; k++) {
          const extensionKey: string = extensionKeys[k];
          if (!isDeviceLocalRustDeskPeerTwoFactorKey(extensionKey)) {
            scrubbedExtension[extensionKey] = extension[extensionKey];
          }
        }
        target[key] = scrubbedExtension as Object;
      } else {
        target[key] = source[key];
      }
    }
    return JSON.stringify(target);
  } catch (_error) {
    return raw;
  }
}

function scrubDeviceLocalRustDeskPeerTwoFactorExport(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>>
): PortableBackupData {
  const safeTables: Record<string, Array<Record<string, string>>> = {};
  const devicePrivateHostIds: Set<string> = new Set<string>();
  const tableNames: string[] = Object.keys(tables);
  for (let i = 0; i < tableNames.length; i++) {
    const table: string = tableNames[i];
    safeTables[table] = [];
    const rows: Array<Record<string, string>> = tables[table] || [];
    for (let r = 0; r < rows.length; r++) {
      if (table === 'remotehosts' && remoteHostEndpointIsDevicePrivateForTransfer(
        rows[r]['protocol'] || '', rows[r]['host'])) {
        if ((rows[r]['id'] || '') !== '') { devicePrivateHostIds.add(rows[r]['id']); }
        continue;
      }
      const next: Record<string, string> = {};
      const keys: string[] = Object.keys(rows[r]);
      for (let k = 0; k < keys.length; k++) {
        const key: string = keys[k];
        if (table === 'remotehosts' && isDeviceLocalRustDeskPeerTwoFactorKey(key)) {
          continue;
        }
        next[key] = table === 'remotehosts' && key === 'displayconfig' ?
          scrubDeviceLocalRustDeskPeerTwoFactorDisplayConfig(rows[r][key]) : rows[r][key];
      }
      safeTables[table].push(next);
    }
  }
  const safeExtensions: Array<Record<string, string>> = [];
  for (let i = 0; i < extensions.length; i++) {
    if (localBackupExtensionOwnerTable(extensions[i]['tablename'] || '') === 'remotehosts' &&
      devicePrivateHostIds.has(extensions[i]['recordid'] || '')) {
      continue;
    }
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(extensions[i]);
    for (let k = 0; k < keys.length; k++) { next[keys[k]] = extensions[i][keys[k]]; }
    if (next['tablename'] === 'remotehosts') {
      try {
        const source: Record<string, string> =
          JSON.parse(next['payload'] || '{}') as Record<string, string>;
        const payload: Record<string, string> = {};
        const payloadKeys: string[] = Object.keys(source);
        for (let k = 0; k < payloadKeys.length; k++) {
          const key: string = payloadKeys[k];
          if (isDeviceLocalRustDeskPeerTwoFactorKey(key)) { continue; }
          payload[key] = key === 'localdisplayconfig' ?
            scrubDeviceLocalRustDeskPeerTwoFactorDisplayConfig(source[key]) : source[key];
        }
        next['payload'] = JSON.stringify(payload);
      } catch (_error) {
        // Validation will reject an already-corrupt extension after export.
      }
    }
    safeExtensions.push(next);
  }
  return { tables: safeTables, extensions: safeExtensions, localTables: {} };
}

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
    return ['id', 'userid', 'label', 'protocol', 'host', 'port', 'username', 'password', 'passward', 'customhostname', 'sshusekey', 'sshkeypath', 'sshkeydata', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject', 'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatenotbeforems', 'rdpcertificatenotafterms', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'rdpcertificaterouteidentity', 'rdpgatewaycertificatefingerprintsha256', 'rdpgatewaycertificatesubject', 'rdpgatewaycertificateissuer', 'rdpgatewaycertificatecommonname', 'rdpgatewaycertificatenotbeforems', 'rdpgatewaycertificatenotafterms', 'rdpgatewaycertificatetrustedat', 'rdpgatewaycertificatetrustmode', 'rdpgatewaycertificateallowuntrustedroot', 'rdpgatewaycertificateallowhostmismatch', 'rdpgatewaycertificaterouteidentity', 'proxyhost', 'proxyport', 'proxyusername', 'gatewayhost', 'gatewayport', 'displayconfig', 'locked', 'locktype', 'isfavorite', 'groupid', 'sortorder', 'icon', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskrelayid', 'rustdeskaccountid', 'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled', 'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'sourcetype', 'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror', 'createdat', 'updatedat'];
  }
  if (table === 'rdpcredentials') {
    return ['id', 'userid', 'label', 'username', 'password',
      'createdat', 'updatedat'];
  }
  if (table === 'rustdeskrelays') { return ['id', 'userid', 'idserver', 'idserverport', 'relayserver', 'relayport', 'apiserver', 'apiusername', 'apipassword', 'key', 'healthstatus', 'healthlatency', 'healthcheckedat', 'apiloginstatus', 'accountsjson', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['id', 'userid', 'label', 'keytype', 'publickey', 'privatekey', 'fingerprint', 'comment', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['id', 'userid', 'issuer', 'account', 'displayname', 'secret', 'algorithm', 'digits', 'period', 'iconurl', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'vncrecordv2') {
    return ['id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext', 'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256', 'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'];
  }
  if (table === MOONLIGHT_CLOUD_TABLE) {
    return MOONLIGHT_RECORD_COLUMNS.slice();
  }
  return [];
}

export function localBackupLocalExtensionColumns(): string[] {
  return ['id', 'tablename', 'recordid', 'payload', 'updatedat'];
}

/** Resolve the durable owner row for a device-local extension. */
export function localBackupExtensionOwnerTable(table: string): string {
  return table === 'rdprestrictedadminsecrets' ? 'remotehosts' : table;
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
  if (table === MOONLIGHT_LOCAL_TABLE) {
    return MOONLIGHT_LOCAL_RECORD_COLUMNS.slice();
  }
  return [];
}

function localBackupIntegerColumns(table: string): string[] {
  if (table === 'usersettings') { return ['schemaversion', 'updatedat']; }
  if (table === 'remotehosts') { return ['port', 'sshusekey', 'sshhostkeytrustedat', 'sshhostkeytrustmode', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch', 'rdpgatewaycertificatetrustedat', 'rdpgatewaycertificatetrustmode', 'rdpgatewaycertificateallowuntrustedroot', 'rdpgatewaycertificateallowhostmismatch', 'proxyport', 'gatewayport', 'locked', 'locktype', 'isfavorite', 'sortorder', 'lastconnected', 'lasthealth', 'lastlatency', 'syncversion', 'rustdeskpasswordmode', 'rustdeskdirectenabled', 'rustdeskdirectport', 'rustdeskpromanaged', 'rustdeskprolastseenat', 'createdat', 'updatedat']; }
  if (table === 'rdpcredentials') { return ['createdat', 'updatedat']; }
  if (table === 'rustdeskrelays') { return ['idserverport', 'relayport', 'healthlatency', 'healthcheckedat', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'sshkeys') { return ['keytype', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat', 'formatversion', 'privatekeyencrypted']; }
  if (table === 'totpentries') { return ['algorithm', 'digits', 'period', 'locked', 'locktype', 'syncversion', 'createdat', 'updatedat']; }
  if (table === 'vncrecordv2') { return ['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat']; }
  if (table === MOONLIGHT_CLOUD_TABLE) {
    return ['envelopeversion', 'cryptoversion', 'keyversion',
      'aadversion', 'syncversion', 'schemaversion', 'resetepoch',
      'createdat', 'updatedat', 'deletedat'];
  }
  return [];
}

function localBackupLocalTableIntegerColumns(table: string): string[] {
  if (table === 'vnclocalrecords') {
    return ['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion',
      'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat', 'localonly'];
  }
  if (table === MOONLIGHT_LOCAL_TABLE) {
    return ['envelopeversion', 'cryptoversion', 'keyversion',
      'aadversion', 'syncversion', 'schemaversion', 'resetepoch',
      'createdat', 'updatedat', 'deletedat', 'localonly'];
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
    ? LOCAL_BACKUP_PORTABLE_TABLES : tableInventory;
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

function hasActiveVncTrustRows(data: PortableBackupData): boolean {
  const tables: Array<Array<Record<string, string>>> = [
    data.tables['vncrecordv2'] || [],
    data.localTables['vnclocalrecords'] || []
  ];
  for (let t = 0; t < tables.length; t++) {
    for (let r = 0; r < tables[t].length; r++) {
      if (tables[t][r]['recordtype'] === 'trust' &&
        Number(tables[t][r]['deletedat'] || '0') <= 0) {
        return true;
      }
    }
  }
  return false;
}

function hasActiveMoonlightTrustRows(data: PortableBackupData): boolean {
  const tables: Array<Array<Record<string, string>>> = [
    data.tables[MOONLIGHT_CLOUD_TABLE] || [],
    data.localTables[MOONLIGHT_LOCAL_TABLE] || []
  ];
  for (let t = 0; t < tables.length; t++) {
    for (let r = 0; r < tables[t].length; r++) {
      if (tables[t][r]['recordtype'] === 'trust' &&
        Number(tables[t][r]['deletedat'] || '0') <= 0) {
        return true;
      }
    }
  }
  return false;
}

function createBackupManifestV3(
  data: PortableBackupRedactionResult, createdAt: number,
  appVersion: string, accountScope: string, rdbSchemaVersion: number,
  sourceCryptoConfigured: boolean,
  sensitivityMode: BackupSensitivityMode = 'redacted'
): BackupManifestV3 {
  const sections: BackupSectionManifestV3[] = [];
  const tableNames: string[] = Object.keys(data.tables);
  for (let i = 0; i < LOCAL_BACKUP_PORTABLE_TABLES.length; i++) {
    const table: string = LOCAL_BACKUP_PORTABLE_TABLES[i];
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
      mode: sensitivityMode,
      sourceCryptoConfigured,
      sourceEnvelopeVersion: 3,
      // Full backups from an encrypted source carry cryptoparams so the same
      // master password can unlock the ciphertext on the target device.
      verifierIncluded: sensitivityMode === 'full' && sourceCryptoConfigured
    },
    trust: {
      deviceTrustIncluded: true,
      vncTrustCandidatesIncluded: sensitivityMode === 'full' && hasActiveVncTrustRows(data),
      // The confirmation marker is stored only in device-local Preferences;
      // it is never present in either localTables or the cloud table.
      vncLocalConfirmationMarkerIncluded: false,
      plaintextConsentIncluded:
        sensitivityMode === 'full' && !sourceCryptoConfigured,
      loginTokensIncluded: sensitivityMode === 'full'
    },
    moonlight: {
      schemaVersion: MOONLIGHT_SCHEMA_VERSION,
      settingsHostsProfilesIncluded: true,
      trustCandidatesIncluded:
        sensitivityMode === 'full' &&
        hasActiveMoonlightTrustRows(data),
      // Pairing identity is device-bound and omitted even from an explicit
      // full backup. Restore therefore always requires re-pairing.
      clientIdentityIncluded: false,
      clientIdentityOmitted: true,
      restoreLocalOnly: true
    }
  };
}

export function localBackupSha256(text: string): string {
  // Keep the public hash helper total on platform builds that reject a
  // zero-length DataBlob in Md.updateSync. Non-empty backup behavior is
  // unchanged; this is the standard SHA-256 digest of empty input.
  if (text.length === 0) {
    return 'e3b0c44298fc1c149afbf4c8996fb924' +
      '27ae41e4649b934ca495991b7852b855';
  }
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
  sourceCryptoConfigured: boolean = false,
  sensitivityMode: BackupSensitivityMode = 'redacted'
): LocalBackupDocument {
  if ((tables[MOONLIGHT_CLOUD_TABLE] !== undefined &&
    !moonlightBackupSourceRowsAreValid(
      tables[MOONLIGHT_CLOUD_TABLE], accountScope, false)) ||
    (localTables[MOONLIGHT_LOCAL_TABLE] !== undefined &&
      !moonlightBackupSourceRowsAreValid(
        localTables[MOONLIGHT_LOCAL_TABLE], accountScope, true))) {
    throw new Error(
      'portable backup contains invalid Moonlight source rows');
  }
  const scrubbed: PortableBackupData =
    scrubDeviceLocalRustDeskPeerTwoFactorExport(tables, extensions);
  const portable: PortableBackupRedactionResult =
    sensitivityMode === 'full'
      ? fullPortableBackupData(scrubbed.tables, scrubbed.extensions, localTables)
      : redactPortableBackupData(scrubbed.tables, scrubbed.extensions, localTables);
  const manifest: BackupManifestV3 = createBackupManifestV3(
    portable, createdAt, appVersion, accountScope,
    rdbSchemaVersion, sourceCryptoConfigured, sensitivityMode);
  const payload: string = localBackupCanonicalPayload(
    createdAt, appVersion, portable.tables, portable.extensions,
    LOCAL_BACKUP_VERSION, portable.localTables, manifest);
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
      typeof document.sha256 !== 'string') {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=shape');
      return null;
    }
    const names: string[] = Object.keys(document.tables);
    const inventory: string[] = [];
    const allowedTables: string[] = document.version >= 3
      ? LOCAL_BACKUP_PORTABLE_TABLES : CLOUD_SYNC_TABLES;
    for (let i = 0; i < allowedTables.length; i++) {
      const table: string = allowedTables[i];
      if (names.indexOf(table) >= 0) { inventory.push(table); }
    }
    if (inventory.length !== names.length) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'validate stage=inventory names=' + names.join(','));
      return null;
    }
    for (let i = 0; i < inventory.length; i++) {
      const table: string = inventory[i];
      const rows: Array<Record<string, string>> =
        document.tables[table];
      if (!Array.isArray(rows) ||
        !backupRowsContainOnlyKnownColumns(table, rows)) {
        hilog.error(0x0001, 'LocalBackupPolicy',
          'validate stage=columns table=' + table);
        return null;
      }
    }
    if (document.version === 1 && document.extensions !== undefined) {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=v1-extensions');
      return null;
    }
    if (document.version >= 3 &&
      !validateBackupManifestV3(document, inventory)) {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=manifest');
      return null;
    }
    const canonical: string = localBackupCanonicalPayload(
      document.createdAt, document.appVersion,
      document.tables, document.extensions, document.version,
      document.localTables, document.manifest, inventory);
    // Hash the source shape before dropping ResultSet system columns. Existing
    // backups created by older builds legitimately include #_deleted_flag.
    if (localBackupSha256(canonical) !== document.sha256) {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=hash');
      return null;
    }
    const normalizedTables: Record<string, Array<Record<string, string>>> = {};
    for (let i = 0; i < inventory.length; i++) {
      const table: string = inventory[i];
      normalizedTables[table] = normalizeLocalBackupRows(table, document.tables[table]);
      if (!validateLocalBackupRows(table, normalizedTables[table])) {
        hilog.error(0x0001, 'LocalBackupPolicy',
          'validate stage=rows table=' + table);
        return null;
      }
    }
    if (document.version >= 2 && !validateLocalExtensions(
      document.extensions || [], normalizedTables)) {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=extensions');
      return null;
    }
    if (document.localTables !== undefined &&
      !validateLocalTables(document.localTables, true)) {
      hilog.error(0x0001, 'LocalBackupPolicy', 'validate stage=localTables');
      return null;
    }
    if (document.version >= 3 &&
      document.manifest?.crypto.mode === 'full'
        ? !validateFullV3Rows(document, normalizedTables)
        : !validateRedactedV3Rows(document, normalizedTables)) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'validate stage=v3rows mode=' +
        (document.manifest?.crypto.mode || 'redacted'));
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
    !backupManifestV3IsStructurallyValid(manifest)) {
    hilog.error(0x0001, 'LocalBackupPolicy', 'manifest stage=structural mode=' +
      (manifest === undefined ? 'none' : (manifest.crypto ? manifest.crypto.mode : 'no-crypto')));
    return false;
  }
  const hasMoonlightDescriptor: boolean =
    manifest.moonlight !== undefined;
  const manifestCloudTables: string[] = hasMoonlightDescriptor
    ? LOCAL_BACKUP_PORTABLE_TABLES : CLOUD_SYNC_TABLES;
  const manifestLocalTables: string[] = hasMoonlightDescriptor
    ? LOCAL_BACKUP_LOCAL_TABLES : LEGACY_LOCAL_BACKUP_LOCAL_TABLES;
  const documentLocalTables:
    Record<string, Array<Record<string, string>>> =
    document.localTables === undefined ?
      {} as Record<string, Array<Record<string, string>>> :
      document.localTables;
  if (!hasMoonlightDescriptor &&
    (inventory.indexOf(MOONLIGHT_CLOUD_TABLE) >= 0 ||
      Object.keys(documentLocalTables)
        .indexOf(MOONLIGHT_LOCAL_TABLE) >= 0)) {
    return false;
  }
  if (
    manifest.sourceAppVersion !== document.appVersion ||
    manifest.createdAt !== document.createdAt ||
    manifest.restoreMode !== 'merge' ||
    manifest.sections.length !==
      manifestCloudTables.length + manifestLocalTables.length + 1) {
    hilog.error(0x0001, 'LocalBackupPolicy', 'manifest stage=meta sections=' +
      manifest.sections.length.toString() + ' app=' + manifest.sourceAppVersion +
      ' vs ' + document.appVersion + ' createdAt=' +
      manifest.createdAt.toString() + ' vs ' + document.createdAt.toString());
    return false;
  }
  for (let i = 0; i < manifestCloudTables.length; i++) {
    const table: string = manifestCloudTables[i];
    const section: BackupSectionManifestV3 | null =
      manifestSection(manifest, 'cloud:' + table);
    const present: boolean = inventory.indexOf(table) >= 0;
    if (section === null || section.kind !== 'cloud_table' ||
      section.table !== table ||
      !sectionMatchesRows(
        section, present, present ? document.tables[table] : [],
        localBackupColumnsForTable(table))) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'manifest stage=section table=' + table +
        ' state=' + (section === null ? 'missing' : section.state) +
        ' rows=' + (present ? (document.tables[table] || []).length.toString() : 'absent'));
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
    hilog.error(0x0001, 'LocalBackupPolicy', 'manifest stage=extensionSection');
    return false;
  }
  const localTables: Record<string, Array<Record<string, string>>> =
    document.localTables || {};
  const localNames: string[] = Object.keys(localTables);
  for (let i = 0; i < manifestLocalTables.length; i++) {
    const table: string = manifestLocalTables[i];
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
  if (hasMoonlightDescriptor) {
    const moonlightData: PortableBackupData = {
      tables: document.tables,
      extensions,
      localTables
    };
    const expectedTrustCandidates: boolean =
      manifest.crypto.mode === 'full' &&
      hasActiveMoonlightTrustRows(moonlightData);
    if (manifest.moonlight?.trustCandidatesIncluded !==
      expectedTrustCandidates) {
      return false;
    }
  }
  // Redacted configs never carry crypto parameters. Full backups chosen by
  // the user may carry cryptoparams (empty when the source is unencrypted,
  // rows when encrypted so the same master password can unlock on restore).
  return manifest.crypto.mode === 'redacted'
    ? manifestSection(manifest, 'cloud:cryptoparams')?.state === 'absent'
    : true;
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

function rowsCanonicalJson(
  rows: Array<Record<string, string>>
): string {
  const canonical: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = {};
    const keys: string[] = Object.keys(rows[i]).sort();
    for (let k = 0; k < keys.length; k++) {
      row[keys[k]] = rows[i][keys[k]];
    }
    canonical.push(row);
  }
  return JSON.stringify(canonical);
}

function portableDataCanonicalJson(
  data: PortableBackupData
): string {
  const tables: Record<string, string> = {};
  const tableNames: string[] = Object.keys(data.tables).sort();
  for (let i = 0; i < tableNames.length; i++) {
    tables[tableNames[i]] = rowsCanonicalJson(data.tables[tableNames[i]]);
  }
  const localNames: string[] = Object.keys(data.localTables).sort();
  const locals: Record<string, string> = {};
  for (let i = 0; i < localNames.length; i++) {
    locals[localNames[i]] = rowsCanonicalJson(data.localTables[localNames[i]]);
  }
  return JSON.stringify({
    tables,
    extensions: rowsCanonicalJson(data.extensions),
    localTables: locals
  });
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
  // Compare with key-order-insensitive canonical JSON: exporters may build
  // rows (e.g. redacted user settings) in a different key order than the
  // normalized inventory without changing the data.
  if (portableDataCanonicalJson(redacted) !==
      portableDataCanonicalJson({
        tables: normalizedTables,
        extensions: document.extensions || [],
        localTables: document.localTables || {}
      })) {
    hilog.error(0x0001, 'LocalBackupPolicy',
      'redacted canonical equality failed');
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
  if (normalizedTables['vncrecordv2'] !== undefined &&
    !validateVncBackupRows(normalizedTables['vncrecordv2'], owner)) {
    return false;
  }
  if (normalizedTables[MOONLIGHT_CLOUD_TABLE] !== undefined &&
    !moonlightBackupRowsAreValid(
      normalizedTables[MOONLIGHT_CLOUD_TABLE], owner,
      'redacted', false)) {
    return false;
  }
  const localVnc: Array<Record<string, string>> =
    (document.localTables || {})['vnclocalrecords'] || [];
  if (!validateVncBackupRows(localVnc, owner)) { return false; }
  const localMoonlight: Array<Record<string, string>> =
    (document.localTables || {})[MOONLIGHT_LOCAL_TABLE] || [];
  return moonlightBackupRowsAreValid(
    localMoonlight, owner, 'redacted', true);
}

/**
 * Full-backup validation: rows must keep the exact owner and known columns
 * (already enforced by backupRowsContainOnlyKnownColumns/normalize), VNC rows
 * may include secret rows and trust candidate metadata, and cryptoparams rows
 * are expected when the source was encrypted. The device-local confirmation
 * marker is not a row and is never accepted from a backup. There is
 * deliberately no redaction-equality check.
 */
function validateFullV3Rows(
  document: LocalBackupDocument,
  normalizedTables: Record<string, Array<Record<string, string>>>
): boolean {
  const manifest: BackupManifestV3 = document.manifest as BackupManifestV3;
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
  const vncRows: Array<Record<string, string>> =
    normalizedTables['vncrecordv2'] || [];
  for (let i = 0; i < vncRows.length; i++) {
    if ((vncRows[i]['userid'] || '') !== owner ||
      Number(vncRows[i]['deletedat'] || '0') > 0) {
      return false;
    }
  }
  const localVnc: Array<Record<string, string>> =
    (document.localTables || {})['vnclocalrecords'] || [];
  for (let i = 0; i < localVnc.length; i++) {
    if ((localVnc[i]['userid'] || '') !== owner ||
      Number(localVnc[i]['deletedat'] || '0') > 0) {
      return false;
    }
  }
  if (normalizedTables[MOONLIGHT_CLOUD_TABLE] !== undefined &&
    !moonlightBackupRowsAreValid(
      normalizedTables[MOONLIGHT_CLOUD_TABLE], owner,
      'full', false)) {
    return false;
  }
  const localMoonlight: Array<Record<string, string>> =
    (document.localTables || {})[MOONLIGHT_LOCAL_TABLE] || [];
  if (!moonlightBackupRowsAreValid(
    localMoonlight, owner, 'full', true)) {
    return false;
  }
  if (manifest.crypto.sourceCryptoConfigured &&
    (normalizedTables['cryptoparams'] === undefined ||
      normalizedTables['cryptoparams'].length === 0)) {
    return false;
  }
  return true;
}

export interface PortableBackupRestorePlan extends PortableBackupData {
  sourceFormatVersion: number;
  sourceAccountScope: string;
  targetAccountScope: string;
  legacyOwnerAdopted: boolean;
  restoreMode: 'merge';
  sensitivityMode: BackupSensitivityMode;
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
    'rustdeskrelays', 'sshkeys', 'totpentries', 'vncrecordv2',
    'vnclocalrecords', MOONLIGHT_CLOUD_TABLE, MOONLIGHT_LOCAL_TABLE
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
    if ((table === 'vncrecordv2' || table === 'vnclocalrecords') &&
      row['ownertype'] === 'account') {
      row['ownerid'] = targetOwner;
    }
    if ((table === MOONLIGHT_CLOUD_TABLE ||
      table === MOONLIGHT_LOCAL_TABLE) &&
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

/**
 * Full-backup VNC filter: keeps secret rows and trust candidate metadata
 * (ciphertext or plaintext by the user's explicit choice) and only drops
 * tombstoned rows. Owner rebinding happens before this filter, so rows already
 * carry the target owner. Device-local confirmation markers are not rows.
 */
function validFullVncRows(
  rows: Array<Record<string, string>>, owner: string
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = rows[i];
    if ((row['userid'] || '') === owner &&
      Number(row['deletedat'] || '0') <= 0) {
      result.push(row);
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
  for (let i = 0; i < LOCAL_BACKUP_PORTABLE_TABLES.length; i++) {
    const table: string = LOCAL_BACKUP_PORTABLE_TABLES[i];
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
    secretsIncluded: document.manifest?.crypto.mode === 'full',
    deviceTrustIncluded:
      document.manifest?.trust.deviceTrustIncluded === true,
    vncTrustCandidatesIncluded:
      document.manifest?.trust.vncTrustCandidatesIncluded === true,
    // A valid document can never transport this marker. Keep the preview
    // explicit so callers cannot accidentally imply that restore re-trusts.
    vncLocalConfirmationMarkerIncluded: false,
    moonlightIncluded: document.manifest?.moonlight !== undefined,
    moonlightTrustCandidatesIncluded:
      document.manifest?.moonlight?.trustCandidatesIncluded === true,
    moonlightClientIdentityIncluded: false,
    moonlightRepairPairingRequired:
      document.manifest?.moonlight !== undefined
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
  const sensitivityMode: BackupSensitivityMode =
    document.version >= 3 &&
      document.manifest?.crypto.mode === 'full'
      ? 'full' : 'redacted';
  if ((legacy && !allowLegacyOwnerAdoption) ||
    (!legacy && sourceOwner !== owner)) {
    return null;
  }
  const portable: PortableBackupRedactionResult =
    sensitivityMode === 'full'
      ? fullPortableBackupData(
          document.tables, document.extensions || [],
          document.localTables || {})
      : redactPortableBackupData(
          document.tables, document.extensions || [],
          document.localTables || {});
  const tables: Record<string, Array<Record<string, string>>> = {};
  const sourcePresentTables: string[] = Object.keys(portable.tables);
  const presentTables: string[] = [];
  let quarantinedRows: number = portable.excludedRows;
  const devicePrivateHostIds: Set<string> = new Set<string>();
  for (let i = 0; i < sourcePresentTables.length; i++) {
    const table: string = sourcePresentTables[i];
    if (table === MOONLIGHT_CLOUD_TABLE) { continue; }
    const sourceRows: Array<Record<string, string>> = portable.tables[table];
    const transferableRows: Array<Record<string, string>> = [];
    for (let rowIndex: number = 0; rowIndex < sourceRows.length; rowIndex++) {
      if (table === 'remotehosts' && remoteHostEndpointIsDevicePrivateForTransfer(
        sourceRows[rowIndex]['protocol'] || '', sourceRows[rowIndex]['host'])) {
        if ((sourceRows[rowIndex]['id'] || '') !== '') {
          devicePrivateHostIds.add(sourceRows[rowIndex]['id']);
        }
        quarantinedRows++;
        continue;
      }
      transferableRows.push(sourceRows[rowIndex]);
    }
    const rebound: Array<Record<string, string>> =
      reboundRows(table, transferableRows, owner);
    if (table === 'vncrecordv2') {
      const valid: Array<Record<string, string>> =
        sensitivityMode === 'full'
          ? validFullVncRows(rebound, owner)
          : validPortableVncRows(rebound, owner);
      quarantinedRows += rebound.length - valid.length;
      tables[table] = valid;
    } else {
      tables[table] = rebound;
    }
    presentTables.push(table);
  }
  const localTables: Record<string, Array<Record<string, string>>> = {};
  const sourcePresentLocalTables: string[] =
    Object.keys(portable.localTables);
  const presentLocalTables: string[] = [];
  for (let i = 0; i < sourcePresentLocalTables.length; i++) {
    const table: string = sourcePresentLocalTables[i];
    if (table === MOONLIGHT_LOCAL_TABLE) { continue; }
    const rebound: Array<Record<string, string>> =
      reboundRows(table, portable.localTables[table], owner);
    if (table === 'vnclocalrecords') {
      const valid: Array<Record<string, string>> =
        sensitivityMode === 'full'
          ? validFullVncRows(rebound, owner)
          : validPortableVncRows(rebound, owner);
      quarantinedRows += rebound.length - valid.length;
      localTables[table] = valid;
    } else {
      localTables[table] = rebound;
    }
    presentLocalTables.push(table);
  }
  const moonlightPresent: boolean =
    document.manifest?.moonlight !== undefined &&
    (sourcePresentTables.indexOf(MOONLIGHT_CLOUD_TABLE) >= 0 ||
      sourcePresentLocalTables.indexOf(MOONLIGHT_LOCAL_TABLE) >= 0);
  if (moonlightPresent) {
    const moonlight: MoonlightBackupRestoreResolution =
      resolveMoonlightBackupForRestore(
        portable.tables[MOONLIGHT_CLOUD_TABLE] || [],
        portable.localTables[MOONLIGHT_LOCAL_TABLE] || [],
        owner, sensitivityMode);
    localTables[MOONLIGHT_LOCAL_TABLE] = moonlight.rows;
    presentLocalTables.push(MOONLIGHT_LOCAL_TABLE);
    quarantinedRows += moonlight.quarantinedRows;
  }
  const extensions: Array<Record<string, string>> = [];
  for (let i = 0; i < portable.extensions.length; i++) {
    const extension: Record<string, string> = portable.extensions[i];
    if (localBackupExtensionOwnerTable(extension['tablename'] || '') === 'remotehosts' &&
      devicePrivateHostIds.has(extension['recordid'] || '')) {
      quarantinedRows++;
      continue;
    }
    extensions.push(extension);
  }
  return {
    sourceFormatVersion: document.version,
    sourceAccountScope: sourceOwner,
    targetAccountScope: owner,
    legacyOwnerAdopted: legacy,
    restoreMode: 'merge',
    sensitivityMode,
    tables,
    extensions,
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
  return validateSnapshotTables(tables, CLOUD_SYNC_TABLES) &&
    validateLocalExtensions(extensions, tables) &&
    (localTables === undefined ||
      validateCompleteSnapshotLocalTables(localTables));
}

/**
 * A persisted cloud-download before-image is not a portable backup. Current
 * builds capture the optional Moonlight physical table as well as the eight
 * long-lived cloud tables, while an in-flight checkpoint written by an older
 * build contains only those original eight. Both inventories are valid during
 * an upgrade; every other partial/superset shape fails closed.
 */
export function validateCloudDownloadRollbackSnapshot(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>> = [],
  localTables?: Record<string, Array<Record<string, string>>>
): boolean {
  const names: string[] = Object.keys(tables);
  const inventory: string[] = names.length ===
    LOCAL_BACKUP_PORTABLE_TABLES.length
    ? LOCAL_BACKUP_PORTABLE_TABLES : CLOUD_SYNC_TABLES;
  if (!validateSnapshotTables(tables, inventory) ||
    !validateLocalExtensions(extensions, tables)) {
    return false;
  }
  return localTables === undefined ||
    validateCompleteSnapshotLocalTables(localTables);
}

function validateSnapshotTables(
  tables: Record<string, Array<Record<string, string>>>,
  inventory: string[]
): boolean {
  const names: string[] = Object.keys(tables);
  if (names.length !== inventory.length) { return false; }
  for (let i = 0; i < inventory.length; i++) {
    const table: string = inventory[i];
    const rows: Array<Record<string, string>> = tables[table];
    if (!Array.isArray(rows) || names.indexOf(table) < 0 ||
      !backupRowsContainOnlyKnownColumns(table, rows) || !validateLocalBackupRows(table, rows)) {
      return false;
    }
  }
  return true;
}

function exactInventory(
  names: string[], expected: string[]
): boolean {
  if (names.length !== expected.length) { return false; }
  for (let i = 0; i < expected.length; i++) {
    if (names.indexOf(expected[i]) < 0) { return false; }
  }
  return true;
}

function validateCompleteSnapshotLocalTables(
  localTables: Record<string, Array<Record<string, string>>>
): boolean {
  const names: string[] = Object.keys(localTables);
  // A durable rollback image written before Moonlight existed legitimately
  // contains only vnclocalrecords. Do not reject that checkpoint after an app
  // upgrade, and do not accept arbitrary partial combinations either.
  if (!exactInventory(names, LEGACY_LOCAL_BACKUP_LOCAL_TABLES) &&
    !exactInventory(names, LOCAL_BACKUP_LOCAL_TABLES)) {
    return false;
  }
  return validateLocalTables(localTables, true);
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
      (rows[i]['recordid'] || '') === '' || (rows[i]['payload'] || '') === '') {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'extension invalid identity index=' + i.toString());
      return false;
    }
    if (LOCAL_EXTENSION_TABLES.indexOf(rows[i]['tablename']) < 0 ||
      rows[i]['id'] !== rows[i]['tablename'] + ':' + rows[i]['recordid'] ||
      extensionIds.has(rows[i]['id']) ||
      extensionBindings.has(rows[i]['tablename'] + ':' + rows[i]['recordid'])) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'extension invalid binding id=' + rows[i]['id'] +
        ' table=' + rows[i]['tablename']);
      return false;
    }
    for (let k = 0; k < keys.length; k++) {
      if (allowed.indexOf(keys[k]) < 0 || typeof rows[i][keys[k]] !== 'string') {
        hilog.error(0x0001, 'LocalBackupPolicy',
          'extension invalid column id=' + rows[i]['id'] + ' key=' + keys[k]);
        return false;
      }
    }
    if (rows[i]['updatedat'] !== undefined && !isStrictIntegerText(rows[i]['updatedat'])) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'extension invalid updatedat id=' + rows[i]['id']);
      return false;
    }
    const ownerTable: string =
      localBackupExtensionOwnerTable(rows[i]['tablename']);
    const owners: Array<Record<string, string>> = tables[ownerTable] || [];
    let ownerFound: boolean = false;
    for (let ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
      if (owners[ownerIndex]['id'] === rows[i]['recordid']) { ownerFound = true; break; }
    }
    if (!ownerFound &&
      Object.keys(tables).indexOf(ownerTable) >= 0) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'extension orphan id=' + rows[i]['id'] + ' ownerTable=' + ownerTable);
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
        if (payloadColumns.indexOf(key) < 0 || typeof values[key] !== 'string') {
          hilog.error(0x0001, 'LocalBackupPolicy',
            'extension invalid payload id=' + rows[i]['id'] + ' key=' + key);
          return false;
        }
        if ((key === 'formatversion' || key === 'privatekeyencrypted') &&
          values[key] !== '' && !isStrictIntegerText(values[key])) {
          hilog.error(0x0001, 'LocalBackupPolicy',
            'extension invalid integer payload id=' + rows[i]['id'] + ' key=' + key);
          return false;
        }
      }
    } catch (_e) {
      hilog.error(0x0001, 'LocalBackupPolicy',
        'extension invalid json id=' + rows[i]['id']);
      return false;
    }
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
