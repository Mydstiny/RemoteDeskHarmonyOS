import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { VncRecord, VncRecordType, VncOwnerType, VncSecretKind } from '../model/VncRecord';

export const VNC_CLOUD_TABLE: string = 'vncrecords';
export const VNC_LOCAL_TABLE: string = 'vnclocalrecords';
export const VNC_SCHEMA_VERSION: number = 1;
export const VNC_CRYPTO_VERSION: number = 2;
export const VNC_KEY_VERSION: number = 1;
export const VNC_AAD_VERSION: number = 1;
export const VNC_SECRET_ENVELOPE_VERSION: number = 2;
// Kept only to read legacy scope-retraction rows safely. New selection
// transitions do not write this marker because a single shared cloud row has
// no device owner and must not be retracted by an unselected/locked device.
export const VNC_SCOPE_TOMBSTONE_PAYLOAD: string = '{"__vncScopeTombstone":true}';

export const VNC_RECORD_COLUMNS: string[] = [
  'id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
  'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
  'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'
];

const VNC_RECORD_TYPES: VncRecordType[] = ['settings', 'host', 'gateway', 'secret', 'trust'];
const VNC_OWNER_TYPES: VncOwnerType[] = ['', 'account', 'host', 'gateway'];
const VNC_SECRET_KINDS: VncSecretKind[] = [
  '', 'vnc_password', 'repeater_token', 'gateway_token', 'client_certificate'
];
const VNC_TRANSPORTS: string[] = [
  'direct_tcp', 'ultravnc_repeater', 'websocket_gateway', 'ssh_tunnel'
];
const VNC_SCALING_MODES: string[] = ['fit', 'integer', 'one_to_one', 'pan'];
const VNC_SECURITY_POLICIES: string[] = ['secure_only', 'trusted_network', 'allow_plaintext'];
const VNC_REPEATER_MODES: string[] = ['mode2', 'mode12'];
const FORBIDDEN_SECRET_KEYS: string[] = [
  'password', 'passwd', 'token', 'secret', 'privatekey', 'privateKey', 'ciphertext'
];

export function vncRecordColumns(): string[] {
  return VNC_RECORD_COLUMNS.slice();
}

export function isVncRecordType(value: string): boolean {
  return VNC_RECORD_TYPES.indexOf(value as VncRecordType) >= 0;
}

export function isVncOwnerType(value: string): boolean {
  return VNC_OWNER_TYPES.indexOf(value as VncOwnerType) >= 0;
}

export function isVncSecretKind(value: string): boolean {
  return VNC_SECRET_KINDS.indexOf(value as VncSecretKind) >= 0;
}

export function vncRecordIdentity(userId: string, recordId: string): string {
  return 'vnc|' + userId.trim() + '|' + recordId.trim();
}

export function vncCanonicalJson(values: Record<string, Object>): string {
  const ordered: Record<string, Object> = {};
  const keys: string[] = Object.keys(values).sort();
  for (let i = 0; i < keys.length; i++) { ordered[keys[i]] = values[keys[i]]; }
  return JSON.stringify(ordered);
}

export function vncPayloadHashSha256(payload: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(payload) });
  const digest: Uint8Array = new Uint8Array(md.digestSync().data);
  let result: string = '';
  for (let i = 0; i < digest.length; i++) { result += digest[i].toString(16).padStart(2, '0'); }
  return result;
}

export function vncPayloadObject(payload: string): Record<string, Object> | null {
  try {
    const parsed: Object = JSON.parse(payload) as Object;
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') { return null; }
    return parsed as Record<string, Object>;
  } catch (_e) {
    return null;
  }
}

export function vncSecretPayloadIsMetadataOnly(payload: string): boolean {
  const values: Record<string, Object> | null = vncPayloadObject(payload);
  if (values === null) { return false; }
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const normalized: string = key.toLowerCase();
    for (let j = 0; j < FORBIDDEN_SECRET_KEYS.length; j++) {
      if (normalized === FORBIDDEN_SECRET_KEYS[j].toLowerCase()) { return false; }
    }
  }
  return true;
}

function isFiniteInteger(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value);
}

