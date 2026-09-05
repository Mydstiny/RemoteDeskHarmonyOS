import { RemoteHost } from '../model/RemoteHost';
import { SshJumpHop, SshRoute } from '../types/rdpnapi';
import {
  SshProxyHopMetadataV1,
  SshProxyProfileV1,
  SshProxyProfileValidationResult,
  validateSshProxyProfile
} from './SshProxyProfilePolicy';
import { parseEndpointPortText } from './EndpointAddressPolicy';

export type SshProxyEditorKind = 'direct' | 'http_connect' | 'socks5' | 'ssh_jump' | 'frp_tcp';
export type SshProxyEditorAuthMethod = 'password' | 'publickey' | 'kbd-interactive';

export interface SshProxyHopDraft {
  hopId: string;
  label: string;
  host: string;
  portText: string;
  username: string;
  authMethod: SshProxyEditorAuthMethod;
  keyId: string;
  expectedHostKeyFingerprintSha256: string;
  connectTimeoutMs: number;
}

export interface SshProxyEditorValue {
  kind: SshProxyEditorKind;
  proxyHost: string;
  proxyPortText: string;
  proxyUsername: string;
  proxyAuthRequired: boolean;
  hops: SshProxyHopDraft[];
}

export interface SshProxyEditorBuildResult {
  valid: boolean;
  code: string;
  message: string;
  profile: SshProxyProfileV1 | null;
}

export function defaultSshProxyHop(index: number): SshProxyHopDraft {
  return {
    hopId: 'hop-' + Date.now().toString(36) + '-' + index.toString(),
    label: '跳板机 ' + (index + 1).toString(),
    host: '', portText: '22', username: '', authMethod: 'password', keyId: '',
    expectedHostKeyFingerprintSha256: '', connectTimeoutMs: 10000
  };
}

export function defaultSshProxyEditorValue(): SshProxyEditorValue {
  return {
    kind: 'direct', proxyHost: '', proxyPortText: '8080', proxyUsername: '',
    proxyAuthRequired: false, hops: [defaultSshProxyHop(0)]
  };
}

export function sshProxyEditorValueFromProfile(profile: SshProxyProfileV1): SshProxyEditorValue {
  const value: SshProxyEditorValue = defaultSshProxyEditorValue();
  value.kind = profile.route.type as SshProxyEditorKind;
  value.proxyHost = profile.proxyHost || '';
  value.proxyPortText = (profile.proxyPort ||
    (value.kind === 'socks5' ? 1080 : (value.kind === 'frp_tcp' ? 60022 : 8080))).toString();
  value.proxyUsername = profile.proxyUsername || '';
  value.proxyAuthRequired = profile.proxyAuthRequired === true;
  if (profile.route.type === 'ssh_jump') {
    value.hops = profile.route.hops.map((hop: SshJumpHop, index: number): SshProxyHopDraft => {
      const metadata: SshProxyHopMetadataV1 | undefined = profile.hopMetadata === undefined
        ? undefined : profile.hopMetadata[index];
      return {
        hopId: metadata === undefined ? 'hop-' + index.toString() : metadata.hopId,
        label: metadata === undefined ? '跳板机 ' + (index + 1).toString() : metadata.label,
        host: hop.host,
        portText: hop.port.toString(),
        username: hop.username,
        authMethod: hop.authMethod,
        keyId: metadata === undefined ? '' : metadata.keyId,
        expectedHostKeyFingerprintSha256: hop.expectedHostKeyFingerprintSha256 || '',
        connectTimeoutMs: hop.connectTimeoutMs
      };
    });
  }
  return value;
}

function validPortText(value: string): number {
  return parseEndpointPortText(value);
}

