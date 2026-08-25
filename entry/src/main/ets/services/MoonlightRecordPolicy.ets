import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightInputOverrides,
  MoonlightProfile,
  MoonlightSettings,
  MoonlightStreamOverrides,
  MoonlightTrustCandidate,
  MoonlightWakeOnLan,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  moonlightHostIsValid,
  moonlightProfileIsValid,
  moonlightSettingsAreValid,
  moonlightTrustCandidateIsValid
} from '../model/MoonlightModels';
import {
  MOONLIGHT_SCHEMA_VERSION,
  MoonlightOwnerType,
  MoonlightRecord,
  MoonlightRecordType,
  MoonlightSecretKind,
  moonlightExpectedOwnerType,
  moonlightExpectedSecretKind
} from '../model/MoonlightRecord';

export const MOONLIGHT_PAYLOAD_MAX_BYTES: number = 64 * 1024;
export const MOONLIGHT_CIPHERTEXT_MAX_BYTES: number = 128 * 1024;
export const MOONLIGHT_TOMBSTONE_PAYLOAD: string = '{}';

export type MoonlightQuarantineReason =
  'none' | 'unknown_record_type' | 'unknown_owner_type' | 'owner_mismatch' |
  'secret_kind_mismatch' | 'invalid_envelope' | 'schema_too_new' |
  'invalid_payload_json' | 'duplicate_json_key' | 'non_canonical_payload' |
  'payload_too_large' | 'ciphertext_too_large' | 'hash_mismatch' |
  'invalid_meta' | 'reference_mismatch' | 'invalid_payload_semantics' | 'invalid_tombstone' |
  'secret_plaintext_forbidden';

export interface MoonlightRecordMeta {
  mutationId: string;
  originId: string;
  baseSyncVersion: number;
  fieldVersions: Record<string, number>;
}

export interface MoonlightCanonicalJsonResult {
  ok: boolean;
  canonical: string;
  reason: MoonlightQuarantineReason;
}

export interface MoonlightRecordValidation {
  valid: boolean;
  reason: MoonlightQuarantineReason;
}

const RECORD_TYPES: string[] = ['settings', 'host', 'profile', 'trust', 'secret'];
const OWNER_TYPES: string[] = ['account', 'host', 'profile', ''];
const SECRET_KINDS: string[] = ['client_identity', ''];
const FORBIDDEN_SECRET_KEYS: string[] = [
  'pin', 'password', 'privatekey', 'private_key', 'token', 'sessiontoken',
  'rikey', 'rikeyid', 'localsecurestoreref', 'keyalias', 'alias'
];

const SETTINGS_FIELD_PATHS: string[] = [
  'video.codecPreference', 'video.resolutionMode', 'video.adaptiveResolution',
  'video.customWidth', 'video.customHeight',
  'video.fps', 'video.bitrateKbps', 'video.hdr', 'video.yuv444', 'video.latencyMode',
  'audio.enabled', 'audio.channels', 'audio.volume', 'audio.playOnHost',
  'input.touchMode', 'input.controlMode', 'input.captureKeyboard', 'input.forwardSystemShortcuts',
  'input.controllerSlot', 'input.enableRumble', 'network.discovery',
  'network.preferredAddressFamily', 'network.streamEncryption', 'network.allowLegacySha1',
  'network.meteredNetwork', 'network.autoReconnect', 'network.reconnectBudgetMs',
  'background.allowAudioInBackground', 'background.noSurfaceVideo',
  'security.blockCertificateChanges', 'security.identityStorage',
  'diagnostics.showPerformanceHud', 'diagnostics.logLevel'
];
// These paths were emitted by the pre-common-display/PIP settings format. They
// remain readable so an old local row can be loaded and normalized, but they
// are deliberately excluded from new mutable metadata and new payloads.
const LEGACY_SETTINGS_FIELD_PATHS: string[] = [
  'video.scalingMode', 'background.allowPip'
];
const HOST_FIELD_PATHS: string[] = [
  'displayName', 'addresses', 'preferredAddressKey', 'httpsPort', 'wakeOnLan', 'locked', 'userOrder'
];
const PROFILE_FIELD_PATHS: string[] = [
  'titleSnapshot', 'streamOverrides.codecPreference', 'streamOverrides.resolutionMode',
  'streamOverrides.adaptiveResolution',
  'streamOverrides.customWidth', 'streamOverrides.customHeight', 'streamOverrides.fps',
  'streamOverrides.bitrateKbps', 'streamOverrides.hdr', 'streamOverrides.latencyMode',
  'streamOverrides.scalingMode', 'inputOverrides.touchMode',
  'inputOverrides.captureKeyboard', 'inputOverrides.controllerSlot', 'favorite', 'userOrder'
];

