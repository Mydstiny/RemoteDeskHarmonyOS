import { SshJumpHop, SshRoute, SshRouteType } from '../types/rdpnapi';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields
} from './EndpointAddressPolicy';

export const SSH_PROXY_PROFILE_SCHEMA_VERSION: number = 1;
export const SSH_PROXY_ROUTE_SCHEMA_VERSION: number = 1;
export const SSH_PROXY_MAX_JUMP_HOPS: number = 3;
const SSH_PROXY_MAX_TEXT: number = 255;
const SSH_PROXY_MAX_ID: number = 128;
const SSH_PROXY_MAX_TIMEOUT_MS: number = 2147483647;

export type SshProxyHopHostKeyPolicy = 'strict';

/** Durable UI metadata kept parallel to the frozen native hop array. */
export interface SshProxyHopMetadataV1 {
  hopId: string;
  label: string;
  keyId: string;
  hostKeyPolicy: SshProxyHopHostKeyPolicy;
  position: number;
}

/** Durable SSH proxy metadata. Credentials are deliberately not part of this shape. */
export interface SshProxyProfileV1 {
  schemaVersion: 1;
  hostId: string;
  route: SshRoute;
  proxyHost?: string;
  proxyPort?: number;
  proxyUsername?: string;
  proxyAuthRequired?: boolean;
  hopMetadata?: SshProxyHopMetadataV1[];
  updatedAtMs?: number;
}

export interface SshRouteValidationResult {
  valid: boolean;
  code: string;
  message: string;
  route: SshRoute;
}

export interface SshProxyProfileValidationResult {
  valid: boolean;
  code: string;
  message: string;
  profile: SshProxyProfileV1 | null;
}

/** Structural input accepted from the legacy RemoteHost flat fields. */
export interface SshLegacyRemoteHostInput {
  id?: string;
  hostId?: string;
  type?: string;
  sshProxyType?: string;
  host?: string;
  port?: number;
  username?: string;
  proxyUsername?: string;
  sshProxyUsername?: string;
  authMethod?: string;
  sshProxyAuthMethod?: string;
  keyId?: string;
  sshKeyId?: string;
  sshProxyKeyId?: string;
  proxyHost?: string;
  proxyPort?: number;
  jumpHost?: string;
  jumpPort?: number;
  jumpUsername?: string;
  jumpAuthMethod?: string;
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
  sshHostKeyAlgorithm?: string;
  sshHostKeyFingerprintSha256?: string;
  sshHostKeyRawBase64?: string;
  sshJumpHostKeyAlgorithm?: string;
  sshJumpHostKeyFingerprintSha256?: string;
  sshJumpHostKeyRawBase64?: string;
}

const ROUTE_TYPES: SshRouteType[] = [
  'direct', 'http_connect', 'socks5', 'frp_tcp', 'ssh_jump',
  'frp_visitor', 'frp_stcp', 'frp_sudp', 'frp_xtcp'
];
const PROFILE_KEYS: string[] = [
  'schemaVersion', 'hostId', 'route', 'proxyHost', 'proxyPort', 'proxyUsername',
  'proxyAuthRequired', 'hopMetadata', 'updatedAtMs'
];
const ROUTE_KEYS: string[] = [
  'schemaVersion', 'type', 'endpointHost', 'endpointPort', 'hops', 'controlId', 'connectTimeoutMs'
];
const HOP_KEYS: string[] = [
  'host', 'port', 'username', 'authMethod',
  'expectedHostKeyRawBase64', 'expectedHostKeyFingerprintSha256', 'connectTimeoutMs'
];
const HOP_METADATA_KEYS: string[] = ['hopId', 'label', 'keyId', 'hostKeyPolicy', 'position'];

function isObject(value: Object): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasOwn(value: Object, key: string): boolean {
  return Object.keys(value as Record<string, Object>).indexOf(key) >= 0;
}

function hasOnlyKeys(value: Object, allowed: string[]): boolean {
  const record: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let index: number = 0; index < keys.length; index++) {
    if (allowed.indexOf(keys[index]) < 0) { return false; }
  }
  return true;
}

function text(record: Record<string, Object>, key: string, required: boolean = false): string | null {
  if (!hasOwn(record, key)) { return required ? null : ''; }
  return typeof record[key] === 'string' ? (record[key] as string).trim() : null;
}

