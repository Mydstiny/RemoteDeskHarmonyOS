export type RdpSessionSettingActivation = 'live' | 'reconnect';

export const RDP_SESSION_CONTROL_ACCENT: string = '#4F8DFF';
export const RDP_SESSION_CONTROL_ACCENT_SOFT: string = 'rgba(79,141,255,0.22)';
export const RDP_SESSION_NEUTRAL_ACCENT: string = '#A8B0BF';
export const RDP_SESSION_NEUTRAL_ACCENT_SOFT: string = 'rgba(168,176,191,0.12)';

export interface RdpSessionPerformanceSummary {
  status: string;
  color: string;
  transport: string;
  frameAge: string;
  queueP95: string;
}

export function normalizeRdpSessionControlMode(mode: number): number {
  if (!Number.isFinite(mode)) { return 0; }
  const value: number = Math.floor(mode);
  return value >= 0 && value <= 2 ? value : 0;
}

export function normalizeRdpSessionColorDepth(depth: number): number {
  return depth === 16 || depth === 24 ? depth : 32;
}

export function normalizeRdpSessionDriveName(value: string): string {
  let out: string = '';
  for (let index: number = 0; index < value.length && out.length < 20; index++) {
    const ch: string = value.charAt(index);
    const code: number = ch.charCodeAt(0);
    const alnum: boolean = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    if (alnum || ch === '_' || ch === '-') {
      out += ch;
    } else if (ch === ' ' || ch === '.' || ch === '/' || ch === '\\') {
      out += '_';
    }
  }
  return out.length > 0 ? out : 'RemoteDesktop';
}

export function rdpSessionSettingActivation(key: string): RdpSessionSettingActivation {
  if (key === 'rdpDesktopResolutionId' || key === 'rdpRemoteUiScale' || key === 'rdpColorDepth' ||
    key === 'rdpAudioEnabled' || key === 'rdpDriveEnabled' ||
    key === 'rdpDriveName' || key === 'rdpAuthIdentityMode' ||
    key === 'rdpTlsWithoutNla' || key === 'rdpClipboardEnabled') {
    return 'reconnect';
  }
  return 'live';
}

function durationUs(value: number): string {
  if (!Number.isFinite(value) || value <= 0) { return '—'; }
  return value >= 1000 ? (value / 1000).toFixed(1) + ' ms' :
    Math.round(value).toString() + ' μs';
}

function ageMs(value: number): string {
  if (!Number.isFinite(value) || value < 0) { return '—'; }
  return Math.round(value).toString() + ' ms';
}

export function rdpSessionPerformanceSummary(lastRenderResult: number,
  lastRemoteUpdateAgeMs: number, queueP95Us: number,
  gfxChannelConnected: boolean): RdpSessionPerformanceSummary {
  const sampled: boolean = Number.isFinite(lastRemoteUpdateAgeMs) && lastRemoteUpdateAgeMs >= 0;
  const stalled: boolean = sampled &&
    lastRemoteUpdateAgeMs >= 2500;
  const failed: boolean = lastRenderResult < 0;
  return {
    status: failed ? '恢复中' : (!sampled ? '待采样' : (stalled ? '画面停滞' : '实时')),
    color: failed || stalled ? '#FF6B6B' :
      (sampled ? RDP_SESSION_CONTROL_ACCENT : RDP_SESSION_NEUTRAL_ACCENT),
    transport: gfxChannelConnected ? 'GFX' : 'GDI',
    frameAge: ageMs(lastRemoteUpdateAgeMs),
    queueP95: durationUs(queueP95Us)
  };
}