function isFiniteInteger(value: number): boolean {
  return Number.isSafeInteger(value);
}

function isNonNegativeInteger(value: number): boolean {
  return isFiniteInteger(value) && value >= 0;
}

function isBoundedText(value: string, maximum: number): boolean {
  if (typeof value !== 'string' || value.length < 1 || value.length > maximum) { return false; }
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) { return false; }
  }
  return true;
}

function isSha256Hex(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

function recordTypeKnown(value: string): boolean {
  return RECORD_TYPES.indexOf(value) >= 0;
}

function ownerTypeKnown(value: string): boolean {
  return OWNER_TYPES.indexOf(value) >= 0;
}

function secretKindKnown(value: string): boolean {
  return SECRET_KINDS.indexOf(value) >= 0;
}

class MoonlightJsonSyntaxScanner {
  private readonly source: string;
  private offset: number = 0;
  duplicateKey: boolean = false;

  constructor(source: string) {
    this.source = source;
  }

  scan(): boolean {
    this.skipWhitespace();
    if (!this.parseValue()) { return false; }
    this.skipWhitespace();
    return this.offset === this.source.length;
  }

  private skipWhitespace(): void {
    while (this.offset < this.source.length) {
      const value: string = this.source.charAt(this.offset);
      if (value !== ' ' && value !== '\n' && value !== '\r' && value !== '\t') { return; }
      this.offset++;
    }
  }

  private parseValue(): boolean {
    this.skipWhitespace();
    if (this.offset >= this.source.length) { return false; }
    const value: string = this.source.charAt(this.offset);
    if (value === '{') { return this.parseObject(); }
    if (value === '[') { return this.parseArray(); }
    if (value === '"') { return this.parseStringToken() !== null; }
    if (value === 't') { return this.consumeLiteral('true'); }
    if (value === 'f') { return this.consumeLiteral('false'); }
    if (value === 'n') { return this.consumeLiteral('null'); }
    return this.parseNumber();
  }

  private parseObject(): boolean {
    this.offset++;
    this.skipWhitespace();
    const normalizedKeys: string[] = [];
    if (this.consumeCharacter('}')) { return true; }
    while (this.offset < this.source.length) {
      const token: string | null = this.parseStringToken();
      if (token === null) { return false; }
      let key: string = '';
      try {
        key = (JSON.parse(token) as string).normalize('NFC');
      } catch (_e) {
        return false;
      }
      if (normalizedKeys.indexOf(key) >= 0) {
        this.duplicateKey = true;
        return false;
      }
      normalizedKeys.push(key);
      this.skipWhitespace();
      if (!this.consumeCharacter(':')) { return false; }
      if (!this.parseValue()) { return false; }
      this.skipWhitespace();
      if (this.consumeCharacter('}')) { return true; }
      if (!this.consumeCharacter(',')) { return false; }
      this.skipWhitespace();
    }
    return false;
  }

  private parseArray(): boolean {
    this.offset++;
    this.skipWhitespace();
    if (this.consumeCharacter(']')) { return true; }
    while (this.offset < this.source.length) {
      if (!this.parseValue()) { return false; }
      this.skipWhitespace();
      if (this.consumeCharacter(']')) { return true; }
      if (!this.consumeCharacter(',')) { return false; }
      this.skipWhitespace();
    }
    return false;
  }

  private parseStringToken(): string | null {
    if (this.offset >= this.source.length || this.source.charAt(this.offset) !== '"') {
      return null;
    }
    const start: number = this.offset;
    this.offset++;
    let escaped: boolean = false;
    while (this.offset < this.source.length) {
      const value: string = this.source.charAt(this.offset);
      if (!escaped && value === '"') {
        this.offset++;
        return this.source.substring(start, this.offset);
      }
      if (!escaped && value.charCodeAt(0) < 0x20) { return null; }
      if (!escaped && value === '\\') {
        escaped = true;
      } else {
        escaped = false;
      }
      this.offset++;
    }
    return null;
  }

  private parseNumber(): boolean {
    const remaining: string = this.source.substring(this.offset);
    const match: RegExpExecArray | null = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(remaining);
    if (match === null || match[0].length === 0) { return false; }
    const value: number = Number(match[0]);
    if (!Number.isFinite(value)) { return false; }
    this.offset += match[0].length;
    return true;
  }

  private consumeLiteral(value: string): boolean {
    if (this.source.substring(this.offset, this.offset + value.length) !== value) { return false; }
    this.offset += value.length;
    return true;
  }

  private consumeCharacter(value: string): boolean {
    if (this.offset >= this.source.length || this.source.charAt(this.offset) !== value) { return false; }
    this.offset++;
    return true;
  }
}

function canonicalizeValue(value: Object | null): string | null {
  if (value === null) { return 'null'; }
  if (typeof value === 'string') { return JSON.stringify((value as string).normalize('NFC')); }
  if (typeof value === 'boolean') { return value ? 'true' : 'false'; }
  if (typeof value === 'number') {
    const numeric: number = value as number;
    if (!Number.isFinite(numeric)) { return null; }
    return JSON.stringify(numeric);
  }
  if (Array.isArray(value)) {
    const values: Object[] = value as Object[];
    const items: string[] = [];
    for (let i = 0; i < values.length; i++) {
      const item: string | null = canonicalizeValue(values[i]);
      if (item === null) { return null; }
      items.push(item);
    }
    return '[' + items.join(',') + ']';
  }
  if (typeof value !== 'object') { return null; }
  const source: Record<string, Object> = value as Record<string, Object>;
  const originalKeys: string[] = Object.keys(source);
  const normalizedKeys: string[] = [];
  const originalByNormalized: Record<string, string> = {};
  for (let i = 0; i < originalKeys.length; i++) {
    const normalized: string = originalKeys[i].normalize('NFC');
    if (normalizedKeys.indexOf(normalized) >= 0) { return null; }
    normalizedKeys.push(normalized);
    originalByNormalized[normalized] = originalKeys[i];
  }
  normalizedKeys.sort();
  const properties: string[] = [];
  for (let i = 0; i < normalizedKeys.length; i++) {
    const key: string = normalizedKeys[i];
    const originalKey: string = originalByNormalized[key];
    const child: string | null = canonicalizeValue(source[originalKey]);
    if (child === null) { return null; }
    properties.push(JSON.stringify(key) + ':' + child);
  }
  return '{' + properties.join(',') + '}';
}

export function moonlightCanonicalizeJson(source: string): MoonlightCanonicalJsonResult {
  if (typeof source !== 'string' || source.length === 0) {
    return { ok: false, canonical: '', reason: 'invalid_payload_json' };
  }
  const scanner = new MoonlightJsonSyntaxScanner(source);
  if (!scanner.scan()) {
    return {
      ok: false,
      canonical: '',
      reason: scanner.duplicateKey ? 'duplicate_json_key' : 'invalid_payload_json'
    };
  }
  try {
    const parsed: Object = JSON.parse(source) as Object;
    const canonical: string | null = canonicalizeValue(parsed);
    if (canonical === null) {
      return { ok: false, canonical: '', reason: 'invalid_payload_json' };
    }
    return { ok: true, canonical: canonical, reason: 'none' };
  } catch (_e) {
    return { ok: false, canonical: '', reason: 'invalid_payload_json' };
  }
}

function allowedFieldPaths(recordType: MoonlightRecordType): string[] {
  if (recordType === 'settings') { return SETTINGS_FIELD_PATHS; }
  if (recordType === 'host') { return HOST_FIELD_PATHS; }
  if (recordType === 'profile') { return PROFILE_FIELD_PATHS; }
  return [];
}

function readableFieldPaths(recordType: MoonlightRecordType): string[] {
  const mutable: string[] = allowedFieldPaths(recordType);
  if (recordType !== 'settings') { return mutable; }
  return mutable.concat(LEGACY_SETTINGS_FIELD_PATHS);
}

export function moonlightMutableFieldPaths(recordType: MoonlightRecordType): string[] {
  return allowedFieldPaths(recordType).slice();
}

export function moonlightRecordMetaIsValid(
  meta: MoonlightRecordMeta, recordType: MoonlightRecordType
): boolean {
  if (!isBoundedText(meta.mutationId, 128) || !isBoundedText(meta.originId, 128) ||
      !isNonNegativeInteger(meta.baseSyncVersion)) { return false; }
  // Record validation is a read/migration boundary. It must accept the two
  // legacy settings paths long enough for the caller to normalize them.
  const allowed: string[] = readableFieldPaths(recordType);
  const keys: string[] = Object.keys(meta.fieldVersions);
  if (keys.length > allowed.length) { return false; }
  for (let i = 0; i < keys.length; i++) {
    if (allowed.indexOf(keys[i]) < 0 || !isNonNegativeInteger(meta.fieldVersions[keys[i]])) {
      return false;
    }
  }
  return true;
}

export function moonlightPayloadWithMeta(
  businessPayload: Record<string, Object>, meta: MoonlightRecordMeta,
  recordType: MoonlightRecordType
): MoonlightCanonicalJsonResult {
  if (typeof businessPayload['_meta'] !== 'undefined' ||
      !moonlightRecordMetaIsValidForWrite(meta, recordType)) {
    return { ok: false, canonical: '', reason: 'invalid_meta' };
  }
  const values: Record<string, Object> = {};
  const keys: string[] = Object.keys(businessPayload);
  for (let i = 0; i < keys.length; i++) { values[keys[i]] = businessPayload[keys[i]]; }
  const encodedMeta: MoonlightRecordMeta = {
    mutationId: meta.mutationId,
    originId: meta.originId,
    baseSyncVersion: meta.baseSyncVersion,
    fieldVersions: meta.fieldVersions
  };
  values['_meta'] = encodedMeta;
  return moonlightCanonicalizeJson(JSON.stringify(values));
}

function moonlightRecordMetaIsValidForWrite(
  meta: MoonlightRecordMeta, recordType: MoonlightRecordType
): boolean {
  if (!isBoundedText(meta.mutationId, 128) || !isBoundedText(meta.originId, 128) ||
      !isNonNegativeInteger(meta.baseSyncVersion)) { return false; }
  const allowed: string[] = allowedFieldPaths(recordType);
  const keys: string[] = Object.keys(meta.fieldVersions);
  if (keys.length > allowed.length) { return false; }
  for (let i = 0; i < keys.length; i++) {
    if (allowed.indexOf(keys[i]) < 0 || !isNonNegativeInteger(meta.fieldVersions[keys[i]])) {
      return false;
    }
  }
  return true;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let length: number = 0;
  for (let i = 0; i < parts.length; i++) { length += parts[i].length; }
  const result = new Uint8Array(length);
  let offset: number = 0;
  for (let i = 0; i < parts.length; i++) {
    result.set(parts[i], offset);
    offset += parts[i].length;
  }
  return result;
}

function sha256Hex(bytes: Uint8Array): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: bytes });
  const digest = new Uint8Array(md.digestSync().data);
  let result: string = '';
  for (let i = 0; i < digest.length; i++) { result += digest[i].toString(16).padStart(2, '0'); }
  return result;
}

