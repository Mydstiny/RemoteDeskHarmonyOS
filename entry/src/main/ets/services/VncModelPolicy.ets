import { VncRecord } from '../model/VncRecord';
import { vncCanonicalJson, vncPayloadHashSha256, VNC_SCHEMA_VERSION } from './VncRecordPolicy';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields
} from './EndpointAddressPolicy';

export type VncTransport = 'direct_tcp' | 'ultravnc_repeater' | 'websocket_gateway' | 'ssh_tunnel';
export type VncRepeaterMode = 'mode2' | 'mode12';
export type VncScalingMode = 'fit' | 'integer' | 'one_to_one' | 'pan';
export type VncSecurityPolicy = 'secure_only' | 'trusted_network' | 'allow_plaintext';
export type VncDisplayScaleMode = 'fit' | '100' | 'integer' | 'custom';
export type VncImageQualityPreset = 'speed' | 'balanced' | 'quality' | 'custom';
export type VncPreferredEncoding = 'auto' | 'zrle' | 'tight' | 'raw';
export type VncColorDepth = 'auto' | '32' | '16' | '8';
export type VncLocalCursorMode = 'auto' | 'arrow' | 'circle' | 'hidden';

export interface VncSettingsValues {
  defaultTransport: VncTransport;
  defaultPort: number;
  connectTimeoutMs: number;
  authTimeoutMs: number;
  firstFrameTimeoutMs: number;
  viewOnly: boolean;
  /** 0=touchpad, 1=direct touch, 2=keyboard/mouse. */
  controlMode: number;
  showDiagnostics: boolean;
  scalingMode: VncScalingMode;
  displayScaleMode: VncDisplayScaleMode;
  customScalePercent: number;
  imageQualityPreset: VncImageQualityPreset;
  preferredEncoding: VncPreferredEncoding;
  colorDepth: VncColorDepth;
  frameRateLimit: number;
  jpegQuality: number;
  localCursorMode: VncLocalCursorMode;
  touchpadSpeed: number;
  reverseWheel: boolean;
  swapMouseButtons: boolean;
  diagnosticsExpanded: boolean;
  diagnosticsRefreshMs: number;
  diagnosticsMetricMask: number;
  clipboardEnabled: boolean;
  securityPolicy: VncSecurityPolicy;
  defaultGatewayId: string;
  repeaterMode: VncRepeaterMode;
  syncPreferences: boolean;
  syncHosts: boolean;
  syncGateways: boolean;
  syncSecrets: boolean;
  syncTrust: boolean;
}

export interface VncHostValues {
  label: string;
  host: string;
  port: number;
  username: string;
  gatewayId: string;
  transport: VncTransport;
  repeaterMode: VncRepeaterMode;
  rememberPassword: boolean;
  viewOnly: boolean;
  /** False inherits VNC display settings; true preserves this host's scalingMode. */
  displayOverrideEnabled: boolean;
  scalingMode: VncScalingMode;
  clipboardEnabled: boolean;
  securityPolicy: VncSecurityPolicy;
  tls: boolean;
  /** UI lock metadata stays in the VNC host payload, never remotehosts. */
  locked: boolean;
  lockType: number;
}

export interface VncGatewayValues {
  label: string;
  transport: VncTransport;
  host: string;
  port: number;
  path: string;
  repeaterMode: VncRepeaterMode;
  targetId: string;
  tls: boolean;
  enabled: boolean;
}

/**
 * Non-authoritative certificate metadata retained for the trust manager.
 * The endpoint binding and SHA-256 fingerprint remain the only trust inputs;
 * these fields are bounded display data and never contain a PEM or chain.
 */
export interface VncTrustCertificateMetadata {
  endpointLabel: string;
  commonName: string;
  subject: string;
  issuer: string;
  notBeforeMs: number;
  notAfterMs: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
}

