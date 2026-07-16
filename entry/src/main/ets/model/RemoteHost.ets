/**
 * RemoteHost.ets — 远程主机数据模型
 *
 * 对应 C++ RemoteHostData 结构体。
 * 支持 JSON 序列化/反序列化，用于本地 Preferences 存储和 CloudDB 云同步。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export enum LockType {
  NONE = 0,
  BIOMETRIC = 1,
  PIN = 2,
  PASSWORD = 3
}

/** 连接排序方式 */
export enum SortOrder {
  CUSTOM = 0,        // 手动排序
  RECENT = 1,        // 最近连接
  NAME_AZ = 2,       // 名称 A-Z
  NAME_ZA = 3,       // 名称 Z-A
  FAVORITES_FIRST = 4 // 收藏优先
}

export interface PresetItem { label: string; width: number; height: number }

export interface DisplayConfigJSON {
  width: number
  height: number
  multiMonitor: boolean
  monitorCount: number
  dynamicResolution: boolean
  colorDepth: number
}

export interface RemoteHostJSON {
  id: string
  userId: string
  label: string
  customHostname: string
  protocol: string
  host: string
  port: number
  username: string
  password: string
  locked: boolean
  lockType: number
  syncVersion: number
  groupId: string
  sortOrder: number
  icon: string
  lastConnected: number
  createdAt: number
  gatewayHost: string
  gatewayPort: number
  displayConfig: DisplayConfigJSON
  lastHealth: number
  lastLatency: number
  sshUseKey: boolean
  sshKeyPath: string
  sshKeyData: string
  sshKeyId: string
  sshKeyPassphrase: string
  sshHostKeyAlgorithm: string
  sshHostKeyFingerprintSha256: string
  sshHostKeyRawBase64: string
  sshHostKeyTrustedAt: number
  sshHostKeyTrustMode: number
  rdpCertificateFingerprintSha256: string
  rdpCertificateSubject: string
  rdpCertificateIssuer: string
  rdpCertificateCommonName: string
  rdpCertificateTrustedAt: number
  rdpCertificateTrustMode: number
  rdpCertificateAllowUntrustedRoot: boolean
  rdpCertificateAllowHostMismatch: boolean
  proxyHost: string
  proxyPort: number
  proxyUsername: string
  rustdeskRelayId: string
  rustdeskAccountId: string
  rustdeskPasswordMode: number
  rustdeskDirectEnabled: boolean
  rustdeskDirectHost: string
  rustdeskDirectPort: number
  rdpCredentialId: string
  sourceType: string
  rustdeskProAccountId: string
  rustdeskProPeerId: string
  rustdeskProPlatform: string
  rustdeskProManaged: boolean
  rustdeskProLastSeenAt: number
  rustdeskProSyncError: string
}

/** 显示器配置 */
export class DisplayConfig {
  width: number = 1920;
  height: number = 1080;
  multiMonitor: boolean = false;
  monitorCount: number = 1;
  dynamicResolution: boolean = true;
  colorDepth: number = 32;    // bits per pixel

  toJSON(): DisplayConfigJSON {
    return {
      width: this.width,
      height: this.height,
      multiMonitor: this.multiMonitor,
      monitorCount: this.monitorCount,
      dynamicResolution: this.dynamicResolution,
      colorDepth: this.colorDepth
    };
  }

  static fromJSON(json: DisplayConfigJSON): DisplayConfig {
    const cfg = new DisplayConfig();
    if (json.width) { cfg.width = json.width; }
    if (json.height) { cfg.height = json.height; }
    if (json.multiMonitor !== undefined) { cfg.multiMonitor = json.multiMonitor; }
    if (json.monitorCount) { cfg.monitorCount = json.monitorCount; }
    if (json.dynamicResolution !== undefined) { cfg.dynamicResolution = json.dynamicResolution; }
    if (json.colorDepth) { cfg.colorDepth = json.colorDepth; }
    return cfg;
  }

  static presets(): Array<PresetItem> {
    return [
      { label: '自动 (自适应)', width: 0, height: 0 },
      { label: 'Full HD (1920×1080)', width: 1920, height: 1080 },
      { label: '2K (2560×1440)', width: 2560, height: 1440 },
      { label: '4K (3840×2160)', width: 3840, height: 2160 },
      { label: 'HD (1366×768)', width: 1366, height: 768 },
      { label: 'HD+ (1600×900)', width: 1600, height: 900 },
      { label: 'UltraWide (3440×1440)', width: 3440, height: 1440 }
    ];
  }
}

