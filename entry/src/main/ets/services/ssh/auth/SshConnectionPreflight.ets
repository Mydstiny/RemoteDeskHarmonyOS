import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { ExtensionLoader, SshNativeConnectPromise } from '../../ExtensionLoader';
import { HostSyncService } from '../../HostSyncService';
import { KeyVaultService } from '../../KeyVaultService';
import { ProContinuationCredentialHandoff, ProContinuationSecret } from '../../pro/ProContinuationCredentials';
import { RemoteHost } from '../../../model/RemoteHost';
import { SshProxyProfileStore } from '../../SshProxyProfileStore';
import { resolveSshProxyRuntimePlan, SshProxyRuntimePlan } from '../../SshProxyRuntimePolicy';
import { sshHostKeyRouteBinding, sshHostKeyPinsForRoute } from '../../SshHostKeyTrustPolicy';
import { SshSettingsService } from '../../SshSettingsService';
import { SessionConfig, SshAuthPromptRequest, SshJumpHopHandoff } from '../../../types/rdpnapi';
import { persistSshHostKeyTrust } from './SshHostKeyTrustWriter';
import { SshAuthenticatedHandoff } from './SshAuthenticatedHandoff';
import { SshOperationRouteSecretService } from '../../SshOperationRouteSecretService';

export interface SshPreflightInteraction {
  active: () => boolean;
  secret: (title: string, label: string) => Promise<string>;
  prompt: (request: SshAuthPromptRequest | null) => void;
  cancelled: () => void;
}

/** Owns a detached login while the host list remains visible. No terminal UI is mounted. */
export class SshConnectionPreflight {
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private hosts: HostSyncService = HostSyncService.getInstance();
  private profiles: SshProxyProfileStore = new SshProxyProfileStore();
  private scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
  private hostId: string = '';
  private routeIdentity: string = '';
  private username: string = '';
  private hostOwnerId: string = '';
  private sessionId: number = 0;
  private generation: number = 0;
  private polling: number = -1;
  private live: boolean = false;
  private promptId: number = 0;
  private handledPromptId: number = 0;
  private interaction: SshPreflightInteraction;

  constructor(interaction: SshPreflightInteraction) { this.interaction = interaction; }

  private current(): boolean {
    if (!this.live || !this.interaction.active()) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (scope.ownerScopeId !== this.scope.ownerScopeId || scope.generation !== this.scope.generation ||
      scope.storeIdentity !== this.scope.storeIdentity) { return false; }
    const host = this.hosts.getHost(this.hostId);
    if (host === undefined || host.protocol !== 'ssh' || host.username !== this.username ||
      host.userId !== this.hostOwnerId) { return false; }
    const binding = sshHostKeyRouteBinding(host,
      resolveSshProxyRuntimePlan(host, this.profiles.load(host.id)));
    return binding.ok && binding.identity === this.routeIdentity;
  }

  cancel(): void {
    this.live = false;
    if (this.polling !== -1) { clearInterval(this.polling); this.polling = -1; }
    if (this.sessionId > 0) {
      if (this.promptId > 0) {
        this.loader.cancelSshAuthPrompt(this.sessionId, this.generation, this.promptId);
      }
      this.loader.disconnectSshSession(this.sessionId);
    }
    this.sessionId = 0;
    this.promptId = 0;
    this.interaction.prompt(null);
    this.interaction.cancelled();
  }

  submit(request: SshAuthPromptRequest, responses: string[]): boolean {
    if (!this.current() || request.sessionId !== this.sessionId ||
      request.generation !== this.generation || request.requestId !== this.promptId ||
      responses.length !== request.prompts.length) { this.cancel(); return false; }
    if (request.kind === 'host_key' && !persistSshHostKeyTrust(request, this.hosts, this.profiles)) {
      this.cancel();
      return false;
    }
    const accepted: boolean = this.loader.respondSshAuthPrompt({
      schemaVersion: request.schemaVersion, requestId: request.requestId,
      sessionId: this.sessionId, generation: this.generation, responses, cancelled: false
    });
    if (!accepted) { this.cancel(); return false; }
    this.handledPromptId = request.requestId;
    this.promptId = 0;
    this.interaction.prompt(null);
    return true;
  }

  private poll(): void {
    if (!this.current()) { this.cancel(); return; }
    if (this.sessionId <= 0) { return; }
    const prompt = this.loader.getSshAuthPrompt(this.sessionId, this.generation);
    if (prompt === null || prompt.requestId === this.handledPromptId || prompt.requestId === this.promptId) {
      return;
    }
    this.promptId = prompt.requestId;
    this.interaction.prompt(prompt);
  }

