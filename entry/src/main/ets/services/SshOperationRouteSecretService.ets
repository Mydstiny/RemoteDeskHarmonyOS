import { RemoteHost } from '../model/RemoteHost';
import { SshJumpHop, SshJumpHopHandoff, SshPrivateKeyInfo } from '../types/rdpnapi';
import { ExtensionLoader } from './ExtensionLoader';
import { KeyVaultService } from './KeyVaultService';
import { SshOperationRouteSecrets } from './SshOperationConfigPolicy';
import { sshHostKeyRouteBinding } from './SshHostKeyTrustPolicy';
import {
  SshProxyRuntimePlan,
  sshProxyRuntimeHasStrictJumpBindings
} from './SshProxyRuntimePolicy';

export const SSH_OPERATION_ROUTE_SECRET_TTL_MS: number = 60 * 1000;

export interface SshOperationRouteSecretScope {
  ownerScopeId: string;
  storeIdentity: string;
  accountGeneration: number;
}

export interface SshOperationRouteSecretBinding extends SshOperationRouteSecretScope {
  hostId: string;
  routeIdentity: string;
}

export interface SshOperationRouteSecretClock {
  now(): number;
}

interface PendingSshOperationRouteSecret {
  binding: SshOperationRouteSecretBinding;
  secrets: SshOperationRouteSecrets;
  createdAtMs: number;
}

class SystemSshOperationRouteSecretClock implements SshOperationRouteSecretClock {
  now(): number { return Date.now(); }
}

function cloneStrings(values: string[] | undefined): string[] {
  return values === undefined ? [] : values.map((value: string): string => value);
}

/** Private keys stay authoritative in KeyVault and are never duplicated in this broker. */
function cloneHandoffForBroker(value: SshJumpHopHandoff): SshJumpHopHandoff {
  return {
    password: value.password || '',
    privateKeyPem: '',
    privateKeyPassphrase: value.privateKeyPassphrase || '',
    keyboardInteractiveResponses: cloneStrings(value.keyboardInteractiveResponses)
  };
}

function cloneSecretsForBroker(value: SshOperationRouteSecrets): SshOperationRouteSecrets {
  return {
    proxyPassword: value.proxyPassword || '',
    jumpHandoffs: value.jumpHandoffs.map(
      (handoff: SshJumpHopHandoff): SshJumpHopHandoff => cloneHandoffForBroker(handoff))
  };
}

function scrubHandoff(value: SshJumpHopHandoff): void {
  value.password = '';
  value.privateKeyPem = '';
  value.privateKeyPassphrase = '';
  if (value.keyboardInteractiveResponses !== undefined) {
    for (let index: number = 0; index < value.keyboardInteractiveResponses.length; index++) {
      value.keyboardInteractiveResponses[index] = '';
    }
    value.keyboardInteractiveResponses = [];
  }
}

function scrubSecrets(value: SshOperationRouteSecrets): void {
  value.proxyPassword = '';
  for (let index: number = 0; index < value.jumpHandoffs.length; index++) {
    scrubHandoff(value.jumpHandoffs[index]);
  }
  value.jumpHandoffs = [];
}

function cloneBinding(value: SshOperationRouteSecretBinding): SshOperationRouteSecretBinding {
  return {
    ownerScopeId: value.ownerScopeId.trim(),
    storeIdentity: value.storeIdentity.trim(),
    accountGeneration: value.accountGeneration,
    hostId: value.hostId.trim(),
    routeIdentity: value.routeIdentity.trim()
  };
}

function bindingIsValid(value: SshOperationRouteSecretBinding): boolean {
  return value.ownerScopeId.trim().length > 0 && value.storeIdentity.trim().length > 0 &&
    value.hostId.trim().length > 0 && value.routeIdentity.trim().length > 0 &&
    Number.isSafeInteger(value.accountGeneration) && value.accountGeneration > 0;
}

function bindingEquals(left: SshOperationRouteSecretBinding,
  right: SshOperationRouteSecretBinding): boolean {
  return left.ownerScopeId === right.ownerScopeId &&
    left.storeIdentity === right.storeIdentity &&
    left.accountGeneration === right.accountGeneration &&
    left.hostId === right.hostId && left.routeIdentity === right.routeIdentity;
}