function validPort(value: Object): boolean {
  return typeof value === 'number' && Number.isFinite(value as number) &&
    Number.isInteger(value as number) && (value as number) >= 1 && (value as number) <= 65535;
}

function validTimeout(value: Object): boolean {
  return typeof value === 'number' && Number.isFinite(value as number) &&
    Number.isInteger(value as number) && (value as number) >= 1 &&
    (value as number) <= SSH_PROXY_MAX_TIMEOUT_MS;
}

function validTimestamp(value: Object): boolean {
  return typeof value === 'number' && Number.isFinite(value as number) &&
    Number.isInteger(value as number) && (value as number) >= 0;
}

function knownRouteType(value: string): boolean {
  return ROUTE_TYPES.indexOf(value as SshRouteType) >= 0;
}

function authMethod(value: string): boolean {
  return value === 'password' || value === 'publickey' || value === 'kbd-interactive';
}

function invalidRoute(code: string, message: string, route: SshRoute): SshRouteValidationResult {
  return { valid: false, code, message, route };
}

function cloneHop(hop: SshJumpHop): SshJumpHop {
  const result: SshJumpHop = {
    host: hop.host, port: hop.port, username: hop.username,
    authMethod: hop.authMethod, connectTimeoutMs: hop.connectTimeoutMs
  };
  if (hop.expectedHostKeyRawBase64 !== undefined) {
    result.expectedHostKeyRawBase64 = hop.expectedHostKeyRawBase64;
  }
  if (hop.expectedHostKeyFingerprintSha256 !== undefined) {
    result.expectedHostKeyFingerprintSha256 = hop.expectedHostKeyFingerprintSha256;
  }
  return result;
}

function cloneRoute(route: SshRoute): SshRoute {
  const result: SshRoute = {
    schemaVersion: route.schemaVersion, type: route.type,
    endpointHost: route.endpointHost, endpointPort: route.endpointPort,
    hops: route.hops.map((hop: SshJumpHop): SshJumpHop => cloneHop(hop)),
    connectTimeoutMs: route.connectTimeoutMs
  };
  if (route.controlId !== undefined) { result.controlId = route.controlId; }
  return result;
}

