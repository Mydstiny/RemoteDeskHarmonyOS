/**
 * SSH port-forwarding profile contract.
 *
 * The profile is transport-neutral and contains no credentials.  Native
 * forwarding can consume this shape later without allowing UI defaults to
 * become a public listener by accident.
 */
export type SshForwardingMode = 'local' | 'remote' | 'dynamic';

export interface SshForwardingProfile {
  id: string;
  mode: SshForwardingMode;
  bindHost: string;
  bindPort: number;
  targetHost: string;
  targetPort: number;
  maxConnections: number;
  enabled: boolean;
  /** Public bind is an explicit user choice, never an implicit default. */
  allowPublicBind: boolean;
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

export const SSH_FORWARDING_MAX_PROFILES: number = 32;
export const SSH_FORWARDING_MAX_CONNECTIONS: number = 64;
export const SSH_FORWARDING_DEFAULT_BIND_HOST: string = '127.0.0.1';
export const SSH_FORWARDING_DEFAULT_MAX_CONNECTIONS: number = 16;

function isForwardingMode(value: string): value is SshForwardingMode {
  return value === 'local' || value === 'remote' || value === 'dynamic';
}

function isValidPort(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 1 && value <= 65535;
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
  const mode: SshForwardingMode = isForwardingMode(profile.mode) ? profile.mode : 'local';
  return {
    id: profile.id.trim().substring(0, 96),
    mode,
    bindHost: boundedHost(profile.bindHost, SSH_FORWARDING_DEFAULT_BIND_HOST),
    bindPort: profile.bindPort,
    targetHost: boundedHost(profile.targetHost),
    targetPort: profile.targetPort,
    maxConnections: profile.maxConnections,
    enabled: profile.enabled === true,
    allowPublicBind: profile.allowPublicBind === true
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
    allowPublicBind: false
  };
}

export function validateSshForwardingProfile(profile: SshForwardingProfile): SshForwardingValidationResult {
  const normalized: SshForwardingProfile = normalizedProfile(profile);
  if (normalized.id.length === 0) {
    return { valid: false, code: 'E-SSH-FORWARD-ID', message: '转发规则缺少稳定 ID', profile: normalized };
  }
  if (!isForwardingMode(normalized.mode)) {
    return { valid: false, code: 'E-SSH-FORWARD-MODE', message: '转发模式无效', profile: normalized };
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
  if (!isValidPort(normalized.bindPort)) {
    return { valid: false, code: 'E-SSH-FORWARD-BIND-PORT', message: '监听端口必须为 1-65535', profile: normalized };
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
