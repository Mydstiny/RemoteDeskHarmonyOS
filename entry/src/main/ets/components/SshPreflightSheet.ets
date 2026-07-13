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
import { CloudStore } from '../services/CloudStore';
import { SshHostKeyInfo } from '../types/rdpnapi';
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
  error: string = '';
  passphraseInput: string = '';
  passphraseShowPw: boolean = false;
  passphraseSaveToHost: boolean = false;
  private tokenId: string = '';
  private onReadyCallback: (() => void) | null = null;
  private onCancelCallback: (() => void) | null = null;
  private loader: ExtensionLoader;
  private srv: CloudStore;

  constructor(host: RemoteHost, onReady: () => void, onCancel: () => void) {
    this.host = host;
    this.onReadyCallback = onReady;
    this.onCancelCallback = onCancel;
    this.loader = ExtensionLoader.getInstance();
    this.srv = CloudStore.getInstance();
  }

  start(): void {
    this.state = SshPreflightState.PROBING;
    this.error = '';
    this.probe();
  }

  private async probe(): Promise<void> {
    try {
      await new Promise<void>((r) => setTimeout(r, 80));
      const info = this.loader.probeSshHostKey(this.host.host, this.host.port);
      if (!info.ok) {
        this.state = SshPreflightState.ERROR;
        this.error = info.errorMessage || '无法读取 SSH 主机指纹';
        return;
      }
      this.hostKeyInfo = info;
      const savedRaw = this.host.sshHostKeyRawBase64;
      const trustMode = this.host.sshHostKeyTrustMode;
      if (trustMode === 1 && savedRaw === info.rawBase64) {
        this.state = SshPreflightState.TRUSTED_MATCH;
      } else if (trustMode === 1 && savedRaw !== '' && savedRaw !== info.rawBase64) {
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
    if (!this.hostKeyInfo) { return; }
    this.host.sshHostKeyAlgorithm = this.hostKeyInfo.algorithm;
    this.host.sshHostKeyFingerprintSha256 = this.hostKeyInfo.fingerprintSha256;
    this.host.sshHostKeyRawBase64 = this.hostKeyInfo.rawBase64;
    this.host.sshHostKeyTrustedAt = Date.now();
    this.host.sshHostKeyTrustMode = 1;
    this.srv.updateHost(this.host);
    this.checkPassphrase();
  }

  continueAfterMatch(): void { this.checkPassphrase(); }

  async updateTrustAndContinue(): Promise<void> {
    if (!this.hostKeyInfo) { return; }
    this.host.sshHostKeyAlgorithm = this.hostKeyInfo.algorithm;
    this.host.sshHostKeyFingerprintSha256 = this.hostKeyInfo.fingerprintSha256;
    this.host.sshHostKeyRawBase64 = this.hostKeyInfo.rawBase64;
    this.host.sshHostKeyTrustedAt = Date.now();
    this.host.sshHostKeyTrustMode = 1;
    this.srv.updateHost(this.host);
    this.checkPassphrase();
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
      const result = this.loader.testSshKeyAuth(
        this.host.host, this.host.port, this.host.username,
        keyData, this.passphraseInput
      );
      if (result.ok) {
        if (this.passphraseSaveToHost) {
          this.host.sshKeyPassphrase = this.passphraseInput;
          this.srv.updateHost(this.host);
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
      privateKeyPassphrase: this.passphraseInput || this.host.sshKeyPassphrase
    });
    if (this.onReadyCallback) { this.onReadyCallback(); }
  }

  getTokenId(): string { return this.tokenId; }
  cancel(): void { if (this.onCancelCallback) { this.onCancelCallback(); } }
}
