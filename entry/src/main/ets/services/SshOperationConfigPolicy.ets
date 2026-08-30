import { RemoteHost } from '../model/RemoteHost';
import {
  SessionConfig,
  SshJumpHop,
  SshJumpHopHandoff,
  SshRoute
} from '../types/rdpnapi';
import {
  SshHostKeyPins,
  SshHostKeyRouteBinding,
  sshHostKeyPinsForRoute,
  sshHostKeyRouteBinding
} from './SshHostKeyTrustPolicy';
import {
  SshProxyRuntimePlan,
  sshProxyRuntimeHasStrictJumpBindings
} from './SshProxyRuntimePolicy';

export type SshOperationPurpose = 'probe' | 'key_auth' | 'install';
export type SshJumpHostKeyProbeTrust = 'trust_first' | 'trusted' | 'changed';

export interface SshOperationTargetAuth {
  authMethod: 'password' | 'publickey' | 'kbd-interactive';
  password: string;
  privateKeyPem: string;
  privateKeyPassphrase: string;
  keyboardInteractiveResponses: string[];
}

export interface SshOperationRouteSecrets {
  proxyPassword: string;
  jumpHandoffs: SshJumpHopHandoff[];
}

export class SshOperationConfigResult {
  ok: boolean = false;
  code: string = 'E-SSH-OPERATION-CONFIG';
  message: string = 'SSH 操作配置无效';
  config: SessionConfig | null = null;
}

/** Decide whether a directly probed legacy jump may receive credentials. */
export function classifySshJumpHostKeyProbeTrust(host: RemoteHost,
  rawBase64: string): SshJumpHostKeyProbeTrust {
  const saved: string = host.sshJumpHostKeyRawBase64.trim();
  if (host.sshJumpHostKeyTrustMode !== 1 || saved.length === 0) { return 'trust_first'; }
  return saved === rawBase64.trim() ? 'trusted' : 'changed';
}

function invalid(code: string, message: string): SshOperationConfigResult {
  const result: SshOperationConfigResult = new SshOperationConfigResult();
  result.code = code;
  result.message = message;
  return result;
}

function cloneStringArray(values: string[] | undefined): string[] {
  if (values === undefined) { return []; }
  return values.map((value: string): string => value);
}

function cloneHandoff(value: SshJumpHopHandoff): SshJumpHopHandoff {
  return {
    password: value.password || '',
    privateKeyPem: value.privateKeyPem || '',
    privateKeyPassphrase: value.privateKeyPassphrase || '',
    keyboardInteractiveResponses: cloneStringArray(value.keyboardInteractiveResponses)
  };
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

function routeSecretsError(plan: SshProxyRuntimePlan,
  secrets: SshOperationRouteSecrets): SshOperationConfigResult | null {
  if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
    plan.proxyAuthRequired && secrets.proxyPassword.length === 0) {
    return invalid('E-SSH-OPERATION-PROXY-PASSWORD', '代理认证需要一次性密码');
  }
  if (plan.route.type !== 'ssh_jump') {
    if (secrets.jumpHandoffs.length !== 0) {
      return invalid('E-SSH-OPERATION-HANDOFF-NOT-ALLOWED', '非 ProxyJump 路由不能携带跳板凭据');
    }
    return null;
  }
  if (!sshProxyRuntimeHasStrictJumpBindings(plan)) {
    return invalid('E-SSH-OPERATION-JUMP-HOSTKEY', 'ProxyJump 每一跳都必须先绑定主机指纹');
  }
  if (secrets.jumpHandoffs.length !== plan.route.hops.length) {
    return invalid('E-SSH-OPERATION-HANDOFF-COUNT', 'ProxyJump 凭据必须与每一跳一一对应');
  }
  for (let index: number = 0; index < plan.route.hops.length; index++) {
    const hop: SshJumpHop = plan.route.hops[index];
    const handoff: SshJumpHopHandoff = secrets.jumpHandoffs[index];
    if (hop.authMethod === 'password' && (handoff.password || '').length === 0) {
      return invalid('E-SSH-OPERATION-HOP-PASSWORD',
        '第 ' + (index + 1).toString() + ' 跳缺少 SSH 密码');
    }
    if (hop.authMethod === 'publickey' && (handoff.privateKeyPem || '').length === 0) {
      return invalid('E-SSH-OPERATION-HOP-KEY',
        '第 ' + (index + 1).toString() + ' 跳缺少 SSH 私钥');
    }
    if (hop.authMethod === 'kbd-interactive' &&
      (handoff.keyboardInteractiveResponses || []).length === 0) {
      return invalid('E-SSH-OPERATION-HOP-INTERACTIVE',
        '第 ' + (index + 1).toString() + ' 跳缺少键盘交互响应');
    }
  }
  return null;
}

function targetAuthError(purpose: SshOperationPurpose,
  auth: SshOperationTargetAuth): SshOperationConfigResult | null {
  if (purpose === 'probe') { return null; }
  if (purpose === 'key_auth' && auth.authMethod !== 'publickey') {
    return invalid('E-SSH-OPERATION-TARGET-AUTH', 'SSH 密钥验证只能使用公钥认证');
  }
  if (auth.authMethod === 'password' && auth.password.length === 0) {
    return invalid('E-SSH-OPERATION-TARGET-PASSWORD', '目标 SSH 密码不可用');
  }
  if (auth.authMethod === 'publickey' && auth.privateKeyPem.length === 0) {
    return invalid('E-SSH-OPERATION-TARGET-KEY', '目标 SSH 私钥不可用');
  }
  if (auth.authMethod === 'kbd-interactive' && auth.keyboardInteractiveResponses.length === 0) {
    return invalid('E-SSH-OPERATION-TARGET-INTERACTIVE', '目标 SSH 键盘交互响应不可用');
  }
  return null;
}