/** 连接诊断状态 */
export enum ConnectionHealth {
  UNKNOWN = 0,
  EXCELLENT = 1,  // < 20ms 延迟
  GOOD = 2,       // 20-50ms
  FAIR = 3,       // 50-100ms
  POOR = 4,       // 100-200ms
  BAD = 5         // > 200ms
}

export class RemoteHost {
  id: string = '';             // 主机唯一 ID (UUID)
  userId: string = '';         // 关联的华为账号 UnionID
  label: string = '';          // 主机显示名
  customHostname: string = ''; // 自定义主机名 (RDP /client-hostname:)
  protocol: string = 'rdp';    // 协议类型 ("rdp" | "rustdesk")
  host: string = '';           // IP 或域名
  port: number = 3389;         // 端口号
  username: string = '';       // 登录用户名
  password: string = '';       // 登录密码
  locked: boolean = false;     // 是否已加安全锁
  lockType: LockType = LockType.NONE;
  // SSH 专用字段
  sshUseKey: boolean = false;   // SSH 使用私钥认证
  sshKeyPath: string = '';      // SSH 私钥文件路径
  sshKeyData: string = '';      // SSH 私钥内容 (PEM格式) — 旧式副本, 兼容
  sshKeyId: string = '';        // KeyVault 密钥引用 — 优先, 修改后自动同步
  sshKeyPassphrase: string = ''; // SSH 私钥密码 (E2E加密存储)
  // SSH 主机指纹信任 (T-210)
  sshHostKeyAlgorithm: string = '';          // 算法: "ssh-ed25519" 等
  sshHostKeyFingerprintSha256: string = '';  // 指纹: "SHA256:..."
  sshHostKeyRawBase64: string = '';          // raw key blob base64 (精确比对)
  sshHostKeyTrustedAt: number = 0;           // 信任时间戳 ms
  sshHostKeyTrustMode: number = 0;           // 0=unknown, 1=trusted
  // RDP 证书信任
  rdpCertificateFingerprintSha256: string = '';
  rdpCertificateSubject: string = '';
  rdpCertificateIssuer: string = '';
  rdpCertificateCommonName: string = '';
  rdpCertificateTrustedAt: number = 0;
  rdpCertificateTrustMode: number = 0; // 0=unknown, 1=legacy implicit, 2=explicit trusted
  rdpCertificateAllowUntrustedRoot: boolean = false;
  rdpCertificateAllowHostMismatch: boolean = false;
  proxyHost: string = '';       // SSH 代理/跳板机地址
  proxyPort: number = 22;       // SSH 代理端口
  proxyUsername: string = '';   // SSH 代理用户名
  rustdeskRelayId: string = ''; // RustDesk 中继服务器配置 ID
  rustdeskAccountId: string = ''; // RustDesk API 账户 ID
  rustdeskPasswordMode: number = 0; // RustDesk 密码模式: 0=一次性, 1=永久
  rustdeskDirectEnabled: boolean = false; // 直连模式 (跳过 ID 服务器)
  rustdeskDirectHost: string = ''; // 直连 peer IP 地址
  rustdeskDirectPort: number = 21116; // 直连端口 (默认 21116)
  rdpCredentialId: string = ''; // RDP 绑定的 Windows 凭据 ID
  sourceType: string = 'manual'; // manual | rustdesk_pro
  rustdeskProAccountId: string = ''; // Pro 账号设备端绑定 ID
  rustdeskProPeerId: string = ''; // Pro 地址簿中的稳定 peer ID
  rustdeskProPlatform: string = ''; // Pro 地址簿返回的平台: Windows/Linux/macOS 等
  rustdeskProManaged: boolean = false; // 是否由 Server Pro 地址簿管理
  rustdeskProLastSeenAt: number = 0; // 最近一次地址簿同步看到该 peer 的时间
  rustdeskProSyncError: string = ''; // not_seen 或最近一次同步错误码
  syncVersion: number = 0;     // 同步版本号 (冲突检测)
  groupId: string = '';        // 工作区分组 ID
  sortOrder: number = 0;       // 手动排序序号
  icon: string = '';           // 主机图标 (可选, 资源名)
  lastConnected: number = 0;   // 最后连接时间戳 (ms)
  createdAt: number = Date.now();
  // 🆕 新增字段
  gatewayHost: string = '';    // RDP 网关服务器地址
  gatewayPort: number = 443;   // RDP 网关端口
  displayConfig: DisplayConfig = new DisplayConfig(); // 显示器配置
  lastHealth: ConnectionHealth = ConnectionHealth.UNKNOWN; // 上次连接健康状态
  lastLatency: number = 0;     // 上次连接延迟 (ms)

