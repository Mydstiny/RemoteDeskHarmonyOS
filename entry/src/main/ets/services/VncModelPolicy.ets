import { VncRecord } from '../model/VncRecord';
import { vncCanonicalJson, vncPayloadHashSha256, VNC_SCHEMA_VERSION } from './VncRecordPolicy';

export type VncTransport = 'direct_tcp' | 'ultravnc_repeater' | 'websocket_gateway' | 'ssh_tunnel';
export type VncRepeaterMode = 'mode2' | 'mode12';
export type VncScalingMode = 'fit' | 'integer' | 'one_to_one' | 'pan';
export type VncSecurityPolicy = 'secure_only' | 'trusted_network' | 'allow_plaintext';

export interface VncSettingsValues {
  defaultTransport: VncTransport;
  defaultPort: number;
  connectTimeoutMs: number;
  authTimeoutMs: number;
  firstFrameTimeoutMs: number;
  viewOnly: boolean;
  scalingMode: VncScalingMode;
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
  viewOnly: boolean;
  scalingMode: VncScalingMode;
  securityPolicy: VncSecurityPolicy;
  tls: boolean;
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

export function defaultVncSettings(): VncSettingsValues {
  return {
    defaultTransport: 'direct_tcp', defaultPort: 5900, connectTimeoutMs: 10000,
    authTimeoutMs: 15000, firstFrameTimeoutMs: 15000, viewOnly: true, scalingMode: 'fit',
    clipboardEnabled: false, securityPolicy: 'secure_only', defaultGatewayId: '',
    repeaterMode: 'mode12', syncPreferences: true, syncHosts: true, syncGateways: true,
    syncSecrets: false, syncTrust: false
  };
}

export function validVncPort(port: number): boolean {
  return Number.isFinite(port) && port >= 1 && port <= 65535;
}

export function validateVncHost(values: VncHostValues): string[] {
  const errors: string[] = [];
  if (values.label.trim() === '') { errors.push('VNC 主机名称不能为空'); }
  if (values.host.trim() === '') { errors.push('VNC 主机地址不能为空'); }
  if (!validVncPort(values.port)) { errors.push('VNC 端口必须在 1-65535 之间'); }
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
  if (values.host.trim() === '') { errors.push('VNC 网关地址不能为空'); }
  if (!validVncPort(values.port)) { errors.push('VNC 网关端口必须在 1-65535 之间'); }
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
  payload['scalingMode'] = values.scalingMode;
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
  payload['host'] = values.host.trim();
  payload['port'] = values.port;
  payload['username'] = values.username.trim();
  payload['gatewayId'] = values.gatewayId.trim();
  payload['transport'] = values.transport;
  payload['repeaterMode'] = values.repeaterMode;
  payload['viewOnly'] = values.viewOnly;
  payload['scalingMode'] = values.scalingMode;
  payload['securityPolicy'] = values.securityPolicy;
  payload['tls'] = values.tls;
  return vncCanonicalJson(payload);
}

export function vncGatewayPayload(values: VncGatewayValues): string {
  const payload: Record<string, Object> = {};
  payload['label'] = values.label.trim();
  payload['transport'] = values.transport;
  payload['host'] = values.host.trim();
  payload['port'] = values.port;
  payload['path'] = values.path.trim();
  payload['repeaterMode'] = values.repeaterMode;
  payload['targetId'] = values.targetId.trim();
  payload['tls'] = values.tls;
  payload['enabled'] = values.enabled;
  return vncCanonicalJson(payload);
}

export function vncTrustPayload(fingerprintSha256: string, confirmed: boolean, confirmedAt: number): string {
  const payload: Record<string, Object> = {};
  payload['fingerprintSha256'] = fingerprintSha256.trim().toLowerCase();
  payload['confirmed'] = confirmed;
  payload['confirmedAt'] = confirmedAt;
  return vncCanonicalJson(payload);
}

export function vncSecretMetadataPayload(secretKind: string, label: string): string {
  const payload: Record<string, Object> = {};
  payload['kind'] = secretKind;
  payload['label'] = label.trim();
  return vncCanonicalJson(payload);
}

export function finalizeVncRecord(record: VncRecord): VncRecord {
  record.schemaVersion = VNC_SCHEMA_VERSION;
  record.updatedAt = record.updatedAt > 0 ? record.updatedAt : Date.now();
  record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
  return record;
}
