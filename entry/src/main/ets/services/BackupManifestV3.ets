import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  cloudUserSettingIsSyncable
} from './CloudSyncSettingsPolicy';
import {
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_SCHEMA_VERSION
} from '../model/MoonlightRecord';
import {
  filterMoonlightBackupRows,
  MoonlightBackupFilterResult
} from './MoonlightBackupPolicy';

export type BackupSectionKind = 'cloud_table' | 'local_extensions' |
  'local_table';
export type BackupSectionState = 'absent' | 'empty' | 'rows';
export type BackupRestoreMode = 'merge' | 'replace_selected';
/**
 * redacted: portable config only (no passwords/private keys/2FA/tokens).
 * full: complete backup chosen by the user; existing protocol secrets are kept as stored
 * (ciphertext when the source has crypto, plaintext otherwise by the user's
 * explicit choice), public device trust is kept as data. VNC trust rows are
 * candidates/metadata only; the device-local confirmation marker is never
 * portable. Moonlight client identity remains device-bound and is omitted in
 * both modes; only its trust candidates are added by full mode.
 */
export type BackupSensitivityMode = 'redacted' | 'full';

export interface BackupSectionManifestV3 {
  id: string;
  kind: BackupSectionKind;
  table: string;
  state: BackupSectionState;
  columns: string[];
  rowCount: number;
  ownerCount: number;
  tombstoneCount: number;
  sha256: string;
}

export interface BackupCryptoDescriptorV3 {
  mode: BackupSensitivityMode;
  sourceCryptoConfigured: boolean;
  sourceEnvelopeVersion: number;
  verifierIncluded: boolean;
}

export interface BackupTrustDescriptorV3 {
  deviceTrustIncluded: boolean;
  /** VNC trust rows may be carried as candidates in an explicit full backup. */
  vncTrustCandidatesIncluded?: boolean;
  /** Must always be false: this marker lives only in device Preferences. */
  vncLocalConfirmationMarkerIncluded?: boolean;
  plaintextConsentIncluded: boolean;
  loginTokensIncluded: boolean;
}

export interface BackupMoonlightDescriptorV3 {
  schemaVersion: number;
  settingsHostsProfilesIncluded: boolean;
  trustCandidatesIncluded: boolean;
  clientIdentityIncluded: boolean;
  clientIdentityOmitted: boolean;
  restoreLocalOnly: boolean;
}

export interface BackupManifestV3 {
  formatVersion: number;
  rdbSchemaVersion: number;
  sourceAppVersion: string;
  accountScope: string;
  createdAt: number;
  restoreMode: BackupRestoreMode;
  sections: BackupSectionManifestV3[];
  crypto: BackupCryptoDescriptorV3;
  trust: BackupTrustDescriptorV3;
  /** Optional so V3 artifacts created before Moonlight remain readable. */
  moonlight?: BackupMoonlightDescriptorV3;
}

export interface PortableBackupData {
  tables: Record<string, Array<Record<string, string>>>;
  extensions: Array<Record<string, string>>;
  localTables: Record<string, Array<Record<string, string>>>;
}

export interface PortableBackupRedactionResult extends PortableBackupData {
  removedSecretFields: number;
  removedDeviceTrustFields: number;
  excludedRows: number;
}

export interface BackupRestorePreview {
  formatVersion: number;
  sourceAppVersion: string;
  sourceAccountScope: string;
  legacyOwnerUnbound: boolean;
  restoreMode: BackupRestoreMode;
  presentTables: string[];
  absentTables: string[];
  rowCount: number;
  tombstoneCount: number;
  secretsIncluded: boolean;
  deviceTrustIncluded: boolean;
  vncTrustCandidatesIncluded: boolean;
  vncLocalConfirmationMarkerIncluded: boolean;
  moonlightIncluded: boolean;
  moonlightTrustCandidatesIncluded: boolean;
  moonlightClientIdentityIncluded: boolean;
  moonlightRepairPairingRequired: boolean;
}