  /**
   * 验证必填字段
   */
  isValid(): boolean {
    const basic: boolean = this.label.length > 0 &&
           (this.protocol === 'rdp' || this.protocol === 'rustdesk' || this.protocol === 'ssh');
    if (this.protocol === 'rustdesk') {
      // RustDesk: 需要远程ID (customHostname), 不需要host/username
      const hasEndpoint: boolean = this.rustdeskDirectEnabled ?
        this.rustdeskDirectHost.length > 0 && this.host.length > 0 && this.port > 0 && this.port <= 65535 :
        (this.rustdeskRelayId.length > 0 || this.host.length > 0) && this.port > 0 && this.port <= 65535;
      return basic && this.customHostname.length > 0 && hasEndpoint;
    }
    return basic && this.host.length > 0 &&
           (this.username.length > 0 || this.rdpCredentialId.length > 0) &&
           this.port > 0 && this.port <= 65535;
  }

  /**
   * 获取验证错误信息
   */
  getValidationErrors(): string[] {
    const errors: string[] = [];
    if (!this.label) { errors.push('主机名称不能为空'); }
    if (this.protocol === 'rustdesk') {
      if (!this.customHostname) { errors.push('远程ID不能为空'); }
      if (this.rustdeskDirectEnabled) {
        if (!this.rustdeskDirectHost || !this.host) { errors.push('RustDesk 直连地址不能为空'); }
        if (this.port <= 0 || this.port > 65535 || this.rustdeskDirectPort <= 0 || this.rustdeskDirectPort > 65535) {
          errors.push('端口号必须在 1-65535 之间');
        }
      } else if (!this.rustdeskRelayId && !this.host) {
        errors.push('RustDesk 需要选择中继配置或填写直连地址');
      } else if (this.port <= 0 || this.port > 65535) {
        errors.push('端口号必须在 1-65535 之间');
      }
    } else {
      if (!this.host) { errors.push('主机地址不能为空'); }
      if (!this.username && !this.rdpCredentialId) {
        if (this.protocol === 'rdp') {
          errors.push('用户名或 Windows 凭据不能为空');
        } else {
          errors.push('用户名不能为空');
        }
      }
      if (this.port <= 0 || this.port > 65535) { errors.push('端口号必须在 1-65535 之间'); }
    }
    if (this.protocol !== 'rdp' && this.protocol !== 'rustdesk' && this.protocol !== 'ssh') { errors.push('协议类型无效'); }
    if (!this.password && this.rdpCredentialId === '' && !(this.protocol === 'ssh' && this.sshUseKey)) {
      if (this.protocol === 'rdp') {
        errors.push('密码不能为空 (或选择 Windows 凭据)');
      } else if (this.protocol === 'rustdesk') {
        errors.push('密码不能为空 (或使用一次性密码模式)');
      } else {
        errors.push('密码不能为空 (或选择私钥认证)');
      }
    }
    return errors;
  }

  /**
   * 获取协议默认端口
   */
  static getDefaultPort(protocol: string): number {
    if (protocol === 'rustdesk') { return 21116; }
    if (protocol === 'ssh') { return 22; }
    return 3389;
  }

