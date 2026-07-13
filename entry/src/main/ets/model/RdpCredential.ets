/**
 * RdpCredential.ets — Windows/RDP 登录凭据
 *
 * 主机只绑定凭据 ID, 连接时再取出用户名/密码。个人 Microsoft 账户邮箱默认
 * 规范化为 MicrosoftAccount 域；企业/学校账号可走 AzureAD 格式。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface RdpCredentialJSON {
  id: string
  label: string
  username: string
  password: string
  createdAt: number
}

export class RdpCredential {
  id: string = '';
  label: string = '';
  username: string = '';
  password: string = '';
  createdAt: number = Date.now();

  displayName(): string {
    if (this.label !== '') { return this.label; }
    return this.username !== '' ? this.username : '(未命名凭据)';
  }

  toJSON(): RdpCredentialJSON {
    return {
      id: this.id,
      label: this.label,
      username: this.username,
      password: this.password,
      createdAt: this.createdAt
    };
  }

  static fromJSON(json: RdpCredentialJSON): RdpCredential {
    const c = new RdpCredential();
    if (json.id) { c.id = json.id; }
    c.label = json.label || '';
    c.username = json.username || '';
    c.password = json.password || '';
    c.createdAt = json.createdAt || Date.now();
    return c;
  }

  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(6);
    const hex = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'rdpcred_' + Date.now().toString(36) + '_' + hex;
  }
}
