/**
 * SshPreflightSheet.ets — SSH 连接前置安全校验 Sheet
 *
 * 包含: SshPreflightState 枚举、SshPreflightController 逻辑控制器、
 * SshPreflightView UI 组件
 */
import { RemoteHost } from '../model/RemoteHost';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { KeyVaultService } from '../services/KeyVaultService';
import { SshPreflightService } from '../services/SshPreflightService';
import { HostSyncService } from '../services/HostSyncService';
import { SshHostKeyInfo, SshProxyConfig } from '../types/rdpnapi';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SshPreflight';

/** 前置状态 */
export enum SshPreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  HOST_KEY_CHANGED = 3,
  PASSPHRASE_REQUIRED = 4,
  VERIFYING_PASSPHRASE = 5,
  ERROR = 6
}

/** 提供给调用方的逻辑控制器 */
export class SshPreflightController {
  host: RemoteHost;
  state: SshPreflightState = SshPreflightState.PROBING;
  hostKeyInfo: SshHostKeyInfo | null = null;
  jumpHostKeyInfo: SshHostKeyInfo | null = null;
  error: string = '';
  passphraseInput: string = '';
  passphraseShowPw: boolean = false;
  passphraseSaveToHost: boolean = false;
  private tokenId: string = '';
  private onReadyCallback: (() => void) | null = null;
  private onCancelCallback: (() => void) | null = null;
  private loader: ExtensionLoader;
  private srv: HostSyncService;

  constructor(host: RemoteHost, onReady: () => void, onCancel: () => void) {
    this.host = host;
    this.onReadyCallback = onReady;
    this.onCancelCallback = onCancel;
    this.loader = ExtensionLoader.getInstance();
    this.srv = HostSyncService.getInstance();
  }

  start(): void {
    this.state = SshPreflightState.PROBING;
    this.error = '';
    this.probe();
  }

  private async probe(): Promise<void> {
    try {
      await new Promise<void>((r) => setTimeout(r, 80));
      const info = await this.loader.probeSshHostKeyAsync(
        this.host.host, this.host.port, this.proxyConfig(false));
      if (!info.ok) {
        this.state = SshPreflightState.ERROR;
        this.error = info.errorMessage || '无法读取 SSH 主机指纹';
        return;
      }
      let jumpInfo: SshHostKeyInfo | null = null;
      if (this.usesJump()) {
        jumpInfo = await this.loader.probeSshHostKeyAsync(this.host.proxyHost, this.host.proxyPort);
        if (!jumpInfo.ok) {
          this.state = SshPreflightState.ERROR;
          this.error = '无法读取跳板机 SSH 主机指纹: ' +
            (jumpInfo.errorMessage || '跳板机 KEX 握手失败');
          return;
        }
      }
      this.hostKeyInfo = info;
      this.jumpHostKeyInfo = jumpInfo;
      const targetChanged = this.host.sshHostKeyTrustMode === 1 &&
        this.host.sshHostKeyRawBase64 !== '' && this.host.sshHostKeyRawBase64 !== info.rawBase64;
      const jumpChanged = jumpInfo !== null && this.host.sshJumpHostKeyTrustMode === 1 &&
        this.host.sshJumpHostKeyRawBase64 !== '' &&
        this.host.sshJumpHostKeyRawBase64 !== jumpInfo.rawBase64;
      const targetNeedsTrust = this.host.sshHostKeyTrustMode !== 1 ||
        this.host.sshHostKeyRawBase64 === '' || this.host.sshHostKeyRawBase64 !== info.rawBase64;
      const jumpNeedsTrust = jumpInfo !== null && (this.host.sshJumpHostKeyTrustMode !== 1 ||
        this.host.sshJumpHostKeyRawBase64 === '' || this.host.sshJumpHostKeyRawBase64 !== jumpInfo.rawBase64);
      if (!targetChanged && !jumpChanged && !targetNeedsTrust && !jumpNeedsTrust) {
        this.state = SshPreflightState.TRUSTED_MATCH;
      } else if (targetChanged || jumpChanged) {
        this.state = SshPreflightState.HOST_KEY_CHANGED;
      } else {
        this.state = SshPreflightState.TRUST_FIRST_TIME;
      }
    } catch (err) {
      this.state = SshPreflightState.ERROR;
      this.error = '探测主机指纹异常: ' + JSON.stringify(err);
    }
  }