/**
 * Process-memory-only, account/route-bound, one-shot handoff for auxiliary SSH
 * operations. This class deliberately has no serialization or storage API.
 */
export class SshOperationRouteSecretBroker {
  private pending: PendingSshOperationRouteSecret[] = [];
  private readonly clock: SshOperationRouteSecretClock;

  constructor(clock: SshOperationRouteSecretClock =
    new SystemSshOperationRouteSecretClock()) {
    this.clock = clock;
  }

  put(binding: SshOperationRouteSecretBinding,
    secrets: SshOperationRouteSecrets): boolean {
    const normalized: SshOperationRouteSecretBinding = cloneBinding(binding);
    if (!bindingIsValid(normalized)) { return false; }
    this.cleanup();
    const next: PendingSshOperationRouteSecret[] = [];
    for (let index: number = 0; index < this.pending.length; index++) {
      const item: PendingSshOperationRouteSecret = this.pending[index];
      if (item.binding.ownerScopeId === normalized.ownerScopeId &&
        item.binding.accountGeneration === normalized.accountGeneration &&
        item.binding.hostId === normalized.hostId) {
        scrubSecrets(item.secrets);
      } else {
        next.push(item);
      }
    }
    this.pending = next;
    this.pending.push({
      binding: normalized,
      secrets: cloneSecretsForBroker(secrets),
      createdAtMs: this.clock.now()
    });
    return true;
  }

  take(binding: SshOperationRouteSecretBinding): SshOperationRouteSecrets | null {
    const normalized: SshOperationRouteSecretBinding = cloneBinding(binding);
    if (!bindingIsValid(normalized)) { return null; }
    this.cleanup();
    for (let index: number = 0; index < this.pending.length; index++) {
      const item: PendingSshOperationRouteSecret = this.pending[index];
      if (!bindingEquals(item.binding, normalized)) { continue; }
      this.pending.splice(index, 1);
      const result: SshOperationRouteSecrets = cloneSecretsForBroker(item.secrets);
      scrubSecrets(item.secrets);
      return result;
    }
    return null;
  }

  clear(binding: SshOperationRouteSecretBinding): void {
    const normalized: SshOperationRouteSecretBinding = cloneBinding(binding);
    if (!bindingIsValid(normalized)) { return; }
    const next: PendingSshOperationRouteSecret[] = [];
    for (let index: number = 0; index < this.pending.length; index++) {
      const item: PendingSshOperationRouteSecret = this.pending[index];
      if (bindingEquals(item.binding, normalized)) {
        scrubSecrets(item.secrets);
      } else {
        next.push(item);
      }
    }
    this.pending = next;
  }

  cleanup(): void {
    const nowMs: number = this.clock.now();
    const next: PendingSshOperationRouteSecret[] = [];
    for (let index: number = 0; index < this.pending.length; index++) {
      const item: PendingSshOperationRouteSecret = this.pending[index];
      if (!Number.isSafeInteger(item.createdAtMs) || item.createdAtMs < 0 ||
        nowMs < item.createdAtMs ||
        nowMs - item.createdAtMs > SSH_OPERATION_ROUTE_SECRET_TTL_MS) {
        scrubSecrets(item.secrets);
      } else {
        next.push(item);
      }
    }
    this.pending = next;
  }

  clearAll(): void {
    for (let index: number = 0; index < this.pending.length; index++) {
      scrubSecrets(this.pending[index].secrets);
    }
    this.pending = [];
  }
}

export class SshOperationRouteSecretResult {
  ok: boolean = false;
  code: string = 'E-SSH-OPERATION-ROUTE-SECRETS';
  message: string = 'SSH 连接路径凭据不可用';
  secrets: SshOperationRouteSecrets = { proxyPassword: '', jumpHandoffs: [] };
}

function failure(code: string, message: string): SshOperationRouteSecretResult {
  const result: SshOperationRouteSecretResult = new SshOperationRouteSecretResult();
  result.code = code;
  result.message = message;
  return result;
}

function routeNeedsTransientSecrets(plan: SshProxyRuntimePlan): boolean {
  if (!plan.valid || plan.source !== 'profile') { return false; }
  if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
    plan.proxyAuthRequired) { return true; }
  return plan.route.type === 'ssh_jump' && plan.route.hops.length > 0;
}

