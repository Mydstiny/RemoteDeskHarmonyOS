/**
 * RustDeskAccount.ets — RustDesk API Admin 账户 (中继服务器下属)
 *
 * 每个中继服务器可配置多个 API Admin 账户, 互相隔离。
 * 主机绑定: RemoteHost → rustdeskRelayId + rustdeskAccountId 二级锁定。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface RustDeskAccountJSON {
  id: string
  relayId: string
  username: string
  password: string
  loginStatus: string
  lastLoginAt: number
  createdAt: number
}

export class RustDeskAccount {
  id: string = '';               // UUID
  relayId: string = '';          // 所属中继配置 ID
  username: string = '';         // API Admin 用户名
  password: string = '';         // API Admin 密码 (加密存储)
  loginStatus: string = 'none';  // none|logged_in|expired
  lastLoginAt: number = 0;
  createdAt: number = Date.now();

  displayName(): string {
    return this.username !== '' ? this.username : '(未命名账户)';
  }

  toJSON(): RustDeskAccountJSON {
    return {
      id: this.id, relayId: this.relayId, username: this.username,
      password: this.password, loginStatus: this.loginStatus,
      lastLoginAt: this.lastLoginAt, createdAt: this.createdAt
    };
  }

  static fromJSON(json: RustDeskAccountJSON): RustDeskAccount {
    const a = new RustDeskAccount();
    if (json.id) { a.id = json.id; }
    a.relayId = json.relayId || '';
    a.username = json.username || '';
    a.password = json.password || '';
    a.loginStatus = json.loginStatus || 'none';
    a.lastLoginAt = json.lastLoginAt || 0;
    a.createdAt = json.createdAt || 0;
    return a;
  }

  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(6);
    const hex = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'rdacct_' + Date.now().toString(36) + '_' + hex;
  }
}
