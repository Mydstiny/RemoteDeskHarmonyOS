/**
 * SSH port-forwarding profile contract.
 *
 * The profile is transport-neutral and contains no credentials.  Native
 * forwarding can consume this shape later without allowing UI defaults to
 * become a public listener by accident.
 */
export type SshForwardingMode = 'local' | 'remote' | 'dynamic';
export type SshForwardingStartPolicy = 'manual' | 'onSessionReady';

export interface SshForwardingProfile {
  id: string;
  mode: SshForwardingMode;
  bindHost: string;
  bindPort: number;
  targetHost: string;
  targetPort: number;
  maxConnections: number;
  enabled: boolean;
  startPolicy?: SshForwardingStartPolicy;
  /** Public bind is an explicit user choice, never an implicit default. */
  allowPublicBind: boolean;
  minBindPort?: number;
  maxBindPort?: number;
  /** 0 means no byte budget; otherwise this is the per-runtime budget. */
  maxBytes?: number;
  /** 0 means no expiry; otherwise this is an absolute epoch-millisecond deadline. */
  expiresAtMs?: number;
}

export interface SshForwardingValidationResult {
  valid: boolean;
  code: string;
  message: string;
  profile: SshForwardingProfile;
}

export interface SshForwardingProfilesValidationResult {
  valid: boolean;
  code: string;
  message: string;
  profiles: SshForwardingProfile[];
}

export interface SshForwardingSheetLayout {
  heightVp: number;
  widthVp: number;
  bottomAnchored: boolean;
}

export const SSH_FORWARDING_MAX_PROFILES: number = 32;
export const SSH_FORWARDING_MAX_CONNECTIONS: number = 64;
export const SSH_FORWARDING_DEFAULT_BIND_HOST: string = '127.0.0.1';
export const SSH_FORWARDING_DEFAULT_MAX_CONNECTIONS: number = 16;
export const SSH_FORWARDING_DEFAULT_MIN_BIND_PORT: number = 1;
export const SSH_FORWARDING_DEFAULT_MAX_BIND_PORT: number = 65535;
const SSH_FORWARDING_MAX_SAFE_INTEGER: number = 9007199254740991;