const SECRET_COLUMNS: Record<string, string[]> = {
  'remotehosts': [
    'password', 'passward', 'sshkeydata', 'sshkeypassphrase'
  ],
  'rdpcredentials': ['password'],
  'rustdeskrelays': ['apipassword', 'key', 'accountsjson'],
  'sshkeys': ['privatekey'],
  'totpentries': ['secret']
};

// Device trust columns (SSH host public keys, RDP certificates) are retained
// in every backup mode; they are public data, not secrets. VNC trust rows are
// intentionally different: redacted backups omit them, while full backups
// carry only candidate metadata and never the local confirmation marker.

const REMOTE_HOST_EXTENSION_TRUST: string[] = [
  'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256',
  'sshhostkeyrawbase64', 'sshhostkeytrustedat', 'sshhostkeytrustmode',
  'sshjumphostkeyalgorithm', 'sshjumphostkeyfingerprintsha256',
  'sshjumphostkeyrawbase64', 'sshjumphostkeytrustedat', 'sshjumphostkeytrustmode',
  'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
  'rdpcertificateissuer', 'rdpcertificatecommonname',
  'rdpcertificatenotbeforems', 'rdpcertificatenotafterms',
  'rdpcertificatetrustedat', 'rdpcertificatetrustmode',
  'rdpcertificateallowuntrustedroot',
  'rdpcertificateallowhostmismatch', 'rdpcertificaterouteidentity',
  'rdpgatewaycertificatefingerprintsha256',
  'rdpgatewaycertificatesubject', 'rdpgatewaycertificateissuer',
  'rdpgatewaycertificatecommonname', 'rdpgatewaycertificatenotbeforems',
  'rdpgatewaycertificatenotafterms', 'rdpgatewaycertificatetrustedat',
  'rdpgatewaycertificatetrustmode',
  'rdpgatewaycertificateallowuntrustedroot',
  'rdpgatewaycertificateallowhostmismatch',
  'rdpgatewaycertificaterouteidentity'
];

const REMOTE_HOST_EXTENSION_SAFE: string[] = [
  'sshkeyid', 'rustdeskrelayid', 'rustdeskaccountid',
  'rustdeskpasswordmode', 'rustdeskauthmode',
  'rustdeskdirectenabled', 'rustdeskdirecthost',
  'rustdeskdirectport', 'sshproxytype', 'rdpcredentialid',
  'sshproxyauthmethod', 'sshproxykeyid',
  'rdpauthmode', 'sourcetype', 'rustdesktargetdevice',
  'rustdeskadaptiveorientation', 'rdpendpointmode',
  'rdpgatewaytransport', 'rdpgatewayservername',
  // Device-local host presentation remains portable only through an explicit
  // local backup. These keys are never projected into a distributed table.
  'localpersonalizationversion', 'localdisplayconfig',
  'locallastconnected', 'locallasthealth', 'locallastlatency',
  'localrustdeskadaptiveorientation', 'localrustdeskdesktopflipmode',
  'localrustdeskprolastseenat',
  'localrustdeskprosyncerror'
];

const DISPLAY_CONFIG_SAFE: string[] = [
  'width', 'height', 'multiMonitor', 'monitorCount',
  'dynamicResolution', 'colorDepth'
];
const REMOTE_HOST_EXTENSION_KEY: string =
  '_remoteDeskExtensionV1';

interface RedactedDisplayConfig {
  value: string;
  removedSecretFields: number;
  removedDeviceTrustFields: number;
}

function copyRowWithout(
  source: Record<string, string>, removed: string[]
): Record<string, string> {
  const next: Record<string, string> = {};
  const keys: string[] = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    if (removed.indexOf(keys[i]) < 0) { next[keys[i]] = source[keys[i]]; }
  }
  return next;
}

function copyRows(
  rows: Array<Record<string, string>>
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    result.push(copyRowWithout(rows[i], []));
  }
  return result;
}