export function buildSshProxyProfile(hostId: string, targetHost: string, targetPort: number,
  value: SshProxyEditorValue): SshProxyEditorBuildResult {
  const route: SshRoute = {
    schemaVersion: 1, type: value.kind, endpointHost: targetHost, endpointPort: targetPort,
    hops: [], connectTimeoutMs: 10000
  };
  const profile: SshProxyProfileV1 = {
    schemaVersion: 1, hostId: hostId.trim(), route, updatedAtMs: Date.now()
  };
  if (value.kind === 'http_connect' || value.kind === 'socks5' || value.kind === 'frp_tcp') {
    profile.proxyHost = value.proxyHost;
    profile.proxyPort = validPortText(value.proxyPortText);
  }
  if ((value.kind === 'http_connect' || value.kind === 'socks5') &&
    value.proxyUsername.trim().length > 0) {
    profile.proxyUsername = value.proxyUsername.trim();
  }
  if ((value.kind === 'http_connect' || value.kind === 'socks5') && value.proxyAuthRequired) {
    profile.proxyAuthRequired = true;
  }
  if (value.kind === 'ssh_jump') {
    if (value.hops.length < 1 || value.hops.length > 3) {
      return { valid: false, code: 'E-SSH-PROXY-HOP-LIMIT', message: 'ProxyJump 需要 1-3 跳', profile: null };
    }
    const metadata: SshProxyHopMetadataV1[] = [];
    for (let index: number = 0; index < value.hops.length; index++) {
      const draft: SshProxyHopDraft = value.hops[index];
      const hop: SshJumpHop = {
        host: draft.host, port: validPortText(draft.portText), username: draft.username.trim(),
        authMethod: draft.authMethod, connectTimeoutMs: draft.connectTimeoutMs
      };
      const fingerprint: string = draft.expectedHostKeyFingerprintSha256.trim();
      if (fingerprint.length === 0) {
        return {
          valid: false,
          code: 'E-SSH-PROXY-HOP-HOST-KEY-REQUIRED',
          message: '第 ' + (index + 1).toString() + ' 跳缺少 SHA256 host-key 指纹',
          profile: null
        };
      }
      hop.expectedHostKeyFingerprintSha256 = fingerprint;
      route.hops.push(hop);
      metadata.push({
        hopId: draft.hopId.trim(), label: draft.label.trim(),
        keyId: draft.authMethod === 'publickey' ? draft.keyId.trim() : '',
        hostKeyPolicy: 'strict', position: index
      });
    }
    profile.hopMetadata = metadata;
  }
  const validation: SshProxyProfileValidationResult = validateSshProxyProfile(profile);
  return {
    valid: validation.valid, code: validation.code, message: validation.message,
    profile: validation.profile
  };
}

/** Keep old flat host fields as additive compatibility only; never copy a secret. */
export function applySshProxyProfileToLegacyHost(host: RemoteHost, profile: SshProxyProfileV1): void {
  host.sshProxyType = profile.route.type;
  host.proxyHost = profile.proxyHost || '';
  host.proxyPort = profile.proxyPort || 0;
  host.proxyUsername = profile.proxyUsername || '';
  host.sshProxyPassword = '';
  host.sshProxyPasswordConfigured = false;
  host.sshProxyKeyPassphrase = '';
  host.sshProxyKeyPassphraseConfigured = false;
  host.sshProxyKeyId = '';
  host.sshProxyAuthMethod = 'password';
  if (profile.route.type === 'ssh_jump' && profile.route.hops.length > 0) {
    const hop: SshJumpHop = profile.route.hops[0];
    host.proxyHost = hop.host;
    host.proxyPort = hop.port;
    host.proxyUsername = hop.username;
    host.sshProxyAuthMethod = hop.authMethod;
    host.sshProxyKeyId = profile.hopMetadata === undefined ? '' : profile.hopMetadata[0].keyId;
    host.sshJumpHostKeyFingerprintSha256 = hop.expectedHostKeyFingerprintSha256 || '';
    host.sshJumpHostKeyRawBase64 = hop.expectedHostKeyRawBase64 || '';
  }
}
