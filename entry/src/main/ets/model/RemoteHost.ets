/**
 * RemoteHost.ets — 远程主机数据模型
 *
 * 对应 C++ RemoteHostData 结构体。
 * 支持 JSON 序列化/反序列化，用于本地 Preferences 存储和 CloudDB 云同步。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  LanHostAddressMode,
  LanHostAddressView,
  normalizeLanHostAddressMode
} from '../services/LanHostAddressPolicy';

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

export type RdpAuthMode = 'password' | 'blank_password' | 'restricted_admin';
/** Restricted Admin always requires the user's real NTLM password hash. */
export type RdpRestrictedAdminSecretSource = 'ntlm_hash';
export type RdpEndpointMode = 'direct_rdp' | 'transparent_tcp_rdp' |
  'microsoft_rd_gateway' | 'vendor_https_bastion' | 'azure_bastion' | 'unknown_gateway';
export type RdpGatewayTransport = 'auto' | 'http' | 'rpc' | 'websocket' | 'no-websockets';
export type SshProxyType = 'direct' | 'http_connect' | 'socks5' | 'frp_tcp' |
  'frp_visitor' | 'frp_stcp' | 'frp_sudp' | 'frp_xtcp' | 'ssh_jump' | 'legacy_gateway';
export type SshProxyAuthMethod = 'password' | 'publickey' | 'kbd-interactive';

export function normalizeRdpAuthMode(value: string | undefined): RdpAuthMode {
  if (value === 'blank_password' || value === 'restricted_admin') { return value; }
  return 'password';
}

export function normalizeRdpRestrictedAdminSecretSource(
  _value: string | undefined
): RdpRestrictedAdminSecretSource {
  // Older builds exposed an "empty password hash" option and derived the
  // well-known NT hash for an empty password.  That is not a generic
  // Restricted Admin credential: it is only correct for the exact empty
  // password account, while Restricted Admin itself requires the supplied
  // account hash.  Normalize every legacy/unknown value to the only safe
  // source and let the local-secret lookup require the user to enter it.
  return 'ntlm_hash';
}

export interface RdpEffectiveIdentity {
  username: string;
  domain: string;
}

/**
 * Produces the username/domain pair sent to FreeRDP.
 *
 * Keep this in the model layer so the local Restricted Admin secret binding
 * uses exactly the same identity that the native adapter authenticates with.
 */
export function normalizeRdpCredentialParts(rawValue: string, authIdentityMode: number): RdpEffectiveIdentity {
  const rawUsername: string = rawValue.trim();
  const slashIndex: number = rawUsername.indexOf('\\');

  if (authIdentityMode === 3 || authIdentityMode === 4) {
    let emailUsername: string = rawUsername;
    if (rawUsername.startsWith('.\\AzureAD\\')) {
      emailUsername = rawUsername.substring('.\\AzureAD\\'.length);
    } else if (rawUsername.startsWith('\\AzureAD\\')) {
      emailUsername = rawUsername.substring('\\AzureAD\\'.length);
    } else if (rawUsername.startsWith('AzureAD\\')) {
      emailUsername = rawUsername.substring('AzureAD\\'.length);
    }
    return authIdentityMode === 3
      ? { username: 'AzureAD\\' + emailUsername, domain: '.' }
      : { username: emailUsername, domain: 'AzureAD' };
  }

  if (rawUsername.startsWith('.\\AzureAD\\') || rawUsername.startsWith('\\AzureAD\\') ||
    rawUsername.startsWith('AzureAD\\')) {
    let azureUsername: string = rawUsername;
    if (rawUsername.startsWith('.\\AzureAD\\')) {
      azureUsername = rawUsername.substring('.\\'.length);
    } else if (rawUsername.startsWith('\\AzureAD\\')) {
      azureUsername = rawUsername.substring('\\'.length);
    }
    return { username: azureUsername, domain: '.' };
  }

  if (slashIndex > 0 && slashIndex < rawUsername.length - 1 &&
    !rawUsername.startsWith('MicrosoftAccount\\')) {
    return {
      username: rawUsername.substring(slashIndex + 1),
      domain: rawUsername.substring(0, slashIndex)
    };
  }

  if (rawUsername.startsWith('MicrosoftAccount\\') || rawUsername.indexOf('@') > 0) {
    let emailUsername: string = rawUsername;
    if (rawUsername.startsWith('MicrosoftAccount\\')) {
      emailUsername = rawUsername.substring('MicrosoftAccount\\'.length);
    }
    if (authIdentityMode === 1) {
      return { username: emailUsername, domain: 'MicrosoftAccount' };
    }
    if (authIdentityMode === 2) {
      return { username: emailUsername, domain: '' };
    }
    return { username: 'MicrosoftAccount\\' + emailUsername, domain: '' };
  }

  return { username: rawUsername, domain: '' };
}