function redactRemoteHostDisplayConfig(
  raw: string
): RedactedDisplayConfig {
  const result: RedactedDisplayConfig = {
    value: '',
    removedSecretFields: 0,
    removedDeviceTrustFields: 0
  };
  try {
    const source: Record<string, Object> =
      JSON.parse(raw || '{}') as Record<string, Object>;
    if (!source || Array.isArray(source)) {
      result.removedSecretFields++;
      return result;
    }
    const safe: Record<string, Object> = {};
    for (let i = 0; i < DISPLAY_CONFIG_SAFE.length; i++) {
      const key: string = DISPLAY_CONFIG_SAFE[i];
      if (source[key] !== undefined) { safe[key] = source[key]; }
    }
    const extension: Record<string, string> =
      source[REMOTE_HOST_EXTENSION_KEY] as
        Record<string, string>;
    if (extension && !Array.isArray(extension)) {
      const safeExtension: Record<string, string> = {};
      const keys: string[] = Object.keys(extension);
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if ((REMOTE_HOST_EXTENSION_SAFE.indexOf(key) >= 0 ||
          REMOTE_HOST_EXTENSION_TRUST.indexOf(key) >= 0) &&
          typeof extension[key] === 'string') {
          safeExtension[key] = extension[key];
        } else {
          result.removedSecretFields++;
        }
      }
      if (Object.keys(safeExtension).length > 0) {
        safe[REMOTE_HOST_EXTENSION_KEY] =
          safeExtension as Object;
      }
    }
    result.value = JSON.stringify(safe);
    return result;
  } catch (_e) {
    result.removedSecretFields++;
    return result;
  }
}

function portableSettingValue(value: Object): boolean {
  return typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean';
}

function redactUserSettingRow(
  source: Record<string, string>
): Record<string, string> | null {
  const row: Record<string, string> = {};
  const baseColumns: string[] = [
    'id', 'userid', 'schemaversion', 'updatedat'
  ];
  for (let i = 0; i < baseColumns.length; i++) {
    const key: string = baseColumns[i];
    if (source[key] !== undefined) { row[key] = source[key]; }
  }
  let hasPortableValue: boolean = false;
  const legacyKey: string = source['key'] || '';
  if (legacyKey !== '' &&
    cloudUserSettingIsSyncable(legacyKey) &&
    source['value'] !== undefined) {
    try {
      const parsed: Object =
        JSON.parse(source['value']) as Object;
      if (portableSettingValue(parsed)) {
        row['key'] = legacyKey;
        row['value'] = source['value'];
        hasPortableValue = true;
      }
    } catch (_e) {}
  }
  if (source['payload'] !== undefined) {
    try {
      const payload: Record<string, Object> =
        JSON.parse(source['payload']) as
          Record<string, Object>;
      if (payload && !Array.isArray(payload)) {
        const safe: Record<string, Object> = {};
        const keys: string[] = Object.keys(payload);
        for (let i = 0; i < keys.length; i++) {
          if (cloudUserSettingIsSyncable(keys[i]) &&
            portableSettingValue(payload[keys[i]])) {
            safe[keys[i]] = payload[keys[i]];
          }
        }
        if (Object.keys(safe).length > 0) {
          row['payload'] = JSON.stringify(safe);
          hasPortableValue = true;
        }
      }
    } catch (_e) {}
  }
  return hasPortableValue ? row : null;
}

function integerText(value: string): number {
  const parsed: number = Number(value);
  return Number.isFinite(parsed) ? Math.floor(parsed) : 0;
}

function vncRowIsPortable(row: Record<string, string>): boolean {
  const recordType: string = row['recordtype'] || '';
  return recordType !== 'secret' && recordType !== 'trust' &&
    integerText(row['deletedat'] || '0') <= 0;
}

function redactVncRows(
  rows: Array<Record<string, string>>
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    if (vncRowIsPortable(rows[i])) { result.push(copyRowWithout(rows[i], [])); }
  }
  return result;
}