  /**
   * 序列化为 JSON
   */
  toJSON(): RemoteHostJSON {
    return {
      id: this.id,
      userId: this.userId,
      label: this.label,
      customHostname: this.customHostname,
      protocol: this.protocol,
      host: this.host,
      port: this.port,
      username: this.username,
      password: this.password,
      locked: this.locked,
      lockType: this.lockType,
      syncVersion: this.syncVersion,
      groupId: this.groupId,
      sortOrder: this.sortOrder,
      icon: this.icon,
      lastConnected: this.lastConnected,
      createdAt: this.createdAt,
      gatewayHost: this.gatewayHost,
      gatewayPort: this.gatewayPort,
      displayConfig: this.displayConfig.toJSON(),
      lastHealth: this.lastHealth,
      lastLatency: this.lastLatency,
      sshUseKey: this.sshUseKey,
      sshKeyPath: this.sshKeyPath,
      sshKeyData: this.sshKeyData,
      sshKeyId: this.sshKeyId,
      sshKeyPassphrase: this.sshKeyPassphrase,
      sshHostKeyAlgorithm: this.sshHostKeyAlgorithm,
      sshHostKeyFingerprintSha256: this.sshHostKeyFingerprintSha256,
      sshHostKeyRawBase64: this.sshHostKeyRawBase64,
      sshHostKeyTrustedAt: this.sshHostKeyTrustedAt,
      sshHostKeyTrustMode: this.sshHostKeyTrustMode,
      rdpCertificateFingerprintSha256: this.rdpCertificateFingerprintSha256,
      rdpCertificateSubject: this.rdpCertificateSubject,
      rdpCertificateIssuer: this.rdpCertificateIssuer,
      rdpCertificateCommonName: this.rdpCertificateCommonName,
      rdpCertificateTrustedAt: this.rdpCertificateTrustedAt,
      rdpCertificateTrustMode: this.rdpCertificateTrustMode,
      rdpCertificateAllowUntrustedRoot: this.rdpCertificateAllowUntrustedRoot,
      rdpCertificateAllowHostMismatch: this.rdpCertificateAllowHostMismatch,
      proxyHost: this.proxyHost,
      proxyPort: this.proxyPort,
      proxyUsername: this.proxyUsername,
      rustdeskRelayId: this.rustdeskRelayId,
      rustdeskAccountId: this.rustdeskAccountId,
      rustdeskPasswordMode: this.rustdeskPasswordMode,
      rustdeskDirectEnabled: this.rustdeskDirectEnabled,
      rustdeskDirectHost: this.rustdeskDirectHost,
      rustdeskDirectPort: this.rustdeskDirectPort,
      rdpCredentialId: this.rdpCredentialId,
      sourceType: this.sourceType,
      rustdeskProAccountId: this.rustdeskProAccountId,
      rustdeskProPeerId: this.rustdeskProPeerId,
      rustdeskProPlatform: this.rustdeskProPlatform,
      rustdeskProManaged: this.rustdeskProManaged,
      rustdeskProLastSeenAt: this.rustdeskProLastSeenAt,
      rustdeskProSyncError: this.rustdeskProSyncError
    };
  }