  private async secret(title: string, label: string): Promise<string> {
    const value: string = await this.interaction.secret(title, label);
    if (!this.current() || value.length === 0) { throw new Error('已取消 SSH 鉴权'); }
    return value;
  }

  private async keyPassphrase(key: string, saved: string, label: string): Promise<string> {
    const info = this.loader.inspectSshPrivateKey(key, saved);
    if (info.ok && (!info.encrypted || saved.length > 0)) { return info.encrypted ? saved : ''; }
    const passphrase: string = await this.secret('SSH 私钥认证', label + '的私钥密码');
    if (!this.loader.inspectSshPrivateKey(key, passphrase).ok) {
      throw new Error('私钥密码错误或密钥不可用');
    }
    return passphrase;
  }

  private async jumpHandoffs(host: RemoteHost, plan: SshProxyRuntimePlan): Promise<SshJumpHopHandoff[]> {
    const handoffs: SshJumpHopHandoff[] = [];
    for (let index: number = 0; index < plan.route.hops.length; index++) {
      const hop = plan.route.hops[index];
      const label: string = '第 ' + (index + 1).toString() + ' 跳 ' + hop.username + '@' + hop.host;
      const legacy: boolean = plan.source === 'legacy' && index === 0;
      let password: string = '';
      let key: string = '';
      let passphrase: string = '';
      if (hop.authMethod === 'password') {
        password = legacy ? host.sshProxyPassword : '';
        if (password.length === 0) { password = await this.secret('ProxyJump 认证', label + '的 SSH 密码'); }
      } else if (hop.authMethod === 'publickey') {
        const keyId: string = plan.hopKeyIds[index] || (legacy ? host.sshProxyKeyId : '');
        key = KeyVaultService.getInstance().getSshKey(keyId)?.privateKey || '';
        if (key.length === 0) { throw new Error(label + '的私钥不可用'); }
        passphrase = await this.keyPassphrase(key, legacy ? host.sshProxyKeyPassphrase : '', label);
      }
      // KBI/MFA must be answered live after the native broker issues its challenge.
      handoffs.push({ password, privateKeyPem: key, privateKeyPassphrase: passphrase,
        keyboardInteractiveResponses: [] });
    }
    return handoffs;
  }