export function defaultVncSettings(controlMode: number = 0): VncSettingsValues {
  return {
    defaultTransport: 'direct_tcp', defaultPort: 5900, connectTimeoutMs: 10000,
    authTimeoutMs: 15000, firstFrameTimeoutMs: 15000, viewOnly: false,
    controlMode: controlMode === 2 ? 2 : 0,
    showDiagnostics: false, scalingMode: 'fit', displayScaleMode: 'fit',
    customScalePercent: 100, imageQualityPreset: 'balanced', preferredEncoding: 'auto',
    colorDepth: 'auto', frameRateLimit: 30, jpegQuality: 6,
    localCursorMode: 'auto', touchpadSpeed: 100, reverseWheel: false,
    swapMouseButtons: false, diagnosticsExpanded: false, diagnosticsRefreshMs: 500,
    diagnosticsMetricMask: 63,
    clipboardEnabled: false, securityPolicy: 'secure_only', defaultGatewayId: '',
    repeaterMode: 'mode12', syncPreferences: true, syncHosts: true, syncGateways: true,
    syncSecrets: false, syncTrust: false
  };
}

export function validVncPort(port: number): boolean {
  return Number.isSafeInteger(port) && port >= 1 && port <= 65535;
}

function vncNetworkEndpoint(host: string, port: number): EndpointAddressResult {
  return parseEndpointFields(host, port);
}

export function canonicalVncNetworkHost(host: string, port: number): string {
  const parsed: EndpointAddressResult = vncNetworkEndpoint(host, port);
  return parsed.ok && parsed.endpoint.scope === '' ? endpointTransportHost(parsed.endpoint) : host;
}

function appendVncEndpointError(errors: string[], label: string, host: string, port: number): void {
  const parsed: EndpointAddressResult = vncNetworkEndpoint(host, port);
  if (!parsed.ok) {
    errors.push(parsed.error === 'invalid_port' ? label + '端口必须在 1-65535 之间' :
      label + '必须是有效的域名、IPv4 或 IPv6 地址');
  } else if (parsed.endpoint.scope !== '') {
    errors.push(label + '的链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址');
  }
}

export function validateVncHost(values: VncHostValues): string[] {
  const errors: string[] = [];
  if (values.label.trim() === '') { errors.push('VNC 主机名称不能为空'); }
  if (values.transport === 'direct_tcp') {
    appendVncEndpointError(errors, 'VNC 主机地址', values.host, values.port);
  } else {
    if (values.host.trim() === '') { errors.push('VNC Repeater 目标 ID 不能为空'); }
    if (!validVncPort(values.port)) { errors.push('VNC 端口必须在 1-65535 之间'); }
  }
  if (values.gatewayId.trim() !== '' && values.transport === 'direct_tcp') {
    errors.push('直连 TCP 不能绑定网关');
  }
  if (values.transport !== 'direct_tcp' && values.gatewayId.trim() === '') {
    errors.push('VNC 网关传输必须绑定独立 VNC 网关');
  }
  return errors;
}

export function validateVncGateway(values: VncGatewayValues): string[] {
  const errors: string[] = [];
  if (values.label.trim() === '') { errors.push('VNC 网关名称不能为空'); }
  appendVncEndpointError(errors, 'VNC 网关地址', values.host, values.port);
  if (values.transport === 'websocket_gateway' && values.path.trim() === '') {
    errors.push('WebSocket 网关必须配置路径');
  }
  if (values.transport === 'ultravnc_repeater' && values.targetId.trim() === '') {
    errors.push('Repeater 必须配置目标 ID');
  }
  return errors;
}

export function vncSettingsPayload(values: VncSettingsValues): string {
  const payload: Record<string, Object> = {};
  payload['defaultTransport'] = values.defaultTransport;
  payload['defaultPort'] = values.defaultPort;
  payload['connectTimeoutMs'] = values.connectTimeoutMs;
  payload['authTimeoutMs'] = values.authTimeoutMs;
  payload['firstFrameTimeoutMs'] = values.firstFrameTimeoutMs;
  payload['viewOnly'] = values.viewOnly;
  payload['controlMode'] = values.controlMode;
  payload['showDiagnostics'] = values.showDiagnostics;
  payload['scalingMode'] = values.scalingMode;
  payload['displayScaleMode'] = values.displayScaleMode;
  payload['customScalePercent'] = values.customScalePercent;
  payload['imageQualityPreset'] = values.imageQualityPreset;
  payload['preferredEncoding'] = values.preferredEncoding;
  payload['colorDepth'] = values.colorDepth;
  payload['frameRateLimit'] = values.frameRateLimit;
  payload['jpegQuality'] = values.jpegQuality;
  payload['localCursorMode'] = values.localCursorMode;
  payload['touchpadSpeed'] = values.touchpadSpeed;
  payload['reverseWheel'] = values.reverseWheel;
  payload['swapMouseButtons'] = values.swapMouseButtons;
  payload['diagnosticsExpanded'] = values.diagnosticsExpanded;
  payload['diagnosticsRefreshMs'] = values.diagnosticsRefreshMs;
  payload['diagnosticsMetricMask'] = values.diagnosticsMetricMask;
  payload['clipboardEnabled'] = values.clipboardEnabled;
  payload['securityPolicy'] = values.securityPolicy;
  payload['defaultGatewayId'] = values.defaultGatewayId;
  payload['repeaterMode'] = values.repeaterMode;
  payload['syncPreferences'] = values.syncPreferences;
  payload['syncHosts'] = values.syncHosts;
  payload['syncGateways'] = values.syncGateways;
  payload['syncSecrets'] = values.syncSecrets;
  payload['syncTrust'] = values.syncTrust;
  return vncCanonicalJson(payload);
}

