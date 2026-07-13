/**
 * SshKey.ets — SSH 密钥数据模型
 *
 * 参考 RemoteHost.ets 的 toJSON/fromJSON/generateId 模式。
 * 私钥字段标记为 HUKS 加密存储。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export enum SshKeyType {
  RSA = 0,
  ED25519 = 1,
  ECDSA = 2,
  DSA = 3
}

export interface SshKeyJSON {
  id: string
  userId: string
  label: string
  keyType: number
  publicKey: string
  privateKey: string
  fingerprint: string
  comment: string
  locked: boolean
  lockType: number
  createdAt: number
  syncVersion: number
  formatVersion: number
  privateKeyEncrypted: boolean
}

export class SshKey {
  id: string = '';
  userId: string = '';
  label: string = '';
  keyType: SshKeyType = SshKeyType.ED25519;
  publicKey: string = '';
  privateKey: string = '';   // HUKS AES-256-GCM 加密存储
  fingerprint: string = '';
  comment: string = '';
  locked: boolean = false;
  lockType: number = 0; // LockType enum
  createdAt: number = 0;
  syncVersion: number = 0;
  /** 格式版本: 0=legacy(cryptoFramework DER, 不可导出/安装), 1=OpenSSH标准格式 */
  formatVersion: number = 0;
  /** 私钥是否有 passphrase 加密 */
  privateKeyEncrypted: boolean = false;

  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(8);
    const randomStr = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'sshkey_' + Date.now().toString(36) + '_' + randomStr;
  }

  toJSON(): SshKeyJSON {
    return {
      id: this.id,
      userId: this.userId,
      label: this.label,
      keyType: this.keyType,
      publicKey: this.publicKey,
      privateKey: this.privateKey,
      fingerprint: this.fingerprint,
      comment: this.comment,
      locked: this.locked,
      lockType: this.lockType,
      createdAt: this.createdAt,
      syncVersion: this.syncVersion,
      formatVersion: this.formatVersion,
      privateKeyEncrypted: this.privateKeyEncrypted
    };
  }

  static fromJSON(json: SshKeyJSON): SshKey {
    const key = new SshKey();
    if (json.id) { key.id = json.id; }
    if (json.userId) { key.userId = json.userId; }
    if (json.label) { key.label = json.label; }
    if (json.keyType !== undefined) { key.keyType = json.keyType; }
    if (json.publicKey) { key.publicKey = json.publicKey; }
    if (json.privateKey) { key.privateKey = json.privateKey; }
    if (json.fingerprint) { key.fingerprint = json.fingerprint; }
    if (json.comment) { key.comment = json.comment; }
    if (json.locked !== undefined) { key.locked = json.locked; }
    if (json.lockType !== undefined) { key.lockType = json.lockType; }
    if (json.createdAt) { key.createdAt = json.createdAt; }
    if (json.syncVersion !== undefined) { key.syncVersion = json.syncVersion; }
    if (json.formatVersion !== undefined) { key.formatVersion = json.formatVersion; }
    if (json.privateKeyEncrypted !== undefined) { key.privateKeyEncrypted = json.privateKeyEncrypted; }
    key.normalizeFormatMetadata();
    return key;
  }

  static looksLikeOpenSshPrivateKey(privateKey: string): boolean {
    return privateKey.indexOf('-----BEGIN OPENSSH PRIVATE KEY-----') >= 0 ||
      privateKey.indexOf('-----BEGIN RSA PRIVATE KEY-----') >= 0 ||
      privateKey.indexOf('-----BEGIN EC PRIVATE KEY-----') >= 0 ||
      privateKey.indexOf('-----BEGIN PRIVATE KEY-----') >= 0 ||
      privateKey.indexOf('-----BEGIN ENCRYPTED PRIVATE KEY-----') >= 0;
  }

  static looksLikeOpenSshPublicKey(publicKey: string): boolean {
    return publicKey.indexOf('ssh-ed25519 ') === 0 ||
      publicKey.indexOf('ssh-rsa ') === 0 ||
      publicKey.indexOf('ecdsa-sha2-') === 0;
  }

  normalizeFormatMetadata(): void {
    if (this.formatVersion === 0 &&
        (SshKey.looksLikeOpenSshPrivateKey(this.privateKey) ||
         SshKey.looksLikeOpenSshPublicKey(this.publicKey))) {
      this.formatVersion = 1;
    }
  }

  /** 是否为旧格式 (不可导出/安装) */
  isLegacyFormat(): boolean {
    return this.formatVersion === 0 &&
      !SshKey.looksLikeOpenSshPrivateKey(this.privateKey) &&
      !SshKey.looksLikeOpenSshPublicKey(this.publicKey);
  }

  /** 密钥类型显示名 */
  static typeLabel(kt: SshKeyType): string {
    if (kt === SshKeyType.RSA) { return 'RSA'; }
    if (kt === SshKeyType.ED25519) { return 'ED25519'; }
    if (kt === SshKeyType.ECDSA) { return 'ECDSA'; }
    if (kt === SshKeyType.DSA) { return 'DSA'; }
    return 'Unknown';
  }
}