export function validateSshRoute(route: SshRoute): SshRouteValidationResult {
  const raw: Object = route as Object;
  if (!isObject(raw) || !hasOnlyKeys(raw, ROUTE_KEYS)) {
    return invalidRoute('E-SSH-PROXY-ROUTE-FIELDS', 'SSH route 字段不在 canonical allowlist', route);
  }
  const record: Record<string, Object> = raw as Record<string, Object>;
  if (record['schemaVersion'] !== SSH_PROXY_ROUTE_SCHEMA_VERSION) {
    return invalidRoute('E-SSH-PROXY-ROUTE-SCHEMA', 'SSH route schema 不是 v1', route);
  }
  const typeValue: string | null = text(record, 'type', true);
  if (typeValue === 'legacy_gateway') {
    return invalidRoute('E-SSH-PROXY-LEGACY-GATEWAY', 'legacy_gateway 已明确拒绝', route);
  }
  if (typeValue === null || !knownRouteType(typeValue)) {
    return invalidRoute('E-SSH-PROXY-ROUTE-TYPE', 'SSH route type 无效', route);
  }
  if (!validPort(record['endpointPort'])) {
    return invalidRoute('E-SSH-PROXY-ENDPOINT-PORT', 'SSH endpoint port 无效', route);
  }
  const endpointHostInput: string | null = typeof record['endpointHost'] === 'string' ?
    record['endpointHost'] as string : null;
  const endpoint: EndpointAddressResult = endpointHostInput === null ?
    new EndpointAddressResult() : parseEndpointFields(endpointHostInput, record['endpointPort'] as number);
  if (!endpoint.ok || endpoint.endpoint.scope !== '') {
    return invalidRoute('E-SSH-PROXY-ENDPOINT-HOST', 'SSH endpoint host 无效或尚未支持作用域 IPv6', route);
  }
  const endpointHost: string = endpointTransportHost(endpoint.endpoint);
  if (!validTimeout(record['connectTimeoutMs'])) {
    return invalidRoute('E-SSH-PROXY-TIMEOUT', 'SSH connect timeout 无效', route);
  }
  if (!Array.isArray(record['hops'])) {
    return invalidRoute('E-SSH-PROXY-HOPS', 'SSH route hops 必须是数组', route);
  }
  const rawHops: Object[] = record['hops'] as Object[];
  if (rawHops.length > SSH_PROXY_MAX_JUMP_HOPS) {
    return invalidRoute('E-SSH-PROXY-HOP-LIMIT', 'SSH ProxyJump 最多三跳，不能截断第四跳', route);
  }
  if (typeValue !== 'ssh_jump' && rawHops.length > 0) {
    return invalidRoute('E-SSH-PROXY-HOPS-NOT-ALLOWED', '非 ssh_jump route 不允许 hops', route);
  }
  if (typeValue === 'ssh_jump' && rawHops.length === 0) {
    return invalidRoute('E-SSH-PROXY-HOPS-REQUIRED', 'ssh_jump route 至少需要一跳', route);
  }
  const hops: SshJumpHop[] = [];
  for (let index: number = 0; index < rawHops.length; index++) {
    const rawHop: Object = rawHops[index];
    if (!isObject(rawHop) || !hasOnlyKeys(rawHop, HOP_KEYS)) {
      return invalidRoute('E-SSH-PROXY-HOP-FIELDS', 'SSH hop 字段不在 canonical allowlist', route);
    }
    const hopRecord: Record<string, Object> = rawHop as Record<string, Object>;
    const hostInput: string | null = typeof hopRecord['host'] === 'string' ?
      hopRecord['host'] as string : null;
    const username: string | null = text(hopRecord, 'username', true);
    const method: string | null = text(hopRecord, 'authMethod', true);
    if (hostInput === null || username === null || username.length === 0 || username.length > SSH_PROXY_MAX_TEXT ||
      method === null || !authMethod(method) || !validPort(hopRecord['port']) ||
      !validTimeout(hopRecord['connectTimeoutMs'])) {
      return invalidRoute('E-SSH-PROXY-HOP', 'SSH jump hop 字段无效', route);
    }
    const parsedHop: EndpointAddressResult =
      parseEndpointFields(hostInput, hopRecord['port'] as number);
    if (!parsedHop.ok || parsedHop.endpoint.scope !== '') {
      return invalidRoute('E-SSH-PROXY-HOP', 'SSH jump hop 地址无效或尚未支持作用域 IPv6', route);
    }
    const host: string = endpointTransportHost(parsedHop.endpoint);
    const rawKey: string | null = text(hopRecord, 'expectedHostKeyRawBase64');
    const fingerprint: string | null = text(hopRecord, 'expectedHostKeyFingerprintSha256');
    if (rawKey === null || fingerprint === null ||
      rawKey.length > SSH_PROXY_MAX_TEXT || fingerprint.length > SSH_PROXY_MAX_TEXT) {
      return invalidRoute('E-SSH-PROXY-HOST-KEY', 'SSH hop host-key metadata 无效', route);
    }
    const hop: SshJumpHop = {
      host, port: hopRecord['port'] as number, username,
      authMethod: method as 'password' | 'publickey' | 'kbd-interactive',
      connectTimeoutMs: hopRecord['connectTimeoutMs'] as number
    };
    if (rawKey.length > 0) { hop.expectedHostKeyRawBase64 = rawKey; }
    if (fingerprint.length > 0) { hop.expectedHostKeyFingerprintSha256 = fingerprint; }
    hops.push(hop);
  }
  const controlId: string | null = text(record, 'controlId');
  if (controlId === null || controlId.length > SSH_PROXY_MAX_TEXT) {
    return invalidRoute('E-SSH-PROXY-CONTROL-ID', 'SSH route controlId 无效', route);
  }
  const normalized: SshRoute = {
    schemaVersion: SSH_PROXY_ROUTE_SCHEMA_VERSION, type: typeValue as SshRouteType,
    endpointHost, endpointPort: record['endpointPort'] as number,
    hops, connectTimeoutMs: record['connectTimeoutMs'] as number
  };
  if (controlId.length > 0) { normalized.controlId = controlId; }
  return { valid: true, code: '', message: '', route: normalized };
}