function forwardingViewport(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function forwardingSheetLayout(viewportWidthVp: number, viewportHeightVp: number,
  phone: boolean, preferredHeightVp: number, preferredWidthVp: number,
  minimumHeightVp: number): SshForwardingSheetLayout {
  const width: number = forwardingViewport(viewportWidthVp, phone ? 360 : 800);
  const height: number = forwardingViewport(viewportHeightVp, phone ? 720 : 640);
  const maximumHeight: number = Math.max(1, height - (phone ? 24 : 48));
  const minimumHeight: number = Math.min(minimumHeightVp, maximumHeight);
  return {
    heightVp: Math.max(minimumHeight, Math.min(preferredHeightVp, maximumHeight)),
    widthVp: phone ? width : Math.max(1, Math.min(preferredWidthVp, width - 40)),
    bottomAnchored: phone
  };
}

/** Root tunnel workspace grows when rules exist and clamps to the live window. */
export function resolveSshForwardingSheetLayout(viewportWidthVp: number,
  viewportHeightVp: number, profileCount: number, phone: boolean): SshForwardingSheetLayout {
  const hasProfiles: boolean = Number.isFinite(profileCount) && profileCount > 0;
  return forwardingSheetLayout(
    viewportWidthVp,
    viewportHeightVp,
    phone,
    hasProfiles ? (phone ? 500 : 460) : (phone ? 320 : 360),
    hasProfiles ? 660 : 560,
    phone ? 280 : 320
  );
}

/** The full rule form scrolls inside a viewport-clamped editor Sheet. */
export function resolveSshForwardingEditorSheetLayout(viewportWidthVp: number,
  viewportHeightVp: number, phone: boolean): SshForwardingSheetLayout {
  return forwardingSheetLayout(
    viewportWidthVp, viewportHeightVp, phone, 680, 560, phone ? 320 : 420);
}

function isForwardingMode(value: string): boolean {
  return value === 'local' || value === 'remote' || value === 'dynamic';
}

function isStartPolicy(value: string): boolean {
  return value === 'manual' || value === 'onSessionReady';
}

function isValidPort(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 1 && value <= 65535;
}

function isValidBoundedUint(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0 &&
    value <= SSH_FORWARDING_MAX_SAFE_INTEGER;
}

function isLoopbackHost(value: string): boolean {
  const host: string = value.trim().toLowerCase();
  return host === 'localhost' || host === '::1' || host.startsWith('127.');
}

function boundedHost(value: string, fallback: string = ''): string {
  const normalized: string = value.trim();
  return (normalized.length > 0 ? normalized : fallback).substring(0, 255);
}

function normalizedProfile(profile: SshForwardingProfile): SshForwardingProfile {
  const mode: SshForwardingMode = isForwardingMode(profile.mode)
    ? profile.mode as SshForwardingMode : 'local';
  const minBindPort: number = profile.minBindPort === undefined
    ? SSH_FORWARDING_DEFAULT_MIN_BIND_PORT : profile.minBindPort;
  const maxBindPort: number = profile.maxBindPort === undefined
    ? SSH_FORWARDING_DEFAULT_MAX_BIND_PORT : profile.maxBindPort;
  const maxBytes: number = profile.maxBytes === undefined ? 0 : profile.maxBytes;
  const expiresAtMs: number = profile.expiresAtMs === undefined ? 0 : profile.expiresAtMs;
  const startPolicy: SshForwardingStartPolicy = profile.startPolicy === undefined
    ? 'manual' : (isStartPolicy(profile.startPolicy)
      ? profile.startPolicy as SshForwardingStartPolicy : 'manual');
  return {
    id: profile.id.trim().substring(0, 96),
    mode,
    bindHost: boundedHost(profile.bindHost, SSH_FORWARDING_DEFAULT_BIND_HOST),
    bindPort: profile.bindPort,
    targetHost: boundedHost(profile.targetHost),
    targetPort: profile.targetPort,
    maxConnections: profile.maxConnections,
    enabled: profile.enabled === true,
    startPolicy,
    allowPublicBind: profile.allowPublicBind === true,
    minBindPort,
    maxBindPort,
    maxBytes,
    expiresAtMs
  };
}

export function defaultSshForwardingProfile(mode: SshForwardingMode): SshForwardingProfile {
  return {
    id: '',
    mode,
    bindHost: SSH_FORWARDING_DEFAULT_BIND_HOST,
    bindPort: 0,
    targetHost: '',
    targetPort: 0,
    maxConnections: SSH_FORWARDING_DEFAULT_MAX_CONNECTIONS,
    enabled: true,
    startPolicy: 'manual',
    allowPublicBind: false,
    minBindPort: SSH_FORWARDING_DEFAULT_MIN_BIND_PORT,
    maxBindPort: SSH_FORWARDING_DEFAULT_MAX_BIND_PORT,
    maxBytes: 0,
    expiresAtMs: 0
  };
}

export function validateSshForwardingProfile(profile: SshForwardingProfile): SshForwardingValidationResult {
  const normalized: SshForwardingProfile = normalizedProfile(profile);
  const minBindPort: number = normalized.minBindPort === undefined
    ? SSH_FORWARDING_DEFAULT_MIN_BIND_PORT : normalized.minBindPort;
  const maxBindPort: number = normalized.maxBindPort === undefined
    ? SSH_FORWARDING_DEFAULT_MAX_BIND_PORT : normalized.maxBindPort;
  const maxBytes: number = normalized.maxBytes === undefined ? 0 : normalized.maxBytes;
  const expiresAtMs: number = normalized.expiresAtMs === undefined ? 0 : normalized.expiresAtMs;
  if (normalized.id.length === 0) {
    return { valid: false, code: 'E-SSH-FORWARD-ID', message: '转发规则缺少稳定 ID', profile: normalized };
  }
  if (!isForwardingMode(normalized.mode)) {
    return { valid: false, code: 'E-SSH-FORWARD-MODE', message: '转发模式无效', profile: normalized };
  }
  if (profile.startPolicy !== undefined && !isStartPolicy(profile.startPolicy)) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-START-POLICY',
      message: '自动启动策略无效',
      profile: normalized
    };
  }
  if (normalized.bindHost.length === 0 || normalized.bindHost.length > 255) {
    return { valid: false, code: 'E-SSH-FORWARD-BIND-HOST', message: '监听地址无效', profile: normalized };
  }
  if (!normalized.allowPublicBind && !isLoopbackHost(normalized.bindHost)) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-PUBLIC-BIND-CONFIRMATION',
      message: '公网监听地址必须由用户显式确认',
      profile: normalized
    };
  }
  if (!isValidPort(minBindPort) || !isValidPort(maxBindPort) || minBindPort > maxBindPort) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-PORT-RANGE',
      message: '监听端口范围必须为 1-65535 且起始端口不大于结束端口',
      profile: normalized
    };
  }
  if (!isValidBoundedUint(maxBytes)) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-BYTE-LIMIT',
      message: '流量限制必须为非负整数',
      profile: normalized
    };
  }
  if (!isValidBoundedUint(expiresAtMs)) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-EXPIRY',
      message: '生命周期截止时间必须为非负整数',
      profile: normalized
    };
  }
  if (!isValidPort(normalized.bindPort)) {
    return { valid: false, code: 'E-SSH-FORWARD-BIND-PORT', message: '监听端口必须为 1-65535', profile: normalized };
  }
  if (normalized.bindPort < minBindPort || normalized.bindPort > maxBindPort) {
    return { valid: false, code: 'E-SSH-FORWARD-BIND-PORT', message: '监听端口不在允许范围内', profile: normalized };
  }
  if (!Number.isFinite(normalized.maxConnections) ||
    !Number.isInteger(normalized.maxConnections) || normalized.maxConnections < 1 ||
    normalized.maxConnections > SSH_FORWARDING_MAX_CONNECTIONS) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-CONNECTION-LIMIT',
      message: '单条转发连接数必须为 1-' + SSH_FORWARDING_MAX_CONNECTIONS.toString(),
      profile: normalized
    };
  }
  if (normalized.mode === 'dynamic') {
    if (normalized.targetHost.length > 0 || normalized.targetPort !== 0) {
      return {
        valid: false,
        code: 'E-SSH-FORWARD-DYNAMIC-TARGET',
        message: 'dynamic 转发不应预设目标地址',
        profile: normalized
      };
    }
    return { valid: true, code: '', message: '', profile: normalized };
  }
  if (normalized.targetHost.length === 0 || normalized.targetHost.length > 255) {
    return { valid: false, code: 'E-SSH-FORWARD-TARGET-HOST', message: '目标地址不能为空', profile: normalized };
  }
  if (!isValidPort(normalized.targetPort)) {
    return { valid: false, code: 'E-SSH-FORWARD-TARGET-PORT', message: '目标端口必须为 1-65535', profile: normalized };
  }
  return { valid: true, code: '', message: '', profile: normalized };
}

export function validateSshForwardingProfiles(
  profiles: SshForwardingProfile[]): SshForwardingProfilesValidationResult {
  if (profiles.length > SSH_FORWARDING_MAX_PROFILES) {
    return {
      valid: false,
      code: 'E-SSH-FORWARD-PROFILE-LIMIT',
      message: 'SSH 转发规则最多保存 ' + SSH_FORWARDING_MAX_PROFILES.toString() + ' 条',
      profiles: []
    };
  }
  const normalizedProfiles: SshForwardingProfile[] = [];
  const ids: Set<string> = new Set<string>();
  for (let index: number = 0; index < profiles.length; index++) {
    const result: SshForwardingValidationResult = validateSshForwardingProfile(profiles[index]);
    if (!result.valid) {
      return {
        valid: false,
        code: result.code,
        message: result.message,
        profiles: []
      };
    }
    if (ids.has(result.profile.id)) {
      return {
        valid: false,
        code: 'E-SSH-FORWARD-DUPLICATE-ID',
        message: 'SSH 转发规则 ID 不能重复',
        profiles: []
      };
    }
    ids.add(result.profile.id);
    normalizedProfiles.push(result.profile);
  }
  return { valid: true, code: '', message: '', profiles: normalizedProfiles };
}