function utf8(value: string): Uint8Array {
  return new util.TextEncoder().encode(value);
}

function bigEndian64(value: number): Uint8Array {
  const bytes = new Uint8Array(8);
  let remaining: number = value;
  for (let i = 7; i >= 0; i--) {
    bytes[i] = remaining % 256;
    remaining = Math.floor(remaining / 256);
  }
  return bytes;
}

function decodeCanonicalBase64Url(value: string): Uint8Array | null {
  if (value.length === 0 || value.length > MOONLIGHT_CIPHERTEXT_MAX_BYTES * 2 ||
      !/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) { return null; }
  try {
    let padded: string = value.replace(/-/g, '+').replace(/_/g, '/');
    while (padded.length % 4 !== 0) { padded += '='; }
    const helper = new util.Base64Helper();
    const decoded: Uint8Array = helper.decodeSync(padded);
    const encoded: string = helper.encodeToStringSync(decoded)
      .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
    return encoded === value ? decoded : null;
  } catch (_e) {
    return null;
  }
}

export function moonlightRecordPayloadHashSha256(record: MoonlightRecord): string {
  const zero = new Uint8Array([0]);
  if (record.deletedAt > 0) {
    return sha256Hex(concatBytes([
      utf8('moonlight-tombstone-v1'), zero, utf8(record.id), zero,
      bigEndian64(record.resetEpoch), bigEndian64(record.syncVersion), bigEndian64(record.deletedAt)
    ]));
  }
  if (record.recordType === 'secret') {
    const decoded: Uint8Array | null = decodeCanonicalBase64Url(record.ciphertext);
    if (decoded === null) { return ''; }
    return sha256Hex(concatBytes([
      utf8('moonlight-secret-v1'), zero, utf8(record.payload), zero, decoded
    ]));
  }
  return sha256Hex(concatBytes([
    utf8('moonlight-live-v1'), zero, utf8(record.recordType), zero, utf8(record.payload)
  ]));
}