function stagedSecretsMatchPlan(plan: SshProxyRuntimePlan,
  secrets: SshOperationRouteSecrets): boolean {
  if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
    plan.proxyAuthRequired) {
    return secrets.proxyPassword.length > 0;
  }
  if (plan.route.type !== 'ssh_jump' ||
    secrets.jumpHandoffs.length !== plan.route.hops.length) { return false; }
  for (let index: number = 0; index < plan.route.hops.length; index++) {
    const hop: SshJumpHop = plan.route.hops[index];
    const handoff: SshJumpHopHandoff = secrets.jumpHandoffs[index];
    if (hop.authMethod === 'password' && (handoff.password || '').length === 0) { return false; }
    if (hop.authMethod === 'kbd-interactive' &&
      (handoff.keyboardInteractiveResponses || []).length === 0) { return false; }
  }
  return true;
}

/** Resolve credentials that are already available in device-local memory. */
export class SshOperationRouteSecretService {
  private static instance: SshOperationRouteSecretService;
  private readonly loader: ExtensionLoader = ExtensionLoader.getInstance();
  private readonly keys: KeyVaultService = KeyVaultService.getInstance();
  private readonly broker: SshOperationRouteSecretBroker =
    new SshOperationRouteSecretBroker();

  static getInstance(): SshOperationRouteSecretService {
    if (!SshOperationRouteSecretService.instance) {
      SshOperationRouteSecretService.instance = new SshOperationRouteSecretService();
    }
    return SshOperationRouteSecretService.instance;
  }

  stage(host: RemoteHost, plan: SshProxyRuntimePlan,
    scope: SshOperationRouteSecretScope,
    secrets: SshOperationRouteSecrets): boolean {
    if (!routeNeedsTransientSecrets(plan) || !stagedSecretsMatchPlan(plan, secrets)) {
      return false;
    }
    const binding: SshOperationRouteSecretBinding | null =
      this.binding(host, plan, scope);
    return binding !== null && this.broker.put(binding, secrets);
  }

  clear(host: RemoteHost, plan: SshProxyRuntimePlan,
    scope: SshOperationRouteSecretScope): void {
    const binding: SshOperationRouteSecretBinding | null =
      this.binding(host, plan, scope);
    if (binding !== null) { this.broker.clear(binding); }
  }

  clearAll(): void { this.broker.clearAll(); }

