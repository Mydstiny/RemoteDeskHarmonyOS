import { RemoteHost } from '../model/RemoteHost';
import { SshRoute, SshJumpHop } from '../types/rdpnapi';
import {
  SshLegacyRemoteHostInput,
  SshProxyProfileV1,
  mapLegacyRemoteHostToSshProxyProfile,
  validateSshProxyProfile
} from './SshProxyProfilePolicy';

export type SshProxyRuntimeSource = 'profile' | 'legacy';

export interface SshProxyRuntimePlan {
  valid: boolean;
  code: string;
  message: string;
  source: SshProxyRuntimeSource;
  route: SshRoute;
  proxyHost: string;
  proxyPort: number;
  proxyUsername: string;
  proxyAuthRequired: boolean;
  hopKeyIds: string[];
}

function cloneRoute(route: SshRoute): SshRoute {
  const hops: SshJumpHop[] = route.hops.map((hop: SshJumpHop): SshJumpHop => {
    const result: SshJumpHop = {
      host: hop.host,
      port: hop.port,
      username: hop.username,
      authMethod: hop.authMethod,
      connectTimeoutMs: hop.connectTimeoutMs
    };
    if (hop.expectedHostKeyRawBase64 !== undefined) {
      result.expectedHostKeyRawBase64 = hop.expectedHostKeyRawBase64;
    }
    if (hop.expectedHostKeyFingerprintSha256 !== undefined) {
      result.expectedHostKeyFingerprintSha256 = hop.expectedHostKeyFingerprintSha256;
    }
    return result;
  });
  const result: SshRoute = {
    schemaVersion: route.schemaVersion,
    type: route.type,
    endpointHost: route.endpointHost,
    endpointPort: route.endpointPort,
    hops,
    connectTimeoutMs: route.connectTimeoutMs
  };
  if (route.controlId !== undefined) { result.controlId = route.controlId; }
  return result;
}

function invalidPlan(host: RemoteHost, code: string, message: string,
  source: SshProxyRuntimeSource): SshProxyRuntimePlan {
  return {
    valid: false,
    code,
    message,
    source,
    route: {
      schemaVersion: 1,
      type: 'direct',
      endpointHost: host.host,
      endpointPort: host.port,
      hops: [],
      connectTimeoutMs: 10000
    },
    proxyHost: '',
    proxyPort: 0,
    proxyUsername: '',
    proxyAuthRequired: false,
    hopKeyIds: []
  };
}

/**
 * Resolve one durable route for a terminal connection. A present but stale or
 * invalid profile fails closed instead of silently falling back to legacy
 * flat fields and accidentally changing the network path.
 */
export function resolveSshProxyRuntimePlan(host: RemoteHost,
  storedProfile: SshProxyProfileV1 | null): SshProxyRuntimePlan {
  const source: SshProxyRuntimeSource = storedProfile === null ? 'legacy' : 'profile';
  const legacyInput: SshLegacyRemoteHostInput = {
    id: host.id,
    host: host.host,
    port: host.port,
    sshProxyType: host.sshProxyType,
    proxyHost: host.proxyHost,
    proxyPort: host.proxyPort,
    proxyUsername: host.proxyUsername,
    sshProxyAuthMethod: host.sshProxyAuthMethod,
    sshProxyKeyId: host.sshProxyKeyId,
    sshJumpHostKeyRawBase64: host.sshJumpHostKeyRawBase64,
    sshJumpHostKeyFingerprintSha256: host.sshJumpHostKeyFingerprintSha256
  };
  const candidate: SshProxyProfileV1 | null = storedProfile === null
    ? mapLegacyRemoteHostToSshProxyProfile(legacyInput) : storedProfile;
  if (candidate === null) {
    return invalidPlan(host, 'E-SSH-PROXY-RUNTIME-PROFILE',
      'SSH 连接方式无效，请重新保存主机', source);
  }
  const validation = validateSshProxyProfile(candidate);
  if (!validation.valid || validation.profile === null) {
    return invalidPlan(host, validation.code || 'E-SSH-PROXY-RUNTIME-PROFILE',
      validation.message || 'SSH 连接方式无效', source);
  }
  const profile: SshProxyProfileV1 = validation.profile;
  if (profile.hostId !== host.id || profile.route.endpointHost !== host.host.trim() ||
    profile.route.endpointPort !== host.port) {
    return invalidPlan(host, 'E-SSH-PROXY-RUNTIME-ENDPOINT',
      'SSH 主机地址已变化，请重新保存连接方式', source);
  }
  const hopKeyIds: string[] = profile.hopMetadata === undefined ? [] :
    profile.hopMetadata.map((item): string => item.keyId);
  return {
    valid: true,
    code: '',
    message: '',
    source,
    route: cloneRoute(profile.route),
    proxyHost: profile.proxyHost || '',
    proxyPort: profile.proxyPort || 0,
    proxyUsername: profile.proxyUsername || '',
    proxyAuthRequired: profile.proxyAuthRequired === true,
    hopKeyIds
  };
}

export function sshProxyRuntimeNeedsTerminalSecrets(plan: SshProxyRuntimePlan): boolean {
  if (!plan.valid) { return false; }
  if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
    plan.proxyAuthRequired) { return true; }
  if (plan.route.type !== 'ssh_jump') { return false; }
  for (let index: number = 0; index < plan.route.hops.length; index++) {
    if (plan.route.hops[index].authMethod === 'password' ||
      plan.route.hops[index].authMethod === 'publickey' ||
      plan.route.hops[index].authMethod === 'kbd-interactive') { return true; }
  }
  return false;
}

export function sshProxyRuntimeHasStrictJumpBindings(plan: SshProxyRuntimePlan): boolean {
  if (!plan.valid || plan.route.type !== 'ssh_jump' || plan.route.hops.length === 0) { return false; }
  for (let index: number = 0; index < plan.route.hops.length; index++) {
    const hop: SshJumpHop = plan.route.hops[index];
    if ((hop.expectedHostKeyRawBase64 || '').trim().length === 0 &&
      (hop.expectedHostKeyFingerprintSha256 || '').trim().length === 0) { return false; }
  }
  return true;
}
