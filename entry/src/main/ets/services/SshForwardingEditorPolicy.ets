import {
  SshForwardingMode,
  SshForwardingProfile,
  SshForwardingStartPolicy,
  SshForwardingValidationResult,
  defaultSshForwardingProfile,
  validateSshForwardingProfile
} from './SshForwardingPolicy';

export interface SshForwardingDraft {
  id: string;
  mode: SshForwardingMode;
  bindHost: string;
  bindPortText: string;
  targetHost: string;
  targetPortText: string;
  maxConnectionsText: string;
  maxBytesText: string;
  enabled: boolean;
  startPolicy: SshForwardingStartPolicy;
  allowPublicBind: boolean;
}

export interface SshForwardingDraftResult {
  valid: boolean;
  code: string;
  message: string;
  profile: SshForwardingProfile;
}

function parseInteger(value: string, fallback: number = -1): number {
  const normalized: string = value.trim();
  if (!/^\d+$/.test(normalized)) { return fallback; }
  const parsed: number = Number(normalized);
  return Number.isSafeInteger(parsed) ? parsed : fallback;
}

export function makeSshForwardingProfileId(nowMs: number, nonce: number): string {
  const timestamp: number = Math.max(0, Math.floor(nowMs));
  const suffix: number = Math.max(0, Math.floor(nonce)) % 1000000;
  return 'ssh-forward-' + timestamp.toString() + '-' + suffix.toString();
}

export function defaultSshForwardingDraft(mode: SshForwardingMode,
  id: string): SshForwardingDraft {
  const profile: SshForwardingProfile = defaultSshForwardingProfile(mode);
  profile.id = id.trim();
  if (mode === 'dynamic') {
    profile.bindPort = 1080;
  } else {
    profile.bindPort = 8022;
    profile.targetHost = mode === 'remote' ? '127.0.0.1' : '127.0.0.1';
    profile.targetPort = 22;
  }
  return sshForwardingDraftFromProfile(profile);
}

export function sshForwardingDraftFromProfile(profile: SshForwardingProfile): SshForwardingDraft {
  return {
    id: profile.id,
    mode: profile.mode,
    bindHost: profile.bindHost,
    bindPortText: profile.bindPort > 0 ? profile.bindPort.toString() : '',
    targetHost: profile.mode === 'dynamic' ? '' : profile.targetHost,
    targetPortText: profile.mode === 'dynamic' || profile.targetPort <= 0
      ? '' : profile.targetPort.toString(),
    maxConnectionsText: profile.maxConnections.toString(),
    maxBytesText: profile.maxBytes === undefined || profile.maxBytes === 0
      ? '' : profile.maxBytes.toString(),
    enabled: profile.enabled,
    startPolicy: profile.startPolicy === undefined ? 'manual' : profile.startPolicy,
    allowPublicBind: profile.allowPublicBind
  };
}

export function buildSshForwardingProfile(draft: SshForwardingDraft): SshForwardingDraftResult {
  const bindPort: number = parseInteger(draft.bindPortText);
  const targetPort: number = draft.mode === 'dynamic' ? 0 : parseInteger(draft.targetPortText);
  const maxConnections: number = parseInteger(draft.maxConnectionsText);
  const maxBytes: number = draft.maxBytesText.trim().length === 0
    ? 0 : parseInteger(draft.maxBytesText);
  const profile: SshForwardingProfile = {
    id: draft.id.trim(),
    mode: draft.mode,
    bindHost: draft.bindHost.trim(),
    bindPort,
    targetHost: draft.mode === 'dynamic' ? '' : draft.targetHost.trim(),
    targetPort,
    maxConnections,
    enabled: draft.enabled,
    startPolicy: draft.startPolicy,
    allowPublicBind: draft.allowPublicBind,
    minBindPort: 1,
    maxBindPort: 65535,
    maxBytes,
    expiresAtMs: 0
  };
  const validation: SshForwardingValidationResult = validateSshForwardingProfile(profile);
  return {
    valid: validation.valid,
    code: validation.code,
    message: validation.message,
    profile: validation.profile
  };
}

export function sshForwardingProfileNeedsPublicConfirmation(
  profile: SshForwardingProfile): boolean {
  const host: string = profile.bindHost.trim().toLowerCase();
  const loopback: boolean = host === 'localhost' || host === '::1' || host.startsWith('127.');
  return !loopback;
}

export function sshForwardingModeLabel(mode: SshForwardingMode): string {
  if (mode === 'remote') { return 'Remote'; }
  if (mode === 'dynamic') { return 'Dynamic'; }
  return 'Local';
}