  retry(): void { this.probe(); }

  trustAndContinue(): void {
    if (!this.hostKeyInfo || (this.usesJump() && !this.jumpHostKeyInfo)) { return; }
    const updated: RemoteHost = this.host.runtimeClone();
    this.applyTrust(updated);
    if (!this.srv.updateHost(updated)) {
      this.state = SshPreflightState.ERROR;
      this.error = 'SSH 指纹验证成功，但信任记录保存失败；连接已停止。';
      return;
    }
    this.host = updated;
    this.checkPassphrase();
  }

  continueAfterMatch(): void { this.checkPassphrase(); }

  async updateTrustAndContinue(): Promise<void> {
    if (!this.hostKeyInfo || (this.usesJump() && !this.jumpHostKeyInfo)) { return; }
    const updated: RemoteHost = this.host.runtimeClone();
    this.applyTrust(updated);
    if (!this.srv.updateHost(updated)) {
      this.state = SshPreflightState.ERROR;
      this.error = 'SSH 新指纹验证成功，但信任记录保存失败；连接已停止。';
      return;
    }
    this.host = updated;
    this.checkPassphrase();
  }

  private usesJump(): boolean {
    return this.host.sshProxyType === 'ssh_jump' && this.host.proxyHost.trim() !== '' &&
      this.host.proxyPort > 0 && this.host.proxyPort <= 65535;
  }

  private proxyConfig(includeExpectedJumpKey: boolean = true): SshProxyConfig {
    let keyData: string = '';
    if (this.host.sshProxyKeyId !== '') {
      const ref = KeyVaultService.getInstance().getSshKey(this.host.sshProxyKeyId);
      if (ref) { keyData = ref.privateKey; }
    }
    return {
      type: this.host.proxyHost.trim() !== '' ? this.host.sshProxyType : 'direct',
      host: this.host.proxyHost,
      port: this.host.proxyPort,
      username: this.host.proxyUsername,
      password: this.host.sshProxyType === 'ssh_jump' ? this.host.sshProxyPassword : '',
      privateKeyPem: this.host.sshProxyType === 'ssh_jump' ? keyData : '',
      privateKeyPassphrase: this.host.sshProxyType === 'ssh_jump' ? this.host.sshProxyKeyPassphrase : '',
      authMethod: this.host.sshProxyType === 'ssh_jump' ? this.host.sshProxyAuthMethod : undefined,
      expectedHostKeyRawBase64: includeExpectedJumpKey && this.host.sshProxyType === 'ssh_jump'
        ? this.host.sshJumpHostKeyRawBase64 : '',
      expectedHostKeyFingerprintSha256: includeExpectedJumpKey && this.host.sshProxyType === 'ssh_jump'
        ? this.host.sshJumpHostKeyFingerprintSha256 : ''
    };
  }

  private applyTrust(host: RemoteHost): void {
    const trustedAt: number = Date.now();
    host.sshHostKeyAlgorithm = this.hostKeyInfo?.algorithm || host.sshHostKeyAlgorithm;
    host.sshHostKeyFingerprintSha256 = this.hostKeyInfo?.fingerprintSha256 ||
      host.sshHostKeyFingerprintSha256;
    host.sshHostKeyRawBase64 = this.hostKeyInfo?.rawBase64 || host.sshHostKeyRawBase64;
    host.sshHostKeyTrustedAt = trustedAt;
    host.sshHostKeyTrustMode = 1;
    if (this.jumpHostKeyInfo) {
      host.sshJumpHostKeyAlgorithm = this.jumpHostKeyInfo.algorithm;
      host.sshJumpHostKeyFingerprintSha256 = this.jumpHostKeyInfo.fingerprintSha256;
      host.sshJumpHostKeyRawBase64 = this.jumpHostKeyInfo.rawBase64;
      host.sshJumpHostKeyTrustedAt = trustedAt;
      host.sshJumpHostKeyTrustMode = 1;
    }
  }