function payloadObject(payload: string): Record<string, Object> | null {
  try {
    const parsed: Object = JSON.parse(payload) as Object;
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') { return null; }
    return parsed as Record<string, Object>;
  } catch (_e) {
    return null;
  }
}

function extractMeta(values: Record<string, Object>): MoonlightRecordMeta | null {
  const raw: Object | undefined = values['_meta'];
  if (raw === undefined || raw === null || Array.isArray(raw) || typeof raw !== 'object') {
    return null;
  }
  const meta = raw as Record<string, Object>;
  if (typeof meta['mutationId'] !== 'string' || typeof meta['originId'] !== 'string' ||
      typeof meta['baseSyncVersion'] !== 'number' || meta['fieldVersions'] === null ||
      Array.isArray(meta['fieldVersions']) || typeof meta['fieldVersions'] !== 'object') {
    return null;
  }
  const rawVersions = meta['fieldVersions'] as Record<string, Object>;
  const versions: Record<string, number> = {};
  const keys: string[] = Object.keys(rawVersions);
  for (let i = 0; i < keys.length; i++) {
    if (typeof rawVersions[keys[i]] !== 'number') { return null; }
    versions[keys[i]] = rawVersions[keys[i]] as number;
  }
  return {
    mutationId: meta['mutationId'] as string,
    originId: meta['originId'] as string,
    baseSyncVersion: meta['baseSyncVersion'] as number,
    fieldVersions: versions
  };
}