function redactExtensionRows(
  rows: Array<Record<string, string>>
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    const table: string = rows[i]['tablename'] || '';
    if (table === 'rdprestrictedadminsecrets') { continue; }
    const next: Record<string, string> = copyRowWithout(rows[i], []);
    if (table === 'remotehosts') {
      try {
        const source: Record<string, string> =
          JSON.parse(next['payload'] || '{}') as Record<string, string>;
      const payload: Record<string, string> = {};
      const keys: string[] = Object.keys(source);
      for (let k = 0; k < keys.length; k++) {
          if ((REMOTE_HOST_EXTENSION_SAFE.indexOf(keys[k]) >= 0 ||
            REMOTE_HOST_EXTENSION_TRUST.indexOf(keys[k]) >= 0) &&
            typeof source[keys[k]] === 'string') {
            payload[keys[k]] = source[keys[k]];
          }
        }
        if (Object.keys(payload).length === 0) { continue; }
        next['payload'] = JSON.stringify(payload);
      } catch (_e) {
        continue;
      }
    }
    result.push(next);
  }
  return result;
}

/**
 * Produce the only currently supported portable payload: account-scoped,
 * redacted configuration. A separate password-protected sensitive format is
 * intentionally not implied by this mode.
 */
export function redactPortableBackupData(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>>,
  localTables: Record<string, Array<Record<string, string>>>
): PortableBackupRedactionResult {
  const redactedTables: Record<string, Array<Record<string, string>>> = {};
  let removedSecretFields: number = 0;
  let removedDeviceTrustFields: number = 0;
  let excludedRows: number = 0;
  const names: string[] = Object.keys(tables);
  for (let i = 0; i < names.length; i++) {
    const table: string = names[i];
    const sourceRows: Array<Record<string, string>> = tables[table] || [];
    if (table === 'cryptoparams') {
      excludedRows += sourceRows.length;
      continue;
    }
    if (table === 'vncrecordv2') {
      const portable: Array<Record<string, string>> =
        redactVncRows(sourceRows);
      excludedRows += sourceRows.length - portable.length;
      redactedTables[table] = portable;
      continue;
    }
    if (table === MOONLIGHT_CLOUD_TABLE) {
      const portable: MoonlightBackupFilterResult =
        filterMoonlightBackupRows(sourceRows, 'redacted', false);
      excludedRows += portable.excludedRows;
      redactedTables[table] = portable.rows;
      continue;
    }
    if (table === 'usersettings') {
      const portable: Array<Record<string, string>> = [];
      for (let r = 0; r < sourceRows.length; r++) {
        const row: Record<string, string> | null =
          redactUserSettingRow(sourceRows[r]);
        if (row === null) {
          excludedRows++;
        } else {
          portable.push(row);
        }
      }
      redactedTables[table] = portable;
      continue;
    }
    const secretColumns: string[] = SECRET_COLUMNS[table] || [];
    // Device trust (SSH host public keys, RDP certificates) is NOT secret and
    // is intentionally retained in every backup mode; only secret columns are
    // removed by the redacted mode. VNC trust rows were handled above and are
    // excluded from this portable configuration mode.
    const removed: string[] = secretColumns;
    const nextRows: Array<Record<string, string>> = [];
    for (let r = 0; r < sourceRows.length; r++) {
      for (let c = 0; c < secretColumns.length; c++) {
        if (sourceRows[r][secretColumns[c]] !== undefined) {
          removedSecretFields++;
        }
      }
      const removedForRow: string[] = table === 'remotehosts'
        ? removed.concat(['displayconfig']) : removed;
      const next: Record<string, string> =
        copyRowWithout(sourceRows[r], removedForRow);
      if (table === 'remotehosts' &&
        sourceRows[r]['displayconfig'] !== undefined) {
        const display: RedactedDisplayConfig =
          redactRemoteHostDisplayConfig(
            sourceRows[r]['displayconfig']);
        removedSecretFields += display.removedSecretFields;
        removedDeviceTrustFields +=
          display.removedDeviceTrustFields;
        if (display.value !== '') {
          next['displayconfig'] = display.value;
        }
      }
      nextRows.push(next);
    }
    redactedTables[table] = nextRows;
  }

  const redactedExtensions: Array<Record<string, string>> =
    redactExtensionRows(extensions);
  excludedRows += extensions.length - redactedExtensions.length;

  const redactedLocal: Record<string, Array<Record<string, string>>> = {};
  const localNames: string[] = Object.keys(localTables);
  for (let i = 0; i < localNames.length; i++) {
    const table: string = localNames[i];
    const sourceRows: Array<Record<string, string>> =
      localTables[table] || [];
    if (table === 'vnclocalrecords') {
      const portable: Array<Record<string, string>> =
        redactVncRows(sourceRows);
      excludedRows += sourceRows.length - portable.length;
      redactedLocal[table] = portable;
    } else if (table === MOONLIGHT_LOCAL_TABLE) {
      const portable: MoonlightBackupFilterResult =
        filterMoonlightBackupRows(sourceRows, 'redacted', true);
      excludedRows += portable.excludedRows;
      redactedLocal[table] = portable.rows;
    } else {
      redactedLocal[table] = copyRows(sourceRows);
    }
  }
  return {
    tables: redactedTables,
    extensions: redactedExtensions,
    localTables: redactedLocal,
    removedSecretFields,
    removedDeviceTrustFields,
    excludedRows
  };
}

