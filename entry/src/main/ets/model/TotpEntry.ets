/**
 * TotpEntry.ets — TOTP 2FA 验证器条目数据模型
 *
 * 参考 RemoteHost.ets 的 toJSON/fromJSON/generateId 模式。
 * secret 字段标记为 HUKS 加密存储。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export enum TotpAlgorithm {
  SHA1 = 0,
  SHA256 = 1,
  SHA512 = 2
}

export interface TotpCode {
  code: string;       // 当前验证码, 如 "123456"
  remaining: number;  // 剩余秒数
  total: number;      // 总周期秒数 (30 或 60)
  progress: number;   // 进度 0.0 ~ 1.0
}

export interface TotpEntryJSON {
  id: string
  userId: string
  issuer: string
  account: string
  secret: string
  algorithm: number
  digits: number
  period: number
  iconUrl: string
  locked: boolean
  lockType: number
  createdAt: number
  syncVersion: number
}

export class TotpEntry {
  id: string = '';
  userId: string = '';
  issuer: string = '';       // 发行方, 如 "GitHub"
  account: string = '';      // 账户名, 如 "user@example.com"
  secret: string = '';       // Base32 密钥 (HUKS 加密存储)
  algorithm: TotpAlgorithm = TotpAlgorithm.SHA1;
  digits: number = 6;        // 验证码位数 (6 或 8)
  period: number = 30;       // 时间间隔秒数 (30 或 60)
  iconUrl: string = '';
  locked: boolean = false;
  lockType: number = 0;
  createdAt: number = 0;
  syncVersion: number = 0;

  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(8);
    const randomStr = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'totp_' + Date.now().toString(36) + '_' + randomStr;
  }

  toJSON(): TotpEntryJSON {
    return {
      id: this.id,
      userId: this.userId,
      issuer: this.issuer,
      account: this.account,
      secret: this.secret,
      algorithm: this.algorithm,
      digits: this.digits,
      period: this.period,
      iconUrl: this.iconUrl,
      locked: this.locked,
      lockType: this.lockType,
      createdAt: this.createdAt,
      syncVersion: this.syncVersion
    };
  }

  static fromJSON(json: TotpEntryJSON): TotpEntry {
    const entry = new TotpEntry();
    if (json.id) { entry.id = json.id; }
    if (json.userId) { entry.userId = json.userId; }
    if (json.issuer) { entry.issuer = json.issuer; }
    if (json.account) { entry.account = json.account; }
    if (json.secret) { entry.secret = json.secret; }
    if (json.algorithm !== undefined) { entry.algorithm = json.algorithm; }
    if (json.digits) { entry.digits = json.digits; }
    if (json.period) { entry.period = json.period; }
    if (json.iconUrl) { entry.iconUrl = json.iconUrl; }
    if (json.locked !== undefined) { entry.locked = json.locked; }
    if (json.lockType !== undefined) { entry.lockType = json.lockType; }
    if (json.createdAt) { entry.createdAt = json.createdAt; }
    if (json.syncVersion !== undefined) { entry.syncVersion = json.syncVersion; }
    return entry;
  }

  /** 算法显示名 */
  static algoLabel(a: TotpAlgorithm): string {
    if (a === TotpAlgorithm.SHA1) { return 'SHA1'; }
    if (a === TotpAlgorithm.SHA256) { return 'SHA256'; }
    if (a === TotpAlgorithm.SHA512) { return 'SHA512'; }
    return 'SHA1';
  }

  /** 显示标签: issuer (account) 或仅 issuer */
  displayLabel(): string {
    if (this.account !== '') {
      return this.issuer + " (" + this.account + ")";
    }
    return this.issuer;
  }
}