function secretMetadataIsSafe(values: Record<string, Object>): boolean {
  return secretValueIsSafe(values, 0);
}

function secretValueIsSafe(value: Object, depth: number): boolean {
  if (depth > 32) { return false; }
  if (value === null || typeof value !== 'object') { return true; }
  if (Array.isArray(value)) {
    const values: Object[] = value as Object[];
    for (let i = 0; i < values.length; i++) {
      if (!secretValueIsSafe(values[i], depth + 1)) { return false; }
    }
    return true;
  }
  const source: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    const normalized: string = keys[i].replace(/[^A-Za-z0-9_]/g, '').toLowerCase();
    if (FORBIDDEN_SECRET_KEYS.indexOf(normalized) >= 0 ||
        !secretValueIsSafe(source[keys[i]], depth + 1)) { return false; }
  }
  return true;
}

function keysAreAllowed(values: Record<string, Object>, allowed: string[]): boolean {
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) {
    if (allowed.indexOf(keys[i]) < 0) { return false; }
  }
  return true;
}

function isPlainObject(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isSha256Text(value: Object | undefined): boolean {
  return typeof value === 'string' && isSha256Hex(value as string);
}

function businessPayload(values: Record<string, Object>): Record<string, Object> {
  const result: Record<string, Object> = {};
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== '_meta') { result[keys[i]] = values[keys[i]]; }
  }
  return result;
}