/** Normalizes a pasted NTLM hash and returns an empty string for invalid input. */
export function normalizeRdpNtlmHash(value: string): string {
  const normalized: string = value.replace(/\s/g, '').toUpperCase();
  return /^[0-9A-F]{32}$/.test(normalized) ? normalized : '';
}

export function normalizeRdpEndpointMode(value: string | undefined, gatewayHost: string = ''): RdpEndpointMode {
  if (value === 'transparent_tcp_rdp' || value === 'microsoft_rd_gateway' ||
    value === 'vendor_https_bastion' || value === 'azure_bastion' || value === 'unknown_gateway') {
    return value;
  }
  return gatewayHost.trim() !== '' ? 'microsoft_rd_gateway' : 'direct_rdp';
}

export function normalizeRdpGatewayTransport(value: string | undefined): RdpGatewayTransport {
  if (value === 'http' || value === 'rpc' || value === 'websocket' || value === 'no-websockets') {
    return value;
  }
  return 'auto';
}

export function rdpRouteIdentityForValues(
  endpointMode: string | undefined,
  targetHost: string,
  targetPort: number,
  targetServerName: string,
  gatewayHost: string,
  gatewayPort: number,
  gatewayServerName: string,
  gatewayTransport: string | undefined
): string {
  const mode: RdpEndpointMode = normalizeRdpEndpointMode(endpointMode, gatewayHost);
  const targetName: string = targetServerName.trim() !== '' ? targetServerName : targetHost;
  const gatewayName: string = gatewayServerName.trim() !== '' ? gatewayServerName : gatewayHost;
  const transport: RdpGatewayTransport = normalizeRdpGatewayTransport(gatewayTransport);
  return mode + '|target=' + targetHost + ':' + targetPort.toString() + ':' + targetName +
    '|gateway=' + gatewayHost + ':' + gatewayPort.toString() + ':' + gatewayName +
    '|transport=' + transport;
}

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
  rdpEndpointMode?: string
  rdpGatewayTransport?: string
  rdpGatewayServerName?: string
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
  sshJumpHostKeyAlgorithm: string
  sshJumpHostKeyFingerprintSha256: string
  sshJumpHostKeyRawBase64: string
  sshJumpHostKeyTrustedAt: number
  sshJumpHostKeyTrustMode: number
  rdpCertificateFingerprintSha256: string
  rdpCertificateSubject: string
  rdpCertificateIssuer: string
  rdpCertificateCommonName: string
  rdpCertificateNotBeforeMs: number
  rdpCertificateNotAfterMs: number
  rdpCertificateTrustedAt: number
  rdpCertificateTrustMode: number
  rdpCertificateAllowUntrustedRoot: boolean
  rdpCertificateAllowHostMismatch: boolean
  rdpCertificateRouteIdentity?: string
  rdpGatewayCertificateFingerprintSha256?: string
  rdpGatewayCertificateSubject?: string
  rdpGatewayCertificateIssuer?: string
  rdpGatewayCertificateCommonName?: string
  rdpGatewayCertificateNotBeforeMs?: number
  rdpGatewayCertificateNotAfterMs?: number
  rdpGatewayCertificateTrustedAt?: number
  rdpGatewayCertificateTrustMode?: number
  rdpGatewayCertificateAllowUntrustedRoot?: boolean
  rdpGatewayCertificateAllowHostMismatch?: boolean
  rdpGatewayCertificateRouteIdentity?: string
  proxyHost: string
  proxyPort: number
  proxyUsername: string
  sshProxyType?: string
  sshProxyAuthMethod?: string
  sshProxyKeyId?: string
  sshProxyPassword?: string
  sshProxyKeyPassphrase?: string
  rustdeskRelayId: string
  rustdeskAccountId: string
  rustdeskPasswordMode: number
  rustdeskAuthMode?: string
  rustdeskDirectEnabled: boolean
  rustdeskDirectHost: string
  rustdeskDirectPort: number
  rustdeskTargetDevice?: string
  rustdeskAdaptiveOrientation?: boolean
  /** Legacy read-only migration input. New serializations omit these fields. */
  rustdeskTotpEntryId?: string
  rustdeskTotpAutoSubmit?: boolean | string
  rustdeskTotpDeviceId?: string
  rdpCredentialId: string
  rdpAuthMode?: string
  rdpRestrictedAdminSecretSource?: string
  sourceType: string
  rustdeskProAccountId: string
  rustdeskProPeerId: string
  rustdeskProPlatform: string
  rustdeskProManaged: boolean
  rustdeskProLastSeenAt: number
  rustdeskProSyncError: string
  lanAddressMode?: string
  lanDiscoveryIdentity?: string
  lanLastResolvedAt?: number
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