  private checkPassphrase(): void {
    if (!this.host.sshUseKey) { this.ready(); return; }
    let keyData = this.host.sshKeyData;
    if (this.host.sshKeyId !== '') {
      const ref = KeyVaultService.getInstance().getSshKey(this.host.sshKeyId);
      if (ref) { keyData = ref.privateKey; }
    }
    if (keyData.length === 0) { this.ready(); return; }
    const keyInfo = this.loader.inspectSshPrivateKey(keyData, this.host.sshKeyPassphrase);
    if (keyInfo.encrypted && this.host.sshKeyPassphrase === '') {
      this.state = SshPreflightState.PASSPHRASE_REQUIRED;
      this.passphraseInput = '';
      this.passphraseSaveToHost = false;
    } else {
      this.ready();
    }
  }

  async verifyPassphrase(): Promise<void> {
    this.state = SshPreflightState.VERIFYING_PASSPHRASE;
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      let keyData = this.host.sshKeyData;
      if (this.host.sshKeyId !== '') {
        const ref = KeyVaultService.getInstance().getSshKey(this.host.sshKeyId);
        if (ref) { keyData = ref.privateKey; }
      }
      const result = await this.loader.testSshKeyAuthAsync(
        this.host.host, this.host.port, this.host.username,
        keyData, this.passphraseInput, this.proxyConfig()
      );
      if (result.ok) {
        if (this.passphraseSaveToHost) {
          const updated: RemoteHost = this.host.runtimeClone();
          updated.sshKeyPassphrase = this.passphraseInput;
          updated.sshKeyPassphraseConfigured = this.passphraseInput.length > 0;
          if (!this.srv.updateHost(updated)) {
            this.state = SshPreflightState.PASSPHRASE_REQUIRED;
            this.error = '私钥密码验证成功，但保存失败；连接已停止。';
            return;
          }
          this.host = updated;
        }
        this.ready();
      } else {
        this.state = SshPreflightState.PASSPHRASE_REQUIRED;
        this.error = '私钥密码错误或密钥不可用';
        hilog.error(0x0001, TAG, 'passphrase verify failed: ' + result.message);
      }
    } catch (err) {
      this.state = SshPreflightState.PASSPHRASE_REQUIRED;
      this.error = '验证异常: ' + JSON.stringify(err);
    }
  }

  private ready(): void {
    const svc = SshPreflightService.getInstance();
    this.tokenId = svc.createToken({
      hostId: this.host.id,
      expectedHostKeyRawBase64: this.hostKeyInfo?.rawBase64 || this.host.sshHostKeyRawBase64,
      expectedHostKeyFingerprintSha256: this.hostKeyInfo?.fingerprintSha256 || this.host.sshHostKeyFingerprintSha256,
      targetRouteIdentity: this.host.sshHostKeyRouteIdentity,
      expectedJumpHostKeyRawBase64: this.jumpHostKeyInfo?.rawBase64 || this.host.sshJumpHostKeyRawBase64,
      expectedJumpHostKeyFingerprintSha256: this.jumpHostKeyInfo?.fingerprintSha256 ||
        this.host.sshJumpHostKeyFingerprintSha256,
      privateKeyPassphrase: this.passphraseInput || this.host.sshKeyPassphrase,
      proxyPrivateKeyPassphrase: this.host.sshProxyKeyPassphrase
    });
    if (this.onReadyCallback) { this.onReadyCallback(); }
  }

  getTokenId(): string { return this.tokenId; }
  cancel(): void { if (this.onCancelCallback) { this.onCancelCallback(); } }
}