/**
 * Build the exact native SessionConfig used by every auxiliary SSH operation.
 * Durable route metadata and one-shot credentials remain separate inputs; no
 * caller is allowed to fall back from a profile route to the legacy/direct path.
 */
export function buildSshOperationSessionConfig(host: RemoteHost,
  plan: SshProxyRuntimePlan, purpose: SshOperationPurpose,
  auth: SshOperationTargetAuth, secrets: SshOperationRouteSecrets):
  SshOperationConfigResult {
  if (host.protocol !== 'ssh' || !plan.valid) {
    return invalid(plan.code || 'E-SSH-OPERATION-ROUTE',
      plan.message || 'SSH 连接路径无效');
  }
  const binding: SshHostKeyRouteBinding = sshHostKeyRouteBinding(host, plan);
  if (!binding.ok) {
    return invalid(binding.code, 'SSH 连接路径无法建立稳定的目标身份');
  }
  const routeError: SshOperationConfigResult | null = routeSecretsError(plan, secrets);
  if (routeError !== null) { return routeError; }
  const authError: SshOperationConfigResult | null = targetAuthError(purpose, auth);
  if (authError !== null) { return authError; }

  const pins: SshHostKeyPins = sshHostKeyPinsForRoute(host, plan);
  if (purpose !== 'probe' && !pins.trusted) {
    return invalid('E-SSH-OPERATION-TARGET-HOSTKEY',
      '目标 SSH 指纹未绑定当前连接路径');
  }
  const jumpHandoffs: SshJumpHopHandoff[] = secrets.jumpHandoffs.map(
    (value: SshJumpHopHandoff): SshJumpHopHandoff => cloneHandoff(value));
  const firstHop: SshJumpHop | null = plan.route.type === 'ssh_jump' &&
    plan.route.hops.length > 0 ? plan.route.hops[0] : null;
  const config: SessionConfig = {
    protocol: 'ssh',
    host: host.host,
    port: host.port,
    username: host.username,
    password: purpose === 'probe' ? '' : auth.password,
    width: 80,
    height: 24,
    customHostname: host.customHostname,
    gatewayHost: '',
    gatewayPort: 0,
    domain: '',
    codec: '',
    multiMonitor: false,
    monitorCount: 1,
    colorDepth: 32,
    authMethod: purpose === 'probe' ? 'password' : auth.authMethod,
    privateKeyPem: purpose === 'probe' ? '' : auth.privateKeyPem,
    privateKeyPassphrase: purpose === 'probe' ? '' : auth.privateKeyPassphrase,
    keyboardInteractiveResponses: purpose === 'probe' ? [] :
      cloneStringArray(auth.keyboardInteractiveResponses),
    sshRoute: cloneRoute(plan.route),
    sshJumpHopHandoffs: jumpHandoffs,
    sshProxyType: plan.route.type,
    sshProxyHost: plan.proxyHost,
    sshProxyPort: plan.proxyPort,
    sshProxyUsername: plan.proxyUsername,
    sshProxyPassword: secrets.proxyPassword,
    sshProxyAuthMethod: firstHop === null ? undefined : firstHop.authMethod,
    sshProxyPrivateKeyPem: '',
    sshProxyPrivateKeyPassphrase: '',
    expectedHostKeyRawBase64: purpose === 'probe' ? '' : pins.rawBase64,
    expectedHostKeyFingerprintSha256: purpose === 'probe' ? '' : pins.fingerprintSha256,
    sshHostKeyPromptEnabled: false,
    sshTrustHostId: host.id,
    sshHostKeyRouteIdentity: binding.identity,
    sshJumpHostKeyRawBase64: firstHop?.expectedHostKeyRawBase64 || '',
    sshJumpHostKeyFingerprintSha256: firstHop?.expectedHostKeyFingerprintSha256 || ''
  };
  const result: SshOperationConfigResult = new SshOperationConfigResult();
  result.ok = true;
  result.code = '';
  result.message = '';
  result.config = config;
  return result;
}

/** Direct one-host probe used only to bootstrap a first legacy jump pin. */
export function buildDirectSshHostKeyProbeConfig(host: string, port: number): SessionConfig {
  return {
    protocol: 'ssh', host, port, username: 'probe', password: '', width: 80, height: 24,
    customHostname: '', gatewayHost: '', gatewayPort: 0, domain: '', codec: '',
    multiMonitor: false, monitorCount: 1, colorDepth: 32, authMethod: 'password',
    privateKeyPem: '', privateKeyPassphrase: '', keyboardInteractiveResponses: [],
    sshRoute: {
      schemaVersion: 1, type: 'direct', endpointHost: host, endpointPort: port,
      hops: [], connectTimeoutMs: 10000
    },
    sshJumpHopHandoffs: [], sshProxyType: 'direct', sshProxyHost: '', sshProxyPort: 0,
    sshProxyUsername: '', sshProxyPassword: '', sshProxyPrivateKeyPem: '',
    sshProxyPrivateKeyPassphrase: '', expectedHostKeyRawBase64: '',
    expectedHostKeyFingerprintSha256: '', sshHostKeyPromptEnabled: false,
    sshTrustHostId: '', sshHostKeyRouteIdentity: '', sshJumpHostKeyRawBase64: '',
    sshJumpHostKeyFingerprintSha256: ''
  };
}