export function validateSshProxyProfile(profile: SshProxyProfileV1): SshProxyProfileValidationResult {
  const raw: Object = profile as Object;
  if (!isObject(raw) || !hasOnlyKeys(raw, PROFILE_KEYS)) {
    return { valid: false, code: 'E-SSH-PROXY-PROFILE-FIELDS', message: 'SSH proxy profile 字段不在 allowlist', profile: null };
  }
  const record: Record<string, Object> = raw as Record<string, Object>;
  if (record['schemaVersion'] !== SSH_PROXY_PROFILE_SCHEMA_VERSION) {
    return { valid: false, code: 'E-SSH-PROXY-PROFILE-SCHEMA', message: 'SSH proxy profile schema 不是 v1', profile: null };
  }
  const hostId: string | null = text(record, 'hostId', true);
  if (hostId === null || hostId.length === 0 || hostId.length > SSH_PROXY_MAX_ID) {
    return { valid: false, code: 'E-SSH-PROXY-HOST-ID', message: 'SSH proxy profile 缺少 hostId', profile: null };
  }
  const route: SshRouteValidationResult = validateSshRoute(record['route'] as SshRoute);
  if (!route.valid) {
    return { valid: false, code: route.code, message: route.message, profile: null };
  }
  if (route.route.type === 'frp_visitor' || route.route.type === 'frp_stcp' ||
    route.route.type === 'frp_sudp' || route.route.type === 'frp_xtcp') {
    return {
      valid: false,
      code: 'E-SSH-PROXY-FRP-CONTROL-PLANE',
      message: '应用只接收外部 FRP 已暴露的 TCP 入口',
      profile: null
    };
  }
  const proxyHostInput: string | null = !hasOwn(record, 'proxyHost') ? '' :
    (typeof record['proxyHost'] === 'string' ? record['proxyHost'] as string : null);
  if (proxyHostInput === null) {
    return { valid: false, code: 'E-SSH-PROXY-HOST', message: 'proxyHost 无效', profile: null };
  }
  const needsProxyEndpoint: boolean = route.route.type === 'http_connect' ||
    route.route.type === 'socks5' || route.route.type === 'frp_tcp';
  if (needsProxyEndpoint && !validPort(record['proxyPort'])) {
    return { valid: false, code: 'E-SSH-PROXY-ENDPOINT', message: '代理或 FRP TCP 入口无效', profile: null };
  }
  const parsedProxy: EndpointAddressResult = needsProxyEndpoint ?
    parseEndpointFields(proxyHostInput, record['proxyPort'] as number) : new EndpointAddressResult();
  if (needsProxyEndpoint && (!parsedProxy.ok || parsedProxy.endpoint.scope !== '')) {
    return { valid: false, code: 'E-SSH-PROXY-ENDPOINT', message: '代理或 FRP TCP 地址无效或尚未支持作用域 IPv6', profile: null };
  }
  const proxyHost: string = parsedProxy.ok ? endpointTransportHost(parsedProxy.endpoint) : proxyHostInput;
  if (!needsProxyEndpoint && (proxyHost.length > 0 || hasOwn(record, 'proxyPort'))) {
    return { valid: false, code: 'E-SSH-PROXY-ENDPOINT-NOT-ALLOWED', message: '当前路由不允许 proxy endpoint', profile: null };
  }
  if (hasOwn(record, 'proxyAuthRequired') && typeof record['proxyAuthRequired'] !== 'boolean') {
    return { valid: false, code: 'E-SSH-PROXY-AUTH-FLAG', message: '代理认证标记无效', profile: null };
  }
  const proxyAuthRequired: boolean = record['proxyAuthRequired'] === true;
  if (proxyAuthRequired && route.route.type !== 'http_connect' && route.route.type !== 'socks5') {
    return { valid: false, code: 'E-SSH-PROXY-AUTH-NOT-ALLOWED', message: '当前路由不允许代理认证', profile: null };
  }
  const username: string | null = text(record, 'proxyUsername');
  if (username === null || username.length > SSH_PROXY_MAX_TEXT) {
    return { valid: false, code: 'E-SSH-PROXY-USERNAME', message: 'proxyUsername 无效', profile: null };
  }
  if (hasOwn(record, 'updatedAtMs') && !validTimestamp(record['updatedAtMs'])) {
    return { valid: false, code: 'E-SSH-PROXY-UPDATED-AT', message: 'updatedAtMs 无效', profile: null };
  }
  const metadata: SshProxyHopMetadataV1[] = [];
  if (hasOwn(record, 'hopMetadata')) {
    if (!Array.isArray(record['hopMetadata'])) {
      return { valid: false, code: 'E-SSH-PROXY-HOP-METADATA', message: 'hopMetadata 必须是数组', profile: null };
    }
    const rawMetadata: Object[] = record['hopMetadata'] as Object[];
    if (rawMetadata.length !== route.route.hops.length || route.route.type !== 'ssh_jump') {
      return { valid: false, code: 'E-SSH-PROXY-HOP-METADATA-COUNT', message: '跳板元数据必须与 hops 一一对应', profile: null };
    }
    const hopIds: Set<string> = new Set<string>();
    for (let index: number = 0; index < rawMetadata.length; index++) {
      const rawItem: Object = rawMetadata[index];
      if (!isObject(rawItem) || !hasOnlyKeys(rawItem, HOP_METADATA_KEYS)) {
        return { valid: false, code: 'E-SSH-PROXY-HOP-METADATA-FIELDS', message: '跳板元数据字段无效', profile: null };
      }
      const item: Record<string, Object> = rawItem as Record<string, Object>;
      const hopId: string | null = text(item, 'hopId', true);
      const label: string | null = text(item, 'label', true);
      const keyId: string | null = text(item, 'keyId');
      if (hopId === null || hopId.length === 0 || hopId.length > SSH_PROXY_MAX_ID || hopIds.has(hopId) ||
        label === null || label.length === 0 || label.length > SSH_PROXY_MAX_TEXT ||
        keyId === null || keyId.length > SSH_PROXY_MAX_ID || item['hostKeyPolicy'] !== 'strict' ||
        item['position'] !== index) {
        return { valid: false, code: 'E-SSH-PROXY-HOP-METADATA', message: '跳板元数据无效', profile: null };
      }
      if (route.route.hops[index].authMethod === 'publickey' && keyId.length === 0) {
        return { valid: false, code: 'E-SSH-PROXY-HOP-KEY', message: '公钥认证的跳板缺少密钥引用', profile: null };
      }
      if (route.route.hops[index].authMethod !== 'publickey' && keyId.length > 0) {
        return { valid: false, code: 'E-SSH-PROXY-HOP-KEY-NOT-ALLOWED', message: '非公钥认证不允许密钥引用', profile: null };
      }
      hopIds.add(hopId);
      metadata.push({ hopId, label, keyId, hostKeyPolicy: 'strict', position: index });
    }
  } else if (route.route.type === 'ssh_jump') {
    return { valid: false, code: 'E-SSH-PROXY-HOP-METADATA-REQUIRED', message: '跳板路由缺少元数据', profile: null };
  }
  const normalized: SshProxyProfileV1 = {
    schemaVersion: 1, hostId, route: route.route
  };
  if (needsProxyEndpoint) {
    normalized.proxyHost = proxyHost;
    normalized.proxyPort = record['proxyPort'] as number;
  }
  if (username.length > 0) { normalized.proxyUsername = username; }
  if (proxyAuthRequired) { normalized.proxyAuthRequired = true; }
  if (metadata.length > 0) { normalized.hopMetadata = metadata; }
  if (hasOwn(record, 'updatedAtMs')) { normalized.updatedAtMs = record['updatedAtMs'] as number; }
  return { valid: true, code: '', message: '', profile: normalized };
}

