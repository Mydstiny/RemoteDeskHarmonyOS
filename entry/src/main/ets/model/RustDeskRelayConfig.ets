/**
 * RustDeskRelayConfig.ets — RustDesk 中继服务器配置
 *
 * 每台设备可配置多组中继服务器, 添加 RustDesk 主机时选择一个绑定。
 * 云同步: rustdeskrelays 表 → 华为云 DISTRIBUTED_CLOUD。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { RustDeskAccount, RustDeskAccountJSON } from './RustDeskAccount';

export interface RustDeskRelayJSON {
  id: string
  userId: string
  idServer: string
  idServerPort: number
  relayServer: string
  relayPort: number
  apiServer: string
  apiUsername: string
  apiPassword: string
  key: string
  healthStatus: string
  healthLatency: number
  healthCheckedAt: number
  apiLoginStatus: string
  accounts: RustDeskAccountJSON[]
  syncVersion: number
  createdAt: number
}

export class RustDeskRelayConfig {
  id: string = '';            // UUID
  userId: string = '';        // 云同步 owner (华为账号 UnionID)
  idServer: string = '';      // ID/Rendezvous 服务器地址
  idServerPort: number = 21116;
  relayServer: string = '';   // Relay 中继服务器地址
  relayPort: number = 21117;
  apiServer: string = '';     // API 服务器 (可选)
  apiUsername: string = '';   // API Admin 用户名
  apiPassword: string = '';   // API Admin 密码
  key: string = '';           // 加密密钥 (可选)
  healthStatus: string = 'unknown';  // unknown|online|offline|error
  healthLatency: number = 0;         // 上次检测延迟(ms)
  healthCheckedAt: number = 0;       // 上次检测时间戳
  apiLoginStatus: string = 'none';   // none|logged_in|expired
  accounts: RustDeskAccount[] = [];  // 该中继下属的 API Admin 账户列表 (JSON序列化)
  syncVersion: number = 0;
  createdAt: number = Date.now();

  /** 外部显示名: 直接用 ID 服务器域名或 IP */
  displayName(): string {
    if (this.idServer !== '') { return this.idServer; }
    return '(未命名中继)';
  }

  /** 验证必填字段 */
  isValid(): boolean {
    return this.idServer.length > 0 && this.relayServer.length > 0;
  }

  toJSON(): RustDeskRelayJSON {
    return {
      id: this.id,
      userId: this.userId,
      idServer: this.idServer,
      idServerPort: this.idServerPort,
      relayServer: this.relayServer,
      relayPort: this.relayPort,
      apiServer: this.apiServer,
      apiUsername: this.apiUsername,
      apiPassword: this.apiPassword,
      key: this.key,
      healthStatus: this.healthStatus,
      healthLatency: this.healthLatency,
      healthCheckedAt: this.healthCheckedAt,
      apiLoginStatus: this.apiLoginStatus,
      accounts: this.accounts.map((account: RustDeskAccount): RustDeskAccountJSON => account.toJSON()),
      syncVersion: this.syncVersion,
      createdAt: this.createdAt
    };
  }

  static fromJSON(json: RustDeskRelayJSON): RustDeskRelayConfig {
    const cfg = new RustDeskRelayConfig();
    if (json.id) { cfg.id = json.id; }
    if (json.userId) { cfg.userId = json.userId; }
    if (json.idServer) { cfg.idServer = json.idServer; }
    if (json.idServerPort) { cfg.idServerPort = json.idServerPort; }
    if (json.relayServer) { cfg.relayServer = json.relayServer; }
    if (json.relayPort) { cfg.relayPort = json.relayPort; }
    if (json.apiServer) { cfg.apiServer = json.apiServer; }
    if (json.apiUsername) { cfg.apiUsername = json.apiUsername; }
    if (json.apiPassword) { cfg.apiPassword = json.apiPassword; }
    if (json.key) { cfg.key = json.key; }
    if (json.healthStatus) { cfg.healthStatus = json.healthStatus; }
    if (json.healthLatency) { cfg.healthLatency = json.healthLatency; }
    if (json.healthCheckedAt) { cfg.healthCheckedAt = json.healthCheckedAt; }
    if (json.apiLoginStatus) { cfg.apiLoginStatus = json.apiLoginStatus; }
    if (json.accounts) {
      cfg.accounts = json.accounts.map((account: RustDeskAccountJSON): RustDeskAccount => RustDeskAccount.fromJSON(account));
    }
    if (json.syncVersion !== undefined) { cfg.syncVersion = json.syncVersion; }
    if (json.createdAt) { cfg.createdAt = json.createdAt; }
    return cfg;
  }

  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(6);
    const hex = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'rdrelay_' + Date.now().toString(36) + '_' + hex;
  }
}