export function moonlightRecordMeta(record: MoonlightRecord): MoonlightRecordMeta | null {
  if (record.deletedAt > 0) { return null; }
  const values: Record<string, Object> | null = payloadObject(record.payload);
  return values === null ? null : extractMeta(values);
}

export function moonlightRecordBusinessPayload(
  record: MoonlightRecord
): Record<string, Object> | null {
  if (record.deletedAt > 0) { return null; }
  const values: Record<string, Object> | null = payloadObject(record.payload);
  return values === null ? null : businessPayload(values);
}

function settingsPayloadIsValid(values: Record<string, Object>): boolean {
  if (!keysAreAllowed(values, [
    'schemaVersion', 'video', 'audio', 'input', 'network', 'background', 'security',
    'diagnostics', '_meta'
  ])) { return false; }
  return moonlightSettingsAreValid(
    businessPayload(values) as Object as MoonlightSettings);
}

function hostPayloadIsValid(record: MoonlightRecord, values: Record<string, Object>): boolean {
  if (!keysAreAllowed(values, [
    'schemaVersion', 'serverUuid', 'displayName', 'addresses', 'preferredAddressKey',
    'httpsPort', 'hostType', 'wakeOnLan', 'locked', 'userOrder', '_meta'
  ]) || values['schemaVersion'] !== 1 || !Array.isArray(values['addresses']) ||
      !isPlainObject(values['wakeOnLan']) ||
      (values['locked'] !== undefined && typeof values['locked'] !== 'boolean') ||
      (values['httpsPort'] !== undefined &&
        (!Number.isSafeInteger(values['httpsPort'] as number) ||
          (values['httpsPort'] as number) < 1 ||
          (values['httpsPort'] as number) > 65535))) { return false; }
  const host: MoonlightHost = {
    id: record.id,
    serverUuid: values['serverUuid'] as string,
    displayName: values['displayName'] as string,
    addresses: values['addresses'] as MoonlightAddress[],
    preferredAddressKey: values['preferredAddressKey'] as string,
    httpsPort: values['httpsPort'] === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
      values['httpsPort'] as number,
    hostType: values['hostType'] as 'sunshine',
    wakeOnLan: values['wakeOnLan'] as MoonlightWakeOnLan,
    locked: values['locked'] === true,
    userOrder: values['userOrder'] as number
  };
  return moonlightHostIsValid(host);
}

function profilePayloadIsValid(record: MoonlightRecord, values: Record<string, Object>): boolean {
  if (!keysAreAllowed(values, [
    'schemaVersion', 'hostId', 'appId', 'titleSnapshot', 'streamOverrides',
    'inputOverrides', 'favorite', 'userOrder', '_meta'
  ]) || values['schemaVersion'] !== 1 || !isPlainObject(values['streamOverrides']) ||
      !isPlainObject(values['inputOverrides']) || typeof values['favorite'] !== 'boolean') {
    return false;
  }
  const profile: MoonlightProfile = {
    id: record.id,
    hostId: values['hostId'] as string,
    appId: values['appId'] as string,
    titleSnapshot: values['titleSnapshot'] as string,
    streamOverrides: values['streamOverrides'] as MoonlightStreamOverrides,
    inputOverrides: values['inputOverrides'] as MoonlightInputOverrides,
    favorite: values['favorite'] as boolean,
    userOrder: values['userOrder'] as number,
    lastUsedAt: 0
  };
  return moonlightProfileIsValid(profile);
}

function trustPayloadIsValid(record: MoonlightRecord, values: Record<string, Object>): boolean {
  if (!keysAreAllowed(values, [
    'schemaVersion', 'hostId', 'serverUuid', 'serverCertificateSha256',
    'pairingGeneration', 'candidateObservedAt', '_meta'
  ]) || values['schemaVersion'] !== 1) { return false; }
  const candidate: MoonlightTrustCandidate = {
    hostId: values['hostId'] as string,
    serverUuid: values['serverUuid'] as string,
    serverCertificateSha256: values['serverCertificateSha256'] as string,
    pairingGeneration: values['pairingGeneration'] as number,
    candidateObservedAt: values['candidateObservedAt'] as number
  };
  return candidate.hostId === record.ownerId && moonlightTrustCandidateIsValid(candidate);
}