export function serializeSshProxyProfile(profile: SshProxyProfileV1): string | null {
  const result: SshProxyProfileValidationResult = validateSshProxyProfile(profile);
  if (!result.valid || result.profile === null) { return null; }
  try { return JSON.stringify(result.profile); } catch (_err) { return null; }
}

export function deserializeSshProxyProfile(raw: string): SshProxyProfileV1 | null {
  try {
    if (raw.trim().length === 0) { return null; }
    const parsed: Object = JSON.parse(raw) as Object;
    const result: SshProxyProfileValidationResult = validateSshProxyProfile(parsed as SshProxyProfileV1);
    return result.valid ? result.profile : null;
  } catch (_err) { return null; }
}

export function serializeSshProxyProfiles(profiles: SshProxyProfileV1[]): string | null {
  if (!Array.isArray(profiles)) { return null; }
  const normalized: SshProxyProfileV1[] = [];
  const ids: Set<string> = new Set<string>();
  for (let index: number = 0; index < profiles.length; index++) {
    const result: SshProxyProfileValidationResult = validateSshProxyProfile(profiles[index]);
    if (!result.valid || result.profile === null || ids.has(result.profile.hostId)) { return null; }
    ids.add(result.profile.hostId);
    normalized.push(result.profile);
  }
  try { return JSON.stringify(normalized); } catch (_err) { return null; }
}