  resolve(host: RemoteHost, plan: SshProxyRuntimePlan,
    legacyProxyPassphrase: string = '',
    scope?: SshOperationRouteSecretScope): SshOperationRouteSecretResult {
    if (!plan.valid) {
      return failure(plan.code || 'E-SSH-OPERATION-ROUTE',
        plan.message || 'SSH 连接路径无效');
    }
    let staged: SshOperationRouteSecrets | null = null;
    if (routeNeedsTransientSecrets(plan) && scope !== undefined) {
      const binding: SshOperationRouteSecretBinding | null =
        this.binding(host, plan, scope);
      if (binding !== null) { staged = this.broker.take(binding); }
    }
    let proxyPassword: string = '';
    if ((plan.route.type === 'http_connect' || plan.route.type === 'socks5') &&
      plan.proxyAuthRequired) {
      proxyPassword = plan.source === 'legacy' ? host.sshProxyPassword :
        (staged === null ? '' : staged.proxyPassword);
      if (proxyPassword.length === 0) {
        if (staged !== null) { scrubSecrets(staged); }
        return failure('E-SSH-OPERATION-PROXY-PASSWORD',
          '该连接路径需要一次性代理密码');
      }
    }
    if (plan.route.type !== 'ssh_jump') {
      if (staged !== null) { scrubSecrets(staged); }
      return this.success(proxyPassword, []);
    }
    if (!sshProxyRuntimeHasStrictJumpBindings(plan)) {
      if (staged !== null) { scrubSecrets(staged); }
      return failure('E-SSH-OPERATION-JUMP-HOSTKEY',
        'ProxyJump 每一跳都必须先绑定主机指纹');
    }
    if (plan.source === 'profile' && (staged === null ||
      staged.jumpHandoffs.length !== plan.route.hops.length)) {
      if (staged !== null) { scrubSecrets(staged); }
      return failure('E-SSH-OPERATION-HOP-SECRETS',
        'ProxyJump 一次性逐跳凭据不可用');
    }
    const handoffs: SshJumpHopHandoff[] = [];
    for (let index: number = 0; index < plan.route.hops.length; index++) {
      const hop: SshJumpHop = plan.route.hops[index];
      const prefix: string = '第 ' + (index + 1).toString() + ' 跳';
      const stagedHandoff: SshJumpHopHandoff | null = staged === null ? null :
        staged.jumpHandoffs[index];
      if (hop.authMethod === 'password') {
        const password: string = plan.source === 'legacy' && index === 0 ?
          host.sshProxyPassword : (stagedHandoff === null ? '' : (stagedHandoff.password || ''));
        if (password.length === 0) {
          if (staged !== null) { scrubSecrets(staged); }
          return failure('E-SSH-OPERATION-HOP-PASSWORD', prefix + '需要一次性 SSH 密码');
        }
        handoffs.push({ password, privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: [] });
        continue;
      }
      if (hop.authMethod === 'kbd-interactive') {
        const responses: string[] = plan.source === 'legacy' && index === 0 ?
          (host.sshProxyPassword.length === 0 ? [] : [host.sshProxyPassword]) :
          (stagedHandoff === null ? [] :
            cloneStrings(stagedHandoff.keyboardInteractiveResponses));
        if (responses.length === 0) {
          if (staged !== null) { scrubSecrets(staged); }
          return failure('E-SSH-OPERATION-HOP-INTERACTIVE',
            prefix + '需要一次性键盘交互响应');
        }
        handoffs.push({ password: '', privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: responses });
        continue;
      }
      const keyId: string = index < plan.hopKeyIds.length ? plan.hopKeyIds[index] : '';
      const key = this.keys.getSshKey(keyId);
      if (key === undefined || key.privateKey.length === 0) {
        if (staged !== null) { scrubSecrets(staged); }
        return failure('E-SSH-OPERATION-HOP-KEY', prefix + '私钥不可用');
      }
      let passphrase: string = plan.source === 'legacy' && index === 0 ?
        (legacyProxyPassphrase || host.sshProxyKeyPassphrase) :
        (stagedHandoff === null ? '' : (stagedHandoff.privateKeyPassphrase || ''));
      const info: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
        key.privateKey, passphrase);
      if (!info.ok) {
        if (staged !== null) { scrubSecrets(staged); }
        return failure('E-SSH-OPERATION-HOP-PASSPHRASE',
          prefix + '私钥密码不可用');
      }
      if (!info.encrypted) { passphrase = ''; }
      handoffs.push({ password: '', privateKeyPem: key.privateKey,
        privateKeyPassphrase: passphrase, keyboardInteractiveResponses: [] });
    }
    if (staged !== null) { scrubSecrets(staged); }
    return this.success(proxyPassword, handoffs);
  }

  private binding(host: RemoteHost, plan: SshProxyRuntimePlan,
    scope: SshOperationRouteSecretScope): SshOperationRouteSecretBinding | null {
    const ownerScopeId: string = scope.ownerScopeId.trim();
    const storeIdentity: string = scope.storeIdentity.trim();
    if (host.protocol !== 'ssh' || host.id.trim().length === 0 ||
      host.userId.trim().length === 0 || host.userId.trim() !== ownerScopeId ||
      storeIdentity.length === 0 || !Number.isSafeInteger(scope.accountGeneration) ||
      scope.accountGeneration <= 0) { return null; }
    const route = sshHostKeyRouteBinding(host, plan);
    if (!route.ok || route.identity.trim().length === 0) { return null; }
    const binding: SshOperationRouteSecretBinding = {
      ownerScopeId,
      storeIdentity,
      accountGeneration: scope.accountGeneration,
      hostId: host.id.trim(),
      routeIdentity: route.identity.trim()
    };
    return bindingIsValid(binding) ? binding : null;
  }

  private success(proxyPassword: string,
    jumpHandoffs: SshJumpHopHandoff[]): SshOperationRouteSecretResult {
    const result: SshOperationRouteSecretResult = new SshOperationRouteSecretResult();
    result.ok = true;
    result.code = '';
    result.message = '';
    result.secrets = { proxyPassword, jumpHandoffs };
    return result;
  }
}