export class RemoteHost implements LanHostAddressView {
  id: string = '';             // 主机唯一 ID (UUID)
  userId: string = '';         // 关联的华为账号 UnionID
  label: string = '';          // 主机显示名
  customHostname: string = ''; // 自定义主机名 (RDP /client-hostname:)
  protocol: string = 'rdp';    // 协议类型 ("rdp" | "rustdesk")
  host: string = '';           // IP 或域名
  port: number = 3389;         // 端口号
  username: string = '';       // 登录用户名
  password: string = '';       // 登录密码
  // Runtime-only presence markers survive crypto-lock redaction and are never serialized.
  passwordConfigured: boolean = false;
  locked: boolean = false;     // 是否已加安全锁
  lockType: LockType = LockType.NONE;
  // SSH 专用字段
  sshUseKey: boolean = false;   // SSH 使用私钥认证
  sshKeyPath: string = '';      // SSH 私钥文件路径
  sshKeyData: string = '';      // SSH 私钥内容 (PEM格式) — 旧式副本, 兼容
  sshKeyDataConfigured: boolean = false;
  sshKeyId: string = '';        // KeyVault 密钥引用 — 优先, 修改后自动同步
  sshKeyPassphrase: string = ''; // SSH 私钥密码 (E2E加密存储)
  sshKeyPassphraseConfigured: boolean = false;
  // SSH 主机指纹信任 (T-210)
  sshHostKeyAlgorithm: string = '';          // 算法: "ssh-ed25519" 等
  sshHostKeyFingerprintSha256: string = '';  // 指纹: "SHA256:..."
  sshHostKeyRawBase64: string = '';          // raw key blob base64 (精确比对)
  sshHostKeyTrustedAt: number = 0;           // 信任时间戳 ms
  sshHostKeyTrustMode: number = 0;           // 0=unknown, 1=trusted
  // ProxyJump 跳板机 host key 信任，独立于目标 SSH 主机。
  sshJumpHostKeyAlgorithm: string = '';
  sshJumpHostKeyFingerprintSha256: string = '';
  sshJumpHostKeyRawBase64: string = '';
  sshJumpHostKeyTrustedAt: number = 0;
  sshJumpHostKeyTrustMode: number = 0;
  // RDP 证书信任
  rdpCertificateFingerprintSha256: string = '';
  rdpCertificateSubject: string = '';
  rdpCertificateIssuer: string = '';
  rdpCertificateCommonName: string = '';
  rdpCertificateNotBeforeMs: number = 0;
  rdpCertificateNotAfterMs: number = 0;
  rdpCertificateTrustedAt: number = 0;
  rdpCertificateTrustMode: number = 0; // 0=unknown, 1=legacy implicit, 2=explicit trusted
  rdpCertificateAllowUntrustedRoot: boolean = false;
  rdpCertificateAllowHostMismatch: boolean = false;
  rdpCertificateRouteIdentity: string = '';
  // RD Gateway certificate trust is independent from the tunneled target.
  rdpGatewayCertificateFingerprintSha256: string = '';
  rdpGatewayCertificateSubject: string = '';
  rdpGatewayCertificateIssuer: string = '';
  rdpGatewayCertificateCommonName: string = '';
  rdpGatewayCertificateNotBeforeMs: number = 0;
  rdpGatewayCertificateNotAfterMs: number = 0;
  rdpGatewayCertificateTrustedAt: number = 0;
  rdpGatewayCertificateTrustMode: number = 0;
  rdpGatewayCertificateAllowUntrustedRoot: boolean = false;
  rdpGatewayCertificateAllowHostMismatch: boolean = false;
  rdpGatewayCertificateRouteIdentity: string = '';
  proxyHost: string = '';       // SSH 代理/跳板机地址
  proxyPort: number = 22;       // SSH 代理端口
  proxyUsername: string = '';   // SSH 代理用户名
  sshProxyType: SshProxyType = 'direct'; // SSH 传输代理协议
  // ProxyJump credentials are independent from the target SSH credentials.
  sshProxyAuthMethod: SshProxyAuthMethod = 'password';
  sshProxyKeyId: string = '';
  sshProxyPassword: string = '';
  sshProxyPasswordConfigured: boolean = false;
  sshProxyKeyPassphrase: string = '';
  sshProxyKeyPassphraseConfigured: boolean = false;
  rustdeskRelayId: string = ''; // RustDesk 中继服务器配置 ID
  rustdeskAccountId: string = ''; // RustDesk Server Pro account ID
  rustdeskPasswordMode: number = 0; // RustDesk 密码模式: 0=一次性, 1=永久
  // RustDesk 登录授权: password=使用一次性/永久密码, request_approval=请求被控端点击批准
  rustdeskAuthMode: string = 'password';
  rustdeskDirectEnabled: boolean = false; // 直连模式 (跳过 ID 服务器)
  rustdeskDirectHost: string = ''; // 直连 peer IP 地址
  rustdeskDirectPort: number = 21118; // 直连端口 (默认 21118; RustDesk peer TCP)
  rustdeskTargetDevice: string = 'computer'; // 控制目标: computer | phone
  rustdeskAdaptiveOrientation: boolean = false; // 手机目标的自适应翻转，默认关闭
  // Peer 2FA 绑定的运行时投影。权威值位于 owner/device 本地 Preferences，
  // 这些字段不得进入 RemoteHost JSON、云扩展或备份。
  rustdeskTotpEntryId: string = '';
  rustdeskTotpAutoSubmit: boolean = false;
  // 仅用于读取旧 JSON/云扩展后的一次性迁移，迁移完成后立即清除。
  rustdeskTotpLegacyDeviceId: string = '';
  rustdeskTotpLegacySource: string = '';
  rdpCredentialId: string = ''; // RDP 绑定的 Windows 凭据 ID
  // Restricted Admin 的 NTLM Hash 保存在本机加密扩展中，不进入 RemoteHost/JSON。
  rdpAuthMode: RdpAuthMode = 'password';
  rdpRestrictedAdminSecretSource: RdpRestrictedAdminSecretSource = 'ntlm_hash';
  sourceType: string = 'manual'; // manual | rustdesk_pro
  rustdeskProAccountId: string = ''; // Pro 账号设备端绑定 ID
  rustdeskProPeerId: string = ''; // Pro 地址簿中的稳定 peer ID
  rustdeskProPlatform: string = ''; // Pro 地址簿返回的平台: Windows/Linux/macOS 等
  rustdeskProManaged: boolean = false; // 是否由 Server Pro 地址簿管理
  rustdeskProLastSeenAt: number = 0; // 最近一次地址簿同步看到该 peer 的时间
  rustdeskProSyncError: string = ''; // not_seen 或最近一次同步错误码
  // LAN search provenance. Manual entry remains the legacy/static behavior.
  // Dynamic rows are persisted only in the device-local host namespace.
  lanAddressMode: LanHostAddressMode = 'manual';
  lanDiscoveryIdentity: string = '';
  lanLastResolvedAt: number = 0;
  syncVersion: number = 0;     // 同步版本号 (冲突检测)
  groupId: string = '';        // 工作区分组 ID
  sortOrder: number = 0;       // 手动排序序号
  icon: string = '';           // 主机图标 (可选, 资源名)
  lastConnected: number = 0;   // 最后连接时间戳 (ms)
  createdAt: number = Date.now();
  // 🆕 新增字段
  gatewayHost: string = '';    // RDP 网关服务器地址
  gatewayPort: number = 443;   // RDP 网关端口
  rdpEndpointMode: string = ''; // direct_rdp | transparent_tcp_rdp | microsoft_rd_gateway | unsupported
  rdpGatewayTransport: string = 'auto';
  rdpGatewayServerName: string = '';
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
      // RustDesk 中继模式需要远程 ID；直连模式使用直连地址完成登录，远程 ID 可选。
      const hasEndpoint: boolean = this.rustdeskDirectEnabled ?
        this.rustdeskDirectHost.trim().length > 0 && this.rustdeskDirectPort > 0 &&
        this.rustdeskDirectPort <= 65535 :
        this.rustdeskRelayId.trim().length > 0 && this.port > 0 && this.port <= 65535;
      const hasPeerIdentity: boolean = this.rustdeskDirectEnabled || this.customHostname.trim().length > 0;
      return basic && hasPeerIdentity && hasEndpoint;
    }
    if (this.protocol === 'rdp') {
      const mode: RdpAuthMode = normalizeRdpAuthMode(this.rdpAuthMode);
      const hasIdentity: boolean = mode === 'password' ?
        this.username.length > 0 || this.rdpCredentialId.length > 0 : this.username.length > 0;
      return basic && this.host.length > 0 && hasIdentity && this.port > 0 && this.port <= 65535;
    }
    return basic && this.host.length > 0 && this.username.length > 0 &&
      this.port > 0 && this.port <= 65535;
  }

  /**
   * 获取验证错误信息
   */
  getValidationErrors(): string[] {
    const errors: string[] = [];
    if (!this.label) { errors.push('主机名称不能为空'); }
    if (this.protocol === 'rdp') {
      const mode: RdpAuthMode = normalizeRdpAuthMode(this.rdpAuthMode);
      if (!this.host) { errors.push('主机地址不能为空'); }
      if (this.port <= 0 || this.port > 65535) { errors.push('端口号必须在 1-65535 之间'); }
      if (mode === 'password') {
        if (!this.username && !this.rdpCredentialId) { errors.push('用户名或 Windows 凭据不能为空'); }
        if (!this.password && this.rdpCredentialId === '') { errors.push('密码不能为空 (或选择 Windows 凭据)'); }
      } else {
        if (!this.username) { errors.push('用户名不能为空'); }
        if (this.rdpCredentialId !== '') { errors.push('此认证方式不能使用 Windows 凭据'); }
        if (this.password !== '') { errors.push('此认证方式不能保存普通密码'); }
      }
      return errors;
    }
    if (this.protocol === 'rustdesk') {
      if (this.rustdeskDirectEnabled) {
        if (!this.rustdeskDirectHost.trim()) { errors.push('RustDesk 直连地址不能为空'); }
        if (this.rustdeskDirectPort <= 0 || this.rustdeskDirectPort > 65535) {
          errors.push('端口号必须在 1-65535 之间');
        }
      } else {
        if (!this.customHostname.trim()) { errors.push('远程ID不能为空'); }
        if (!this.rustdeskRelayId) {
          errors.push('RustDesk 中继连接必须绑定中继配置');
        } else if (this.port <= 0 || this.port > 65535) {
          errors.push('端口号必须在 1-65535 之间');
        }
      }
    } else {
      if (!this.host) { errors.push('主机地址不能为空'); }
      if (!this.username) { errors.push('用户名不能为空'); }
      if (this.port <= 0 || this.port > 65535) { errors.push('端口号必须在 1-65535 之间'); }
    }
    if (this.protocol !== 'rdp' && this.protocol !== 'rustdesk' && this.protocol !== 'ssh') { errors.push('协议类型无效'); }
    // 中继连接的密码可以留空，表示在连接弹窗中临时输入；只有直连没有
    // ID/中继批准通道，才必须在主机配置中预先填写设备密码。
    const rustDeskRelayCanPrompt: boolean = this.protocol === 'rustdesk' &&
      !this.rustdeskDirectEnabled;
    if (!this.password && !rustDeskRelayCanPrompt && !(this.protocol === 'ssh' && this.sshUseKey)) {
      if (this.protocol === 'rustdesk') {
        errors.push(this.rustdeskDirectEnabled ? 'RustDesk 直连模式需要设备密码' :
          '密码不能为空，或选择“请求被控端批准”');
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
    if (protocol === 'vnc') { return 5900; }
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
      rdpEndpointMode: this.rdpEndpointMode,
      rdpGatewayTransport: this.rdpGatewayTransport,
      rdpGatewayServerName: this.rdpGatewayServerName,
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
      sshJumpHostKeyAlgorithm: this.sshJumpHostKeyAlgorithm,
      sshJumpHostKeyFingerprintSha256: this.sshJumpHostKeyFingerprintSha256,
      sshJumpHostKeyRawBase64: this.sshJumpHostKeyRawBase64,
      sshJumpHostKeyTrustedAt: this.sshJumpHostKeyTrustedAt,
      sshJumpHostKeyTrustMode: this.sshJumpHostKeyTrustMode,
      rdpCertificateFingerprintSha256: this.rdpCertificateFingerprintSha256,
      rdpCertificateSubject: this.rdpCertificateSubject,
      rdpCertificateIssuer: this.rdpCertificateIssuer,
      rdpCertificateCommonName: this.rdpCertificateCommonName,
      rdpCertificateNotBeforeMs: this.rdpCertificateNotBeforeMs,
      rdpCertificateNotAfterMs: this.rdpCertificateNotAfterMs,
      rdpCertificateTrustedAt: this.rdpCertificateTrustedAt,
      rdpCertificateTrustMode: this.rdpCertificateTrustMode,
      rdpCertificateAllowUntrustedRoot: this.rdpCertificateAllowUntrustedRoot,
      rdpCertificateAllowHostMismatch: this.rdpCertificateAllowHostMismatch,
      rdpCertificateRouteIdentity: this.rdpCertificateRouteIdentity,
      rdpGatewayCertificateFingerprintSha256: this.rdpGatewayCertificateFingerprintSha256,
      rdpGatewayCertificateSubject: this.rdpGatewayCertificateSubject,
      rdpGatewayCertificateIssuer: this.rdpGatewayCertificateIssuer,
      rdpGatewayCertificateCommonName: this.rdpGatewayCertificateCommonName,
      rdpGatewayCertificateNotBeforeMs: this.rdpGatewayCertificateNotBeforeMs,
      rdpGatewayCertificateNotAfterMs: this.rdpGatewayCertificateNotAfterMs,
      rdpGatewayCertificateTrustedAt: this.rdpGatewayCertificateTrustedAt,
      rdpGatewayCertificateTrustMode: this.rdpGatewayCertificateTrustMode,
      rdpGatewayCertificateAllowUntrustedRoot: this.rdpGatewayCertificateAllowUntrustedRoot,
      rdpGatewayCertificateAllowHostMismatch: this.rdpGatewayCertificateAllowHostMismatch,
      rdpGatewayCertificateRouteIdentity: this.rdpGatewayCertificateRouteIdentity,
      proxyHost: this.proxyHost,
      proxyPort: this.proxyPort,
      proxyUsername: this.proxyUsername,
      sshProxyType: this.sshProxyType,
      sshProxyAuthMethod: this.sshProxyAuthMethod,
      sshProxyKeyId: this.sshProxyKeyId,
      sshProxyPassword: this.sshProxyPassword,
      sshProxyKeyPassphrase: this.sshProxyKeyPassphrase,
      rustdeskRelayId: this.rustdeskRelayId,
      rustdeskAccountId: this.rustdeskAccountId,
      rustdeskPasswordMode: this.rustdeskPasswordMode,
      rustdeskAuthMode: this.rustdeskAuthMode,
      rustdeskDirectEnabled: this.rustdeskDirectEnabled,
      rustdeskDirectHost: this.rustdeskDirectHost,
      rustdeskDirectPort: this.rustdeskDirectPort,
      rustdeskTargetDevice: this.rustdeskTargetDevice,
      rustdeskAdaptiveOrientation: this.rustdeskAdaptiveOrientation,
      rdpCredentialId: this.rdpCredentialId,
      rdpAuthMode: this.rdpAuthMode,
      rdpRestrictedAdminSecretSource: this.rdpRestrictedAdminSecretSource,
      sourceType: this.sourceType,
      rustdeskProAccountId: this.rustdeskProAccountId,
      rustdeskProPeerId: this.rustdeskProPeerId,
      rustdeskProPlatform: this.rustdeskProPlatform,
      rustdeskProManaged: this.rustdeskProManaged,
      rustdeskProLastSeenAt: this.rustdeskProLastSeenAt,
      rustdeskProSyncError: this.rustdeskProSyncError,
      lanAddressMode: this.lanAddressMode,
      lanDiscoveryIdentity: this.lanDiscoveryIdentity,
      lanLastResolvedAt: this.lanLastResolvedAt
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
    if (json.rdpEndpointMode !== undefined) { host.rdpEndpointMode = json.rdpEndpointMode || ''; }
    if (json.rdpGatewayTransport !== undefined) {
      host.rdpGatewayTransport = json.rdpGatewayTransport || 'auto';
    }
    if (json.rdpGatewayServerName !== undefined) {
      host.rdpGatewayServerName = json.rdpGatewayServerName || '';
    }
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
    if (json.sshJumpHostKeyAlgorithm) { host.sshJumpHostKeyAlgorithm = json.sshJumpHostKeyAlgorithm; }
    if (json.sshJumpHostKeyFingerprintSha256) {
      host.sshJumpHostKeyFingerprintSha256 = json.sshJumpHostKeyFingerprintSha256;
    }
    if (json.sshJumpHostKeyRawBase64) { host.sshJumpHostKeyRawBase64 = json.sshJumpHostKeyRawBase64; }
    if (json.sshJumpHostKeyTrustedAt !== undefined) {
      host.sshJumpHostKeyTrustedAt = json.sshJumpHostKeyTrustedAt;
    }
    if (json.sshJumpHostKeyTrustMode !== undefined) {
      host.sshJumpHostKeyTrustMode = json.sshJumpHostKeyTrustMode;
    }
    if (json.rdpCertificateFingerprintSha256) {
      host.rdpCertificateFingerprintSha256 = json.rdpCertificateFingerprintSha256;
    }
    if (json.rdpCertificateSubject) { host.rdpCertificateSubject = json.rdpCertificateSubject; }
    if (json.rdpCertificateIssuer) { host.rdpCertificateIssuer = json.rdpCertificateIssuer; }
    if (json.rdpCertificateCommonName) { host.rdpCertificateCommonName = json.rdpCertificateCommonName; }
    if (json.rdpCertificateNotBeforeMs !== undefined) {
      host.rdpCertificateNotBeforeMs = json.rdpCertificateNotBeforeMs || 0;
    }
    if (json.rdpCertificateNotAfterMs !== undefined) {
      host.rdpCertificateNotAfterMs = json.rdpCertificateNotAfterMs || 0;
    }
    if (json.rdpCertificateTrustedAt !== undefined) { host.rdpCertificateTrustedAt = json.rdpCertificateTrustedAt; }
    if (json.rdpCertificateTrustMode !== undefined) { host.rdpCertificateTrustMode = json.rdpCertificateTrustMode; }
    if (json.rdpCertificateAllowUntrustedRoot !== undefined) {
      host.rdpCertificateAllowUntrustedRoot = json.rdpCertificateAllowUntrustedRoot;
    }
    if (json.rdpCertificateAllowHostMismatch !== undefined) {
      host.rdpCertificateAllowHostMismatch = json.rdpCertificateAllowHostMismatch;
    }
    if (json.rdpCertificateRouteIdentity !== undefined) {
      host.rdpCertificateRouteIdentity = json.rdpCertificateRouteIdentity || '';
    }
    if (json.rdpGatewayCertificateFingerprintSha256 !== undefined) {
      host.rdpGatewayCertificateFingerprintSha256 = json.rdpGatewayCertificateFingerprintSha256 || '';
    }
    if (json.rdpGatewayCertificateSubject !== undefined) {
      host.rdpGatewayCertificateSubject = json.rdpGatewayCertificateSubject || '';
    }
    if (json.rdpGatewayCertificateIssuer !== undefined) {
      host.rdpGatewayCertificateIssuer = json.rdpGatewayCertificateIssuer || '';
    }
    if (json.rdpGatewayCertificateCommonName !== undefined) {
      host.rdpGatewayCertificateCommonName = json.rdpGatewayCertificateCommonName || '';
    }
    if (json.rdpGatewayCertificateNotBeforeMs !== undefined) {
      host.rdpGatewayCertificateNotBeforeMs = json.rdpGatewayCertificateNotBeforeMs || 0;
    }
    if (json.rdpGatewayCertificateNotAfterMs !== undefined) {
      host.rdpGatewayCertificateNotAfterMs = json.rdpGatewayCertificateNotAfterMs || 0;
    }
    if (json.rdpGatewayCertificateTrustedAt !== undefined) {
      host.rdpGatewayCertificateTrustedAt = json.rdpGatewayCertificateTrustedAt || 0;
    }
    if (json.rdpGatewayCertificateTrustMode !== undefined) {
      host.rdpGatewayCertificateTrustMode = json.rdpGatewayCertificateTrustMode || 0;
    }
    if (json.rdpGatewayCertificateAllowUntrustedRoot !== undefined) {
      host.rdpGatewayCertificateAllowUntrustedRoot =
        json.rdpGatewayCertificateAllowUntrustedRoot === true;
    }
    if (json.rdpGatewayCertificateAllowHostMismatch !== undefined) {
      host.rdpGatewayCertificateAllowHostMismatch =
        json.rdpGatewayCertificateAllowHostMismatch === true;
    }
    if (json.rdpGatewayCertificateRouteIdentity !== undefined) {
      host.rdpGatewayCertificateRouteIdentity = json.rdpGatewayCertificateRouteIdentity || '';
    }
    if (json.proxyHost) { host.proxyHost = json.proxyHost; }
    if (json.proxyPort) { host.proxyPort = json.proxyPort; }
    if (json.proxyUsername) { host.proxyUsername = json.proxyUsername; }
    if (json.sshProxyAuthMethod === 'password' || json.sshProxyAuthMethod === 'publickey' ||
      json.sshProxyAuthMethod === 'kbd-interactive') {
      host.sshProxyAuthMethod = json.sshProxyAuthMethod;
    }
    if (json.sshProxyKeyId !== undefined) { host.sshProxyKeyId = json.sshProxyKeyId || ''; }
    if (json.sshProxyPassword !== undefined) { host.sshProxyPassword = json.sshProxyPassword || ''; }
    if (json.sshProxyKeyPassphrase !== undefined) {
      host.sshProxyKeyPassphrase = json.sshProxyKeyPassphrase || '';
    }
    if (json.sshProxyType === 'http_connect' || json.sshProxyType === 'socks5' ||
      json.sshProxyType === 'frp_tcp' || json.sshProxyType === 'frp_visitor' ||
      json.sshProxyType === 'frp_stcp' || json.sshProxyType === 'frp_sudp' ||
      json.sshProxyType === 'frp_xtcp' || json.sshProxyType === 'ssh_jump' ||
      json.sshProxyType === 'legacy_gateway' || json.sshProxyType === 'direct') {
      host.sshProxyType = json.sshProxyType;
    }
    if (json.rustdeskRelayId) { host.rustdeskRelayId = json.rustdeskRelayId; }
    if (json.rustdeskAccountId) { host.rustdeskAccountId = json.rustdeskAccountId; }
    if (json.rustdeskPasswordMode !== undefined) { host.rustdeskPasswordMode = json.rustdeskPasswordMode; }
    if (json.rustdeskAuthMode === 'request_approval') { host.rustdeskAuthMode = 'request_approval'; }
    if (json.rustdeskDirectEnabled !== undefined) { host.rustdeskDirectEnabled = json.rustdeskDirectEnabled; }
    if (json.rustdeskDirectHost) { host.rustdeskDirectHost = json.rustdeskDirectHost; }
    if (json.rustdeskDirectPort) { host.rustdeskDirectPort = json.rustdeskDirectPort; }
    if (json.rustdeskTargetDevice === 'phone') { host.rustdeskTargetDevice = 'phone'; }
    if (json.rustdeskAdaptiveOrientation !== undefined) {
      host.rustdeskAdaptiveOrientation = json.rustdeskAdaptiveOrientation;
    }
    if (json.rustdeskTotpEntryId) {
      host.rustdeskTotpEntryId = json.rustdeskTotpEntryId;
      host.rustdeskTotpLegacySource = 'remote_json';
    }
    if (json.rustdeskTotpAutoSubmit !== undefined) {
      host.rustdeskTotpAutoSubmit = json.rustdeskTotpAutoSubmit === true ||
        json.rustdeskTotpAutoSubmit === 'true' || json.rustdeskTotpAutoSubmit === '1';
    }
    if (json.rustdeskTotpDeviceId) {
      host.rustdeskTotpLegacyDeviceId = json.rustdeskTotpDeviceId;
    }
    if (json.rdpCredentialId) { host.rdpCredentialId = json.rdpCredentialId; }
    host.rdpAuthMode = normalizeRdpAuthMode(json.rdpAuthMode);
    host.rdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      json.rdpRestrictedAdminSecretSource);
    if (json.sourceType) { host.sourceType = json.sourceType; }
    if (json.rustdeskProAccountId) { host.rustdeskProAccountId = json.rustdeskProAccountId; }
    if (json.rustdeskProPeerId) { host.rustdeskProPeerId = json.rustdeskProPeerId; }
    if (json.rustdeskProPlatform) { host.rustdeskProPlatform = json.rustdeskProPlatform; }
    if (json.rustdeskProManaged !== undefined) { host.rustdeskProManaged = json.rustdeskProManaged; }
    if (json.rustdeskProLastSeenAt !== undefined) { host.rustdeskProLastSeenAt = json.rustdeskProLastSeenAt; }
    if (json.rustdeskProSyncError) { host.rustdeskProSyncError = json.rustdeskProSyncError; }
    host.lanAddressMode = normalizeLanHostAddressMode(json.lanAddressMode);
    if (json.lanDiscoveryIdentity !== undefined) {
      host.lanDiscoveryIdentity = json.lanDiscoveryIdentity || '';
    }
    if (json.lanLastResolvedAt !== undefined && Number.isFinite(json.lanLastResolvedAt) &&
      json.lanLastResolvedAt >= 0) {
      host.lanLastResolvedAt = json.lanLastResolvedAt;
    }
    host.normalizeRdpAuthentication();
    return host;
  }

  /** Clone serialized fields while retaining process-only secret presence. */
  runtimeClone(): RemoteHost {
    const host: RemoteHost = RemoteHost.fromJSON(this.toJSON());
    host.passwordConfigured = this.passwordConfigured || this.password.length > 0;
    host.sshKeyDataConfigured = this.sshKeyDataConfigured || this.sshKeyData.length > 0;
    host.sshKeyPassphraseConfigured = this.sshKeyPassphraseConfigured ||
      this.sshKeyPassphrase.length > 0;
    host.sshProxyPasswordConfigured = this.sshProxyPasswordConfigured ||
      this.sshProxyPassword.length > 0;
    host.sshProxyKeyPassphraseConfigured = this.sshProxyKeyPassphraseConfigured ||
      this.sshProxyKeyPassphrase.length > 0;
    return host;
  }

  /** Process-only state used to detect encrypted-secret presence changes. */
  runtimeSecretStateSignature(): string {
    return (this.passwordConfigured || this.password.length > 0 ? '1' : '0') + '|' +
      (this.sshKeyDataConfigured || this.sshKeyData.length > 0 ? '1' : '0') + '|' +
      (this.sshKeyPassphraseConfigured || this.sshKeyPassphrase.length > 0 ? '1' : '0') + '|' +
      (this.sshProxyPasswordConfigured || this.sshProxyPassword.length > 0 ? '1' : '0') + '|' +
      (this.sshProxyKeyPassphraseConfigured || this.sshProxyKeyPassphrase.length > 0 ? '1' : '0');
  }

  /** Enforces the mutually exclusive credential fields for the selected RDP mode. */
  normalizeRdpAuthentication(): void {
    this.rdpAuthMode = normalizeRdpAuthMode(this.rdpAuthMode);
    this.rdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      this.rdpRestrictedAdminSecretSource);
    if (this.protocol !== 'rdp') {
      this.rdpAuthMode = 'password';
      this.rdpRestrictedAdminSecretSource = 'ntlm_hash';
      return;
    }
    if (this.rdpAuthMode === 'password') { return; }
    this.password = '';
    this.passwordConfigured = false;
    this.rdpCredentialId = '';
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

export function rdpRouteIdentity(host: RemoteHost): string {
  return rdpRouteIdentityForValues(
    host.rdpEndpointMode,
    host.host,
    host.port,
    host.customHostname,
    host.gatewayHost,
    host.gatewayPort > 0 ? host.gatewayPort : 443,
    host.rdpGatewayServerName,
    host.rdpGatewayTransport
  );
}