export function deserializeSshProxyProfiles(raw: string): SshProxyProfileV1[] | null {
  try {
    if (raw.trim().length === 0) { return []; }
    const parsed: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) { return null; }
    const values: SshProxyProfileV1[] = [];
    const ids: Set<string> = new Set<string>();
    for (let index: number = 0; index < parsed.length; index++) {
      const result: SshProxyProfileValidationResult =
        validateSshProxyProfile(parsed[index] as SshProxyProfileV1);
      if (!result.valid || result.profile === null || ids.has(result.profile.hostId)) { return null; }
      ids.add(result.profile.hostId);
      values.push(result.profile);
    }
    return values;
  } catch (_err) { return null; }
}

export function mapLegacyRemoteHostToSshProxyProfile(
  source: SshLegacyRemoteHostInput
): SshProxyProfileV1 | null {
  const hostId: string = (source.id || source.hostId || '').trim();
  const endpointHost: string = (source.host || '').trim();
  const endpointPort: number = source.port === undefined ? 22 : source.port;
  const type: string = (source.sshProxyType || source.type || 'direct').trim() || 'direct';
  const route: SshRoute = {
    schemaVersion: 1, type: type as SshRouteType, endpointHost, endpointPort,
    hops: [], connectTimeoutMs: 10000
  };
  if (type === 'ssh_jump') {
    const jumpHost: string = (source.proxyHost || source.jumpHost || '').trim();
    const jumpPort: number = source.proxyPort === undefined
      ? (source.jumpPort === undefined ? 22 : source.jumpPort) : source.proxyPort;
    const jumpUsername: string = (source.sshProxyUsername || source.proxyUsername ||
      source.jumpUsername || '').trim();
    const jumpAuthMethod: string = (source.sshProxyAuthMethod || source.jumpAuthMethod || 'password').trim();
    const hop: SshJumpHop = {
      host: jumpHost, port: jumpPort, username: jumpUsername,
      authMethod: jumpAuthMethod as 'password' | 'publickey' | 'kbd-interactive',
      connectTimeoutMs: 10000
    };
    const rawKey: string = (source.sshJumpHostKeyRawBase64 || source.expectedHostKeyRawBase64 || '').trim();
    const fingerprint: string = (source.sshJumpHostKeyFingerprintSha256 ||
      source.expectedHostKeyFingerprintSha256 || '').trim();
    if (rawKey.length > 0) { hop.expectedHostKeyRawBase64 = rawKey; }
    if (fingerprint.length > 0) { hop.expectedHostKeyFingerprintSha256 = fingerprint; }
    route.hops.push(hop);
  }
  const result: SshProxyProfileV1 = { schemaVersion: 1, hostId, route };
  if (type === 'http_connect' || type === 'socks5' || type === 'frp_tcp') {
    result.proxyHost = (source.proxyHost || '').trim();
    result.proxyPort = source.proxyPort === undefined ? 0 : source.proxyPort;
  }
  const username: string = (source.sshProxyUsername || source.proxyUsername || '').trim();
  if (username.length > 0) { result.proxyUsername = username; }
  if (type === 'ssh_jump') {
    result.hopMetadata = [{
      hopId: 'legacy-hop-1', label: '跳板机 1',
      keyId: (source.sshProxyKeyId || '').trim(),
      hostKeyPolicy: 'strict', position: 0
    }];
  }
  return validateSshProxyProfile(result).profile;
}