  async connect(hostId: string, context: common.Context): Promise<string> {
    this.cancel();
    if (!this.profiles.init(context)) { throw new Error('SSH 连接方式存储不可读'); }
    const host = this.hosts.getHost(hostId);
    if (host === undefined || host.protocol !== 'ssh') { throw new Error('SSH 主机不存在'); }
    const plan = resolveSshProxyRuntimePlan(host, this.profiles.load(host.id));
    const binding = sshHostKeyRouteBinding(host, plan);
    if (!plan.valid || !binding.ok) { throw new Error(plan.message || 'SSH 连接路径无效'); }
    this.scope = AccountSessionCoordinator.getInstance().currentScope();
    this.hostId = host.id;
    this.username = host.username;
    this.hostOwnerId = host.userId;
    this.routeIdentity = binding.identity;
    this.handledPromptId = 0;
    this.live = true;
    this.polling = setInterval((): void => { this.poll(); }, 160);
    let config: SessionConfig | null = null;
    try {
      const resumed: string = SshAuthenticatedHandoff.getInstance().resume(host, plan);
      if (resumed.length > 0) { this.cancel(); return resumed; }
      let key: string = host.sshKeyData;
      if (host.sshKeyId.length > 0) {
        key = KeyVaultService.getInstance().getSshKey(host.sshKeyId)?.privateKey || '';
      }
      let useKey: boolean = host.sshUseKey;
      let storedPassphrase: string = host.sshKeyPassphrase;
      let password: string = host.password;
      // A continuation the source user chose to hand credentials to: this connection only, never stored.
      const handed: ProContinuationSecret | null = ProContinuationCredentialHandoff.getInstance().take(host.id, host.userId);
      if (handed !== null && handed.kind === 'key') {
        useKey = true; key = handed.privateKeyPem; storedPassphrase = handed.passphrase; password = '';
      } else if (handed !== null) {
        useKey = false; password = handed.password;
      }
      if (useKey && key.length === 0) {
        throw new Error('本设备没有这台主机的 SSH 私钥：请在本设备导入密钥，或在源设备的 Pro 功能 > 同账号接续中开启“随接续传输”');
      }
      const passphrase: string = useKey ? await this.keyPassphrase(key, storedPassphrase, '目标主机') : '';
      if (useKey) { password = ''; }
      let proxyPassword: string = '';
      if (plan.proxyAuthRequired && (plan.route.type === 'http_connect' || plan.route.type === 'socks5')) {
        proxyPassword = await this.secret('代理认证', plan.proxyUsername + ' 的代理密码');
      }
      const jumpHandoffs: SshJumpHopHandoff[] = await this.jumpHandoffs(host, plan);
      if (!this.current()) { throw new Error('SSH 主机或账号状态已变化，请重新连接'); }
      const pins = sshHostKeyPinsForRoute(host, plan);
      const settings: SshSettingsService = new SshSettingsService();
      settings.init(context);
      config = {
        protocol: 'ssh', host: host.host, port: host.port, username: host.username, password,
        width: 80, height: 24, customHostname: host.customHostname,
        gatewayHost: '', gatewayPort: 0, domain: '', codec: '', multiMonitor: false,
        monitorCount: 1, colorDepth: 32, authMethod: useKey ? 'publickey' : 'password',
        privateKeyPem: useKey ? key : '', privateKeyPassphrase: passphrase,
        sshLocale: settings.getSshSessionLocale(host.id),
        sshRoute: plan.route, sshJumpHopHandoffs: jumpHandoffs,
        sshProxyType: plan.route.type, sshProxyHost: plan.proxyHost, sshProxyPort: plan.proxyPort,
        sshProxyUsername: plan.proxyUsername, sshProxyPassword: proxyPassword,
        sshProxyAuthMethod: plan.route.type === 'ssh_jump' && plan.route.hops.length > 0
          ? plan.route.hops[0].authMethod : undefined,
        sshProxyPrivateKeyPem: '', sshProxyPrivateKeyPassphrase: '',
        expectedHostKeyRawBase64: pins.rawBase64, expectedHostKeyFingerprintSha256: pins.fingerprintSha256,
        sshHostKeyPromptEnabled: true, sshTrustHostId: host.id, sshHostKeyRouteIdentity: binding.identity,
        sshJumpHostKeyRawBase64: host.sshJumpHostKeyRawBase64,
        sshJumpHostKeyFingerprintSha256: host.sshJumpHostKeyFingerprintSha256
      };
      if (!await this.loader.waitForPendingTeardown() || !this.current()) {
        throw new Error('SSH 连接已取消或上一会话尚未清理');
      }
      const promise: SshNativeConnectPromise = this.loader.connectSshAsync(config, false);
      this.sessionId = promise.sessionId;
      this.generation = promise.generation;
      const result: number = await promise;
      if (!this.current()) {
        if (result > 0) { this.loader.disconnectSshSession(result); }
        throw new Error('SSH 连接已取消');
      }
      if (result <= 0 || result !== this.sessionId) { throw new Error('SSH 鉴权或连接失败（' + result + '）'); }
      const currentHost: RemoteHost | undefined = this.hosts.getHost(host.id);
      if (currentHost === undefined) { throw new Error('SSH 主机已移除'); }
      const currentPlan = resolveSshProxyRuntimePlan(currentHost, this.profiles.load(host.id));
      const token: string = SshAuthenticatedHandoff.getInstance().stage(
        currentHost, currentPlan, this.scope, result, this.generation);
      if (token.length === 0) { throw new Error('SSH 已鉴权会话交接失败'); }
      SshOperationRouteSecretService.getInstance().stage(currentHost, currentPlan, {
        ownerScopeId: this.scope.ownerScopeId, storeIdentity: this.scope.storeIdentity,
        accountGeneration: this.scope.generation
      }, { proxyPassword, jumpHandoffs });
      this.sessionId = 0; // The handoff receipt now owns expiry and cleanup.
      this.cancel();
      return token;
    } catch (error) {
      this.cancel();
      throw new Error(error instanceof Error ? error.message : 'SSH 鉴权失败');
    } finally {
      if (config !== null) {
        config.password = ''; config.privateKeyPem = ''; config.privateKeyPassphrase = '';
        config.sshProxyPassword = '';
        config.sshJumpHopHandoffs?.forEach((hop: SshJumpHopHandoff): void => {
          hop.password = ''; hop.privateKeyPem = ''; hop.privateKeyPassphrase = '';
          hop.keyboardInteractiveResponses = [];
        });
        config.sshJumpHopHandoffs = [];
      }
    }
  }
}