export function vncHostPayload(values: VncHostValues): string {
  const payload: Record<string, Object> = {};
  payload['label'] = values.label.trim();
  payload['host'] = values.transport === 'direct_tcp' ?
    canonicalVncNetworkHost(values.host, values.port) : values.host.trim();
  payload['port'] = values.port;
  payload['username'] = values.username.trim();
  payload['gatewayId'] = values.gatewayId.trim();
  payload['transport'] = values.transport;
  payload['repeaterMode'] = values.repeaterMode;
  payload['rememberPassword'] = values.rememberPassword;
  payload['viewOnly'] = values.viewOnly;
  payload['displayOverrideEnabled'] = values.displayOverrideEnabled;
  payload['scalingMode'] = values.scalingMode;
  payload['clipboardEnabled'] = values.clipboardEnabled;
  payload['securityPolicy'] = values.securityPolicy;
  payload['tls'] = values.tls;
  payload['locked'] = values.locked;
  payload['lockType'] = values.lockType;
  return vncCanonicalJson(payload);
}

export function vncGatewayPayload(values: VncGatewayValues): string {
  const payload: Record<string, Object> = {};
  payload['label'] = values.label.trim();
  payload['transport'] = values.transport;
  payload['host'] = canonicalVncNetworkHost(values.host, values.port);
  payload['port'] = values.port;
  payload['path'] = values.path.trim();
  payload['repeaterMode'] = values.repeaterMode;
  payload['targetId'] = values.targetId.trim();
  payload['tls'] = values.tls;
  payload['enabled'] = values.enabled;
  return vncCanonicalJson(payload);
}

export function vncTrustPayload(fingerprintSha256: string, confirmed: boolean, confirmedAt: number,
  ownerType: string, storeIdentityFingerprint: string, endpointBindingFingerprint: string,
  metadata: VncTrustCertificateMetadata | null = null): string {
  const payload: Record<string, Object> = {};
  payload['payloadVersion'] = 2;
  payload['fingerprintSha256'] = fingerprintSha256.trim().toLowerCase();
  payload['confirmed'] = confirmed;
  payload['confirmedAt'] = confirmedAt;
  payload['ownerType'] = ownerType.trim();
  payload['storeIdentityFingerprint'] = storeIdentityFingerprint.trim().toLowerCase();
  payload['endpointBindingFingerprint'] = endpointBindingFingerprint.trim().toLowerCase();
  if (metadata !== null) {
    payload['endpointLabel'] = metadata.endpointLabel.trim();
    payload['commonName'] = metadata.commonName.trim();
    payload['subject'] = metadata.subject.trim();
    payload['issuer'] = metadata.issuer.trim();
    payload['notBeforeMs'] = metadata.notBeforeMs;
    payload['notAfterMs'] = metadata.notAfterMs;
    payload['rootTrusted'] = metadata.rootTrusted;
    payload['hostMismatch'] = metadata.hostMismatch;
  }
  return vncCanonicalJson(payload);
}

export function vncSecretMetadataPayload(secretKind: string, label: string,
  storageMode: string = 'encrypted_v3'): string {
  const payload: Record<string, Object> = {};
  payload['kind'] = secretKind;
  payload['label'] = label.trim();
  payload['storageMode'] = storageMode;
  return vncCanonicalJson(payload);
}

export function finalizeVncRecord(record: VncRecord): VncRecord {
  record.schemaVersion = VNC_SCHEMA_VERSION;
  record.updatedAt = record.updatedAt > 0 ? record.updatedAt : Date.now();
  record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
  return record;
}