function secretPayloadIsValid(values: Record<string, Object>): boolean {
  if (!keysAreAllowed(values, [
    'schemaVersion', 'identityVersion', 'certificateSha256', 'ownerScopeFingerprint',
    'storageMode', 'recoveryState', 'createdAt', 'rotatedAt', '_meta'
  ]) || values['schemaVersion'] !== 1 ||
      !isNonNegativeInteger(values['identityVersion'] as number) ||
      (values['identityVersion'] as number) < 1 || !isSha256Text(values['certificateSha256']) ||
      values['storageMode'] !== 'cloudEncryptedPending') { return false; }
  if (values['ownerScopeFingerprint'] !== undefined &&
      !isSha256Text(values['ownerScopeFingerprint'])) { return false; }
  if (values['recoveryState'] !== undefined &&
      (typeof values['recoveryState'] !== 'string' ||
       !isBoundedText(values['recoveryState'] as string, 64))) { return false; }
  if (values['createdAt'] !== undefined &&
      !isNonNegativeInteger(values['createdAt'] as number)) { return false; }
  if (values['rotatedAt'] !== undefined &&
      !isNonNegativeInteger(values['rotatedAt'] as number)) { return false; }
  return secretMetadataIsSafe(values);
}

function recordPayloadSemanticsAreValid(
  record: MoonlightRecord, values: Record<string, Object>
): boolean {
  try {
    if (record.recordType === 'settings') { return settingsPayloadIsValid(values); }
    if (record.recordType === 'host') { return hostPayloadIsValid(record, values); }
    if (record.recordType === 'profile') { return profilePayloadIsValid(record, values); }
    if (record.recordType === 'trust') { return trustPayloadIsValid(record, values); }
    return record.recordType === 'secret' && secretPayloadIsValid(values);
  } catch (_e) {
    return false;
  }
}

function recordReferencesAreValid(record: MoonlightRecord, values: Record<string, Object>): boolean {
  if (record.recordType === 'settings') {
    return record.ownerId === record.userId;
  }
  if (record.recordType === 'host') {
    return record.ownerId === record.userId && typeof values['serverUuid'] === 'string';
  }
  if (record.recordType === 'profile' || record.recordType === 'trust') {
    return typeof values['hostId'] === 'string' && (values['hostId'] as string) === record.ownerId;
  }
  return record.recordType === 'secret' && record.ownerId === record.userId;
}

function validateEnvelope(record: MoonlightRecord): MoonlightQuarantineReason {
  if (!isBoundedText(record.id, 128) || !isBoundedText(record.userId, 128) ||
      !isBoundedText(record.ownerId, 128) || !recordTypeKnown(record.recordType) ||
      !ownerTypeKnown(record.ownerType) || !secretKindKnown(record.secretKind) ||
      typeof record.payload !== 'string' || typeof record.ciphertext !== 'string' ||
      typeof record.payloadHashSha256 !== 'string' ||
      !isNonNegativeInteger(record.envelopeVersion) || !isNonNegativeInteger(record.cryptoVersion) ||
      !isNonNegativeInteger(record.keyVersion) || !isNonNegativeInteger(record.aadVersion) ||
      !isNonNegativeInteger(record.syncVersion) || !isNonNegativeInteger(record.schemaVersion) ||
      !isNonNegativeInteger(record.resetEpoch) || !isNonNegativeInteger(record.createdAt) ||
      !isNonNegativeInteger(record.updatedAt) || !isNonNegativeInteger(record.deletedAt) ||
      record.updatedAt < record.createdAt ||
      (record.deletedAt > 0 && record.deletedAt < record.createdAt)) {
    return 'invalid_envelope';
  }
  if (record.schemaVersion > MOONLIGHT_SCHEMA_VERSION) { return 'schema_too_new'; }
  if (record.ownerType !== moonlightExpectedOwnerType(record.recordType)) { return 'owner_mismatch'; }
  if (record.secretKind !== moonlightExpectedSecretKind(record.recordType)) {
    return 'secret_kind_mismatch';
  }
  if (record.recordType !== 'secret' &&
      (record.envelopeVersion !== 0 || record.cryptoVersion !== 0 ||
       record.keyVersion !== 0 || record.aadVersion !== 0)) { return 'invalid_envelope'; }
  if (record.recordType === 'secret' && record.deletedAt === 0 &&
      (record.envelopeVersion < 1 || record.cryptoVersion < 1 ||
       record.keyVersion < 1 || record.aadVersion < 1)) { return 'invalid_envelope'; }
  return 'none';
}