/**
 * Complete backup selected explicitly by the user: existing protocol columns (including
 * passwords/private keys/2FA/tokens as stored, device trust, cryptoparams,
 * VNC secret rows and trust candidate metadata) is preserved. The local VNC
 * confirmation marker remains device-only and is never part of this data.
 * Moonlight is stricter: its client identity is omitted even here, while its
 * non-secret settings/host/profile rows and trust candidates are preserved.
 * When the source has crypto configured, the secrets are ciphertext and the backup
 * carries cryptoparams so the same master password can unlock them on the
 * target; otherwise they are plaintext by the user's explicit choice.
 */
export function fullPortableBackupData(
  tables: Record<string, Array<Record<string, string>>>,
  extensions: Array<Record<string, string>>,
  localTables: Record<string, Array<Record<string, string>>>
): PortableBackupRedactionResult {
  const fullTables: Record<string, Array<Record<string, string>>> = {};
  let excludedRows: number = 0;
  const names: string[] = Object.keys(tables);
  for (let i = 0; i < names.length; i++) {
    if (names[i] === MOONLIGHT_CLOUD_TABLE) {
      const portable: MoonlightBackupFilterResult =
        filterMoonlightBackupRows(
          tables[names[i]] || [], 'full', false);
      fullTables[names[i]] = portable.rows;
      excludedRows += portable.excludedRows;
    } else {
      fullTables[names[i]] = copyRows(tables[names[i]] || []);
    }
  }
  const fullExtensions: Array<Record<string, string>> =
    copyRows(extensions);
  const fullLocal: Record<string, Array<Record<string, string>>> = {};
  const localNames: string[] = Object.keys(localTables);
  for (let i = 0; i < localNames.length; i++) {
    if (localNames[i] === MOONLIGHT_LOCAL_TABLE) {
      const portable: MoonlightBackupFilterResult =
        filterMoonlightBackupRows(
          localTables[localNames[i]] || [], 'full', true);
      fullLocal[localNames[i]] = portable.rows;
      excludedRows += portable.excludedRows;
    } else {
      fullLocal[localNames[i]] = copyRows(localTables[localNames[i]] || []);
    }
  }
  return {
    tables: fullTables,
    extensions: fullExtensions,
    localTables: fullLocal,
    removedSecretFields: 0,
    removedDeviceTrustFields: 0,
    excludedRows
  };
}

export function backupSectionSha256(
  rows: Array<Record<string, string>>
): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({
    data: new util.TextEncoder().encode(JSON.stringify(rows))
  });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += bytes[i].toString(16).padStart(2, '0');
  }
  return result;
}

export function backupSectionState(
  present: boolean, rowCount: number
): BackupSectionState {
  if (!present) { return 'absent'; }
  return rowCount === 0 ? 'empty' : 'rows';
}

export function backupSectionOwners(
  rows: Array<Record<string, string>>
): number {
  const owners: Set<string> = new Set<string>();
  for (let i = 0; i < rows.length; i++) {
    const owner: string = rows[i]['userid'] || '';
    if (owner !== '') { owners.add(owner); }
  }
  return owners.size;
}