  /**
   * 从 JSON 反序列化
   */
  static fromJSON(json: RemoteHostJSON): RemoteHost {
    const host = new RemoteHost();
    if (json.id) { host.id = json.id; }
    if (json.userId) { host.userId = json.userId; }
    if (json.label) { host.label = json.label; }
    if (json.customHostname) { host.customHostname = json.customHostname; }
    if (json.protocol) { host.protocol = json.protocol; }
    if (json.host) { host.host = json.host; }
    if (json.port) { host.port = json.port; }
    if (json.username) { host.username = json.username; }
    if (json.password) { host.password = json.password; }
    if (json.locked !== undefined) { host.locked = json.locked; }
    if (json.lockType !== undefined) { host.lockType = json.lockType; }
    if (json.syncVersion !== undefined) { host.syncVersion = json.syncVersion; }
    if (json.groupId) { host.groupId = json.groupId; }
    if (json.sortOrder !== undefined) { host.sortOrder = json.sortOrder; }
    if (json.icon) { host.icon = json.icon; }
    if (json.lastConnected) { host.lastConnected = json.lastConnected; }
    if (json.createdAt) { host.createdAt = json.createdAt; }
    if (json.gatewayHost) { host.gatewayHost = json.gatewayHost; }
    if (json.gatewayPort) { host.gatewayPort = json.gatewayPort; }
    if (json.displayConfig) {
      host.displayConfig = DisplayConfig.fromJSON(json.displayConfig);
    }
    if (json.lastHealth !== undefined) { host.lastHealth = json.lastHealth; }
    if (json.lastLatency !== undefined) { host.lastLatency = json.lastLatency; }
    if (json.sshUseKey !== undefined) { host.sshUseKey = json.sshUseKey; }
    if (json.sshKeyPath) { host.sshKeyPath = json.sshKeyPath; }
    if (json.sshKeyData) { host.sshKeyData = json.sshKeyData; }
    if (json.sshKeyId) { host.sshKeyId = json.sshKeyId; }
    if (json.sshKeyPassphrase) { host.sshKeyPassphrase = json.sshKeyPassphrase; }
    if (json.sshHostKeyAlgorithm) { host.sshHostKeyAlgorithm = json.sshHostKeyAlgorithm; }
    if (json.sshHostKeyFingerprintSha256) { host.sshHostKeyFingerprintSha256 = json.sshHostKeyFingerprintSha256; }
    if (json.sshHostKeyRawBase64) { host.sshHostKeyRawBase64 = json.sshHostKeyRawBase64; }
    if (json.sshHostKeyTrustedAt !== undefined) { host.sshHostKeyTrustedAt = json.sshHostKeyTrustedAt; }
    if (json.sshHostKeyTrustMode !== undefined) { host.sshHostKeyTrustMode = json.sshHostKeyTrustMode; }
    if (json.rdpCertificateFingerprintSha256) {
      host.rdpCertificateFingerprintSha256 = json.rdpCertificateFingerprintSha256;
    }
    if (json.rdpCertificateSubject) { host.rdpCertificateSubject = json.rdpCertificateSubject; }
    if (json.rdpCertificateIssuer) { host.rdpCertificateIssuer = json.rdpCertificateIssuer; }
    if (json.rdpCertificateCommonName) { host.rdpCertificateCommonName = json.rdpCertificateCommonName; }
    if (json.rdpCertificateTrustedAt !== undefined) { host.rdpCertificateTrustedAt = json.rdpCertificateTrustedAt; }
    if (json.rdpCertificateTrustMode !== undefined) { host.rdpCertificateTrustMode = json.rdpCertificateTrustMode; }
    if (json.rdpCertificateAllowUntrustedRoot !== undefined) {
      host.rdpCertificateAllowUntrustedRoot = json.rdpCertificateAllowUntrustedRoot;
    }
    if (json.rdpCertificateAllowHostMismatch !== undefined) {
      host.rdpCertificateAllowHostMismatch = json.rdpCertificateAllowHostMismatch;
    }
    if (json.proxyHost) { host.proxyHost = json.proxyHost; }
    if (json.proxyPort) { host.proxyPort = json.proxyPort; }
    if (json.proxyUsername) { host.proxyUsername = json.proxyUsername; }
    if (json.rustdeskRelayId) { host.rustdeskRelayId = json.rustdeskRelayId; }
    if (json.rustdeskAccountId) { host.rustdeskAccountId = json.rustdeskAccountId; }
    if (json.rustdeskPasswordMode !== undefined) { host.rustdeskPasswordMode = json.rustdeskPasswordMode; }
    if (json.rustdeskDirectEnabled !== undefined) { host.rustdeskDirectEnabled = json.rustdeskDirectEnabled; }
    if (json.rustdeskDirectHost) { host.rustdeskDirectHost = json.rustdeskDirectHost; }
    if (json.rustdeskDirectPort) { host.rustdeskDirectPort = json.rustdeskDirectPort; }
    if (json.rdpCredentialId) { host.rdpCredentialId = json.rdpCredentialId; }
    if (json.sourceType) { host.sourceType = json.sourceType; }
    if (json.rustdeskProAccountId) { host.rustdeskProAccountId = json.rustdeskProAccountId; }
    if (json.rustdeskProPeerId) { host.rustdeskProPeerId = json.rustdeskProPeerId; }
    if (json.rustdeskProPlatform) { host.rustdeskProPlatform = json.rustdeskProPlatform; }
    if (json.rustdeskProManaged !== undefined) { host.rustdeskProManaged = json.rustdeskProManaged; }
    if (json.rustdeskProLastSeenAt !== undefined) { host.rustdeskProLastSeenAt = json.rustdeskProLastSeenAt; }
    if (json.rustdeskProSyncError) { host.rustdeskProSyncError = json.rustdeskProSyncError; }
    return host;
  }

  /**
   * 生成唯一 ID
   */
  static generateId(): string {
    const rand = cryptoFramework.createRandom();
    const blob = rand.generateRandomSync(8);
    const randomStr = Array.from(new Uint8Array(blob.data))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    return 'host_' + Date.now().toString(36) + '_' + randomStr;
  }
}