export function moonlightValidateRecord(record: MoonlightRecord): MoonlightRecordValidation {
  if (!recordTypeKnown(record.recordType)) {
    return { valid: false, reason: 'unknown_record_type' };
  }
  if (!ownerTypeKnown(record.ownerType)) {
    return { valid: false, reason: 'unknown_owner_type' };
  }
  const envelopeReason: MoonlightQuarantineReason = validateEnvelope(record);
  if (envelopeReason !== 'none') { return { valid: false, reason: envelopeReason }; }
  const payloadBytes: number = utf8(record.payload).length;
  if (payloadBytes > MOONLIGHT_PAYLOAD_MAX_BYTES) {
    return { valid: false, reason: 'payload_too_large' };
  }
  // Ciphertext is canonical Base64URL ASCII. Public records deliberately keep
  // it empty, and some device TextEncoder implementations return undefined for
  // an empty input, so its string length is the exact and safer byte bound.
  if (record.ciphertext.length > MOONLIGHT_CIPHERTEXT_MAX_BYTES * 2) {
    return { valid: false, reason: 'ciphertext_too_large' };
  }
  if (record.deletedAt > 0) {
    if (record.payload !== MOONLIGHT_TOMBSTONE_PAYLOAD || record.ciphertext !== '' ||
        record.envelopeVersion !== 0 || record.cryptoVersion !== 0 ||
        record.keyVersion !== 0 || record.aadVersion !== 0) {
      return { valid: false, reason: 'invalid_tombstone' };
    }
  } else {
    const canonical: MoonlightCanonicalJsonResult = moonlightCanonicalizeJson(record.payload);
    if (!canonical.ok) { return { valid: false, reason: canonical.reason }; }
    if (canonical.canonical !== record.payload) {
      return { valid: false, reason: 'non_canonical_payload' };
    }
    const values: Record<string, Object> | null = payloadObject(record.payload);
    if (values === null) { return { valid: false, reason: 'invalid_payload_json' }; }
    const meta: MoonlightRecordMeta | null = extractMeta(values);
    if (meta === null || !moonlightRecordMetaIsValid(meta, record.recordType)) {
      return { valid: false, reason: 'invalid_meta' };
    }
    if (!recordReferencesAreValid(record, values)) {
      return { valid: false, reason: 'reference_mismatch' };
    }
    if (record.recordType === 'secret' && !secretMetadataIsSafe(values)) {
      return { valid: false, reason: 'secret_plaintext_forbidden' };
    }
    if (!recordPayloadSemanticsAreValid(record, values)) {
      return { valid: false, reason: 'invalid_payload_semantics' };
    }
    if (record.recordType === 'secret') {
      if (record.ciphertext === '' ||
          decodeCanonicalBase64Url(record.ciphertext) === null) {
        return { valid: false, reason: 'secret_plaintext_forbidden' };
      }
    } else if (record.ciphertext !== '') {
      return { valid: false, reason: 'invalid_envelope' };
    }
  }
  const expectedHash: string = moonlightRecordPayloadHashSha256(record);
  if (!isSha256Hex(record.payloadHashSha256) || expectedHash === '' ||
      expectedHash !== record.payloadHashSha256) {
    return { valid: false, reason: 'hash_mismatch' };
  }
  return { valid: true, reason: 'none' };
}

export function moonlightRecordIsValid(record: MoonlightRecord): boolean {
  return moonlightValidateRecord(record).valid;
}

export function moonlightOwnerTypeIsKnown(value: string): boolean {
  return ownerTypeKnown(value);
}

export function moonlightSecretKindIsKnown(value: string): boolean {
  return secretKindKnown(value);
}