export function backupSectionTombstones(
  rows: Array<Record<string, string>>
): number {
  let count: number = 0;
  for (let i = 0; i < rows.length; i++) {
    if (integerText(rows[i]['deletedat'] || '0') > 0 ||
      integerText(rows[i]['#_deleted_flag'] || '0') > 0) {
      count++;
    }
  }
  return count;
}

export function backupManifestV3IsStructurallyValid(
  manifest: BackupManifestV3
): boolean {
  const mode: string = manifest && manifest.crypto
    ? manifest.crypto.mode : '';
  const trust: BackupTrustDescriptorV3 | null = manifest && manifest.trust
    ? manifest.trust : null;
  const moonlight: BackupMoonlightDescriptorV3 | undefined =
    manifest ? manifest.moonlight : undefined;
  if (!manifest || manifest.formatVersion !== 3 ||
    !Number.isFinite(manifest.rdbSchemaVersion) ||
    manifest.rdbSchemaVersion < 1 ||
    typeof manifest.sourceAppVersion !== 'string' ||
    manifest.accountScope.trim() === '' ||
    !Number.isFinite(manifest.createdAt) ||
    (manifest.restoreMode !== 'merge' &&
      manifest.restoreMode !== 'replace_selected') ||
    !Array.isArray(manifest.sections) ||
    (mode !== 'redacted' && mode !== 'full') || trust === null ||
    typeof trust.deviceTrustIncluded !== 'boolean' ||
    typeof trust.plaintextConsentIncluded !== 'boolean' ||
    typeof trust.loginTokensIncluded !== 'boolean' ||
    (typeof trust.vncTrustCandidatesIncluded !== 'undefined' &&
      typeof trust.vncTrustCandidatesIncluded !== 'boolean') ||
    trust.vncLocalConfirmationMarkerIncluded === true ||
    (typeof trust.vncLocalConfirmationMarkerIncluded !== 'undefined' &&
      typeof trust.vncLocalConfirmationMarkerIncluded !== 'boolean')) {
    return false;
  }
  if (moonlight !== undefined &&
    (moonlight.schemaVersion !== MOONLIGHT_SCHEMA_VERSION ||
      moonlight.settingsHostsProfilesIncluded !== true ||
      typeof moonlight.trustCandidatesIncluded !== 'boolean' ||
      moonlight.clientIdentityIncluded !== false ||
      moonlight.clientIdentityOmitted !== true ||
      moonlight.restoreLocalOnly !== true ||
      (mode === 'redacted' &&
        moonlight.trustCandidatesIncluded))) {
    return false;
  }
  // Redacted configs must never carry verifier or secret material; full
  // backups may carry the crypto verifier/params (encrypted source) and
  // plaintext consent (unencrypted source) exactly as the user chose.
  if (mode === 'redacted' &&
    (manifest.crypto.verifierIncluded ||
      trust.plaintextConsentIncluded ||
      trust.loginTokensIncluded ||
      trust.vncTrustCandidatesIncluded === true)) {
    return false;
  }
  const ids: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.sections.length; i++) {
    const section: BackupSectionManifestV3 = manifest.sections[i];
    if (!section || section.id.trim() === '' ||
      section.table.trim() === '' || ids.has(section.id) ||
      (section.kind !== 'cloud_table' &&
        section.kind !== 'local_extensions' &&
        section.kind !== 'local_table') ||
      (section.state !== 'absent' && section.state !== 'empty' &&
        section.state !== 'rows') ||
      !Array.isArray(section.columns) ||
      !Number.isFinite(section.rowCount) || section.rowCount < 0 ||
      !Number.isFinite(section.ownerCount) || section.ownerCount < 0 ||
      !Number.isFinite(section.tombstoneCount) ||
      section.tombstoneCount < 0 ||
      !/^[0-9a-f]{64}$/.test(section.sha256)) {
      return false;
    }
    if (section.state === 'absent' && section.rowCount !== 0) {
      return false;
    }
    if (section.state === 'empty' && section.rowCount !== 0) {
      return false;
    }
    if (section.state === 'rows' && section.rowCount === 0) {
      return false;
    }
    ids.add(section.id);
  }
  return true;
}