function isSha256Hex(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

function vncCiphertextEnvelopeLooksValid(value: string): boolean {
  const parts: string[] = value.split(':');
  return parts.length === 4 && parts[0] === VNC_SECRET_ENVELOPE_VERSION.toString() &&
    parts[1].trim() !== '' && parts[2].trim() !== '' && parts[3].trim() !== '';
}

function isNonEmptyString(values: Record<string, Object>, key: string): boolean {
  return typeof values[key] === 'string' && (values[key] as string).trim() !== '';
}

function isStringValue(values: Record<string, Object>, key: string): boolean {
  return typeof values[key] === 'string';
}

function isBooleanValue(values: Record<string, Object>, key: string): boolean {
  return typeof values[key] === 'boolean';
}

function isIntegerInRange(value: Object, minimum: number, maximum: number): boolean {
  if (typeof value !== 'number') { return false; }
  const numeric: number = value as number;
  return Number.isFinite(numeric) && Number.isInteger(numeric) && numeric >= minimum && numeric <= maximum;
}

function isFinitePositiveIntegerValue(value: Object): boolean {
  if (typeof value !== 'number') { return false; }
  const numeric: number = value as number;
  return Number.isFinite(numeric) && Number.isInteger(numeric) && numeric > 0;
}

function isOneOfString(values: Record<string, Object>, key: string, allowed: string[]): boolean {
  return typeof values[key] === 'string' && allowed.indexOf(values[key] as string) >= 0;
}

/**
 * Validate the typed JSON contract inside payload. The row envelope proves
 * integrity and ownership; this second layer prevents a validly hashed but
 * semantically malformed host/gateway/settings/trust row from reaching a
 * runtime service that fills missing fields with unsafe defaults.
 */
export function vncRecordPayloadSemanticallyValid(record: VncRecord): boolean {
  if (record.deletedAt > 0 && record.payload === VNC_SCOPE_TOMBSTONE_PAYLOAD) {
    return true;
  }
  const values: Record<string, Object> | null = vncPayloadObject(record.payload);
  if (values === null) { return false; }
  if (record.recordType === 'secret') {
    if (record.deletedAt > 0) { return Object.keys(values).length === 0; }
    return isStringValue(values, 'kind') && (values['kind'] as string) === record.secretKind &&
      isStringValue(values, 'label');
  }
  if (record.recordType === 'settings') {
    return isOneOfString(values, 'defaultTransport', VNC_TRANSPORTS) &&
      isIntegerInRange(values['defaultPort'], 1, 65535) &&
      isIntegerInRange(values['connectTimeoutMs'], 1000, 120000) &&
      isIntegerInRange(values['authTimeoutMs'], 1000, 120000) &&
      isIntegerInRange(values['firstFrameTimeoutMs'], 1000, 120000) &&
      isBooleanValue(values, 'viewOnly') && isOneOfString(values, 'scalingMode', VNC_SCALING_MODES) &&
      isBooleanValue(values, 'clipboardEnabled') &&
      isOneOfString(values, 'securityPolicy', VNC_SECURITY_POLICIES) &&
      isStringValue(values, 'defaultGatewayId') && isOneOfString(values, 'repeaterMode', VNC_REPEATER_MODES) &&
      isBooleanValue(values, 'syncPreferences') && isBooleanValue(values, 'syncHosts') &&
      isBooleanValue(values, 'syncGateways') && isBooleanValue(values, 'syncSecrets') &&
      isBooleanValue(values, 'syncTrust');
  }
  if (record.recordType === 'host') {
    const transport: string = typeof values['transport'] === 'string' ? values['transport'] as string : '';
    const gatewayId: string = typeof values['gatewayId'] === 'string' ? values['gatewayId'] as string : '';
    const gatewayBindingValid: boolean = transport === 'direct_tcp' ? gatewayId.trim() === '' : gatewayId.trim() !== '';
    return isNonEmptyString(values, 'label') && isNonEmptyString(values, 'host') &&
      isIntegerInRange(values['port'], 1, 65535) && isStringValue(values, 'username') &&
      isStringValue(values, 'gatewayId') && isOneOfString(values, 'transport', VNC_TRANSPORTS) &&
      isOneOfString(values, 'repeaterMode', VNC_REPEATER_MODES) &&
      isBooleanValue(values, 'viewOnly') && isOneOfString(values, 'scalingMode', VNC_SCALING_MODES) &&
      isOneOfString(values, 'securityPolicy', VNC_SECURITY_POLICIES) &&
      isBooleanValue(values, 'tls') && gatewayBindingValid;
  }
  if (record.recordType === 'gateway') {
    const transport: string = typeof values['transport'] === 'string' ? values['transport'] as string : '';
    const path: string = typeof values['path'] === 'string' ? values['path'] as string : '';
    const targetId: string = typeof values['targetId'] === 'string' ? values['targetId'] as string : '';
    const endpointSpecificFieldsValid: boolean =
      (transport !== 'websocket_gateway' || path.trim() !== '') &&
      (transport !== 'ultravnc_repeater' || targetId.trim() !== '');
    return isNonEmptyString(values, 'label') && isOneOfString(values, 'transport', VNC_TRANSPORTS) &&
      isNonEmptyString(values, 'host') && isIntegerInRange(values['port'], 1, 65535) &&
      isStringValue(values, 'path') && isOneOfString(values, 'repeaterMode', VNC_REPEATER_MODES) &&
      isStringValue(values, 'targetId') && isBooleanValue(values, 'tls') &&
      isBooleanValue(values, 'enabled') && endpointSpecificFieldsValid;
  }
  if (record.recordType === 'trust') {
    const fingerprint: string = typeof values['fingerprintSha256'] === 'string' ?
      (values['fingerprintSha256'] as string).trim().toLowerCase() : '';
    return isSha256Hex(fingerprint) && isBooleanValue(values, 'confirmed') &&
      isFinitePositiveIntegerValue(values['confirmedAt']);
  }
  return false;
}

export function vncRecordPayloadHashMatches(record: VncRecord): boolean {
  if (!isSha256Hex(record.payloadHashSha256.trim().toLowerCase())) { return false; }
  try {
    return record.payloadHashSha256.trim().toLowerCase() === vncPayloadHashSha256(record.payload);
  } catch (_e) {
    return false;
  }
}

export function vncRecordIsScopeTombstone(record: VncRecord): boolean {
  return record.deletedAt > 0 && record.payload === VNC_SCOPE_TOMBSTONE_PAYLOAD;
}

export function vncRecordIsValid(record: VncRecord): boolean {
  if (record.id.trim() === '' || record.userId.trim() === '' || !isVncRecordType(record.recordType) ||
    !isVncOwnerType(record.ownerType) || !isVncSecretKind(record.secretKind) || record.schemaVersion < 1 ||
    !isFiniteInteger(record.schemaVersion) || record.schemaVersion !== VNC_SCHEMA_VERSION ||
    !isFiniteInteger(record.createdAt) || record.createdAt <= 0 ||
    !isFiniteInteger(record.updatedAt) || record.updatedAt <= 0 ||
    !isFiniteInteger(record.resetEpoch) || record.resetEpoch < 0 ||
    !isFiniteInteger(record.cryptoVersion) || record.cryptoVersion < 0 ||
    !isFiniteInteger(record.keyVersion) || record.keyVersion < 0 ||
    !isFiniteInteger(record.aadVersion) || record.aadVersion < 0 ||
    !isFiniteInteger(record.syncVersion) || record.syncVersion < 0 ||
    !isFiniteInteger(record.deletedAt) || record.deletedAt < 0 ||
    !vncRecordPayloadHashMatches(record)) { return false; }
  if (!vncRecordPayloadSemanticallyValid(record)) { return false; }
  if (record.recordType === 'secret') {
    const ownerKindValid: boolean = (record.ownerType === 'host' && record.secretKind === 'vnc_password') ||
      (record.ownerType === 'gateway' && (record.secretKind === 'repeater_token' ||
        record.secretKind === 'gateway_token' || record.secretKind === 'client_certificate'));
    if (record.ownerId.trim() === '' || !ownerKindValid || !vncSecretPayloadIsMetadataOnly(record.payload)) {
      return false;
    }
    if (record.cryptoVersion !== VNC_CRYPTO_VERSION || record.keyVersion !== VNC_KEY_VERSION ||
      record.aadVersion !== VNC_AAD_VERSION) { return false; }
    if (record.deletedAt > 0) {
      return record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION && record.ciphertext === '';
    }
    return record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION &&
      vncCiphertextEnvelopeLooksValid(record.ciphertext);
  }
  const ownerTypeValid: boolean = (record.recordType === 'settings' && record.ownerType === 'account') ||
    (record.recordType === 'host' && record.ownerType === 'account') ||
    (record.recordType === 'gateway' && record.ownerType === 'account') ||
    (record.recordType === 'trust' && record.ownerType === 'host');
  const ownerIdValid: boolean = record.ownerId.trim() !== '' &&
    (record.ownerType !== 'account' || record.ownerId === record.userId);
  return ownerTypeValid && ownerIdValid && record.secretKind === '' && record.envelopeVersion === 0 &&
    record.cryptoVersion === 0 && record.keyVersion === 0 && record.aadVersion === 0 &&
    record.ciphertext === '' && vncSecretPayloadIsMetadataOnly(record.payload);
}

export function vncRecordToCloudRow(record: VncRecord): Record<string, string> {
  const row: Record<string, string> = {};
  row['id'] = record.id;
  row['userid'] = record.userId;
  row['recordtype'] = record.recordType;
  row['ownerid'] = record.ownerId;
  row['ownertype'] = record.ownerType;
  row['secretkind'] = record.secretKind;
  row['payload'] = record.payload;
  row['ciphertext'] = record.ciphertext;
  row['envelopeversion'] = record.envelopeVersion.toString();
  row['cryptoversion'] = record.cryptoVersion.toString();
  row['keyversion'] = record.keyVersion.toString();
  row['aadversion'] = record.aadVersion.toString();
  row['payloadhashsha256'] = record.payloadHashSha256;
  row['syncversion'] = record.syncVersion.toString();
  row['schemaversion'] = record.schemaVersion.toString();
  row['resetepoch'] = record.resetEpoch.toString();
  row['createdat'] = record.createdAt.toString();
  row['updatedat'] = record.updatedAt.toString();
  row['deletedat'] = record.deletedAt.toString();
  return row;
}

export function vncRecordFromCloudRow(row: Record<string, string>): VncRecord {
  const record = new VncRecord();
  record.id = row['id'] || '';
  record.userId = row['userid'] || '';
  const type: string = row['recordtype'] || '';
  // Preserve unknown wire values so the read-side validator rejects them;
  // never coerce malformed cloud data into a valid settings row.
  record.recordType = type as VncRecordType;
  record.ownerId = row['ownerid'] || '';
  const ownerType: string = row['ownertype'] || '';
  record.ownerType = ownerType as VncOwnerType;
  const secretKind: string = row['secretkind'] || '';
  record.secretKind = secretKind as VncSecretKind;
  record.payload = row['payload'] || '{}';
  record.ciphertext = row['ciphertext'] || '';
  record.envelopeVersion = Number(row['envelopeversion'] || '0');
  record.cryptoVersion = Number(row['cryptoversion'] || '0');
  record.keyVersion = Number(row['keyversion'] || '0');
  record.aadVersion = Number(row['aadversion'] || '0');
  record.payloadHashSha256 = row['payloadhashsha256'] || '';
  record.syncVersion = Number(row['syncversion'] || '0');
  record.schemaVersion = Number(row['schemaversion'] || '0');
  record.resetEpoch = Number(row['resetepoch'] || '0');
  record.createdAt = Number(row['createdat'] || '0');
  record.updatedAt = Number(row['updatedat'] || '0');
  record.deletedAt = Number(row['deletedat'] || '0');
  return record;
}

export function vncRecordWins(candidate: VncRecord, current: VncRecord): boolean {
  if (candidate.resetEpoch !== current.resetEpoch) { return candidate.resetEpoch > current.resetEpoch; }
  if (candidate.syncVersion !== current.syncVersion) { return candidate.syncVersion > current.syncVersion; }
  if (candidate.updatedAt !== current.updatedAt) { return candidate.updatedAt > current.updatedAt; }
  return candidate.id > current.id;
}

export function vncRecordNeedsSecretMirror(syncSecrets: boolean, cryptoReady: boolean,
  record: VncRecord): boolean {
  return syncSecrets && cryptoReady && record.recordType === 'secret' && record.ciphertext !== '' &&
    record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION;
}
