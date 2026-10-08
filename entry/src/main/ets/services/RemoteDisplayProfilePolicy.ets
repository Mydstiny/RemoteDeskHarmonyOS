/**
 * Versioned contract for remote display choices.
 *
 * Remote geometry, RDP Windows DPI, and the local canvas transform are kept
 * in separate fields on purpose.  This module is pure so migration and
 * entitlement tests do not need a live session or Preferences instance.
 */

export const REMOTE_DISPLAY_PROFILE_SCHEMA_VERSION: number = 1;
export const REMOTE_DISPLAY_MIN_EDGE: number = 200;
export const REMOTE_DISPLAY_MAX_EDGE: number = 8192;
export const RDP_DESKTOP_SCALE_MIN: number = 100;
export const RDP_DESKTOP_SCALE_MAX: number = 500;

export type RemoteDisplayProtocol = 'rdp' | 'rustdesk';
export type RemoteDisplayDeviceScope = 'phone' | 'tablet' | 'pc' | 'unknown';
export type RemoteDisplayOrientationScope = 'landscape' | 'portrait' | 'any';
export type RemoteDisplayResolutionMode = 'auto' | 'preset' | 'custom';
export type RdpDesktopScaleMode = 'auto' | 'preset' | 'custom';
export type RdpDeviceScaleMode = 'auto' | 'fixed';

export interface RemoteDisplayResolutionProfile {
  mode: RemoteDisplayResolutionMode;
  presetId: string;
  width: number;
  height: number;
}

export interface RdpScaleProfile {
  desktopMode: RdpDesktopScaleMode;
  desktopPercent: number;
  deviceMode: RdpDeviceScaleMode;
  devicePercent: number;
}

export interface RemoteDisplayProfile {
  schemaVersion: number;
  profileId: string;
  hostId: string;
  protocol: RemoteDisplayProtocol;
  targetDisplay: number;
  deviceScope: RemoteDisplayDeviceScope;
  displayScope: string;
  orientationScope: RemoteDisplayOrientationScope;
  resolution: RemoteDisplayResolutionProfile;
  rdpScale: RdpScaleProfile;
  localViewMode: string;
  localViewCustomPercent: number;
  createdAt: number;
  updatedAt: number;
}

export interface RemoteDisplayGeometryValidation {
  accepted: boolean;
  width: number;
  height: number;
  reason: string;
}

export interface RustDeskCustomResolutionCapability {
  peerVersion: string;
  platform: string;
  hasDisplayIndex: boolean;
  hasPermission: boolean;
  hasVirtualDisplay: boolean;
}

export type RustDeskCustomResolutionReason =
  'allowed' | 'version_unknown' | 'version_unsupported' | 'platform_unsupported' |
  'display_index_unavailable' | 'permission_required' | 'virtual_display_required';

export interface RustDeskCustomResolutionDecision {
  allowed: boolean;
  reason: RustDeskCustomResolutionReason;
  detail: string;
}

function finite(value: number): boolean {
  return Number.isFinite(value);
}

function integer(value: number): boolean {
  return Number.isSafeInteger(value);
}

function clampInteger(value: number, minimum: number, maximum: number, fallback: number): number {
  if (!finite(value)) { return fallback; }
  const rounded: number = Math.round(value);
  return Math.max(minimum, Math.min(maximum, rounded));
}

function normalizeEvenEdge(value: number, fallback: number): number {
  const bounded: number = clampInteger(value, REMOTE_DISPLAY_MIN_EDGE, REMOTE_DISPLAY_MAX_EDGE, fallback);
  return bounded % 2 === 0 ? bounded : bounded - 1;
}

function normalizeProtocol(value: string): RemoteDisplayProtocol {
  return value === 'rustdesk' ? 'rustdesk' : 'rdp';
}

function normalizeDeviceScope(value: string): RemoteDisplayDeviceScope {
  if (value === 'phone' || value === 'tablet' || value === 'pc') { return value; }
  return 'unknown';
}

function normalizeOrientationScope(value: string): RemoteDisplayOrientationScope {
  if (value === 'landscape' || value === 'portrait') { return value; }
  return 'any';
}

function normalizeDeviceScalePercent(value: number, fallback: number = 100): number {
  if (value === 140 || value === 180 || value === 100) { return value; }
  return fallback === 140 || fallback === 180 ? fallback : 100;
}

export function normalizeRdpDeviceScalePercent(value: number, fallback: number = 100): number {
  return normalizeDeviceScalePercent(value, fallback);
}

export function normalizeRdpDesktopScalePercent(value: number, fallback: number = 100): number {
  return clampInteger(value, RDP_DESKTOP_SCALE_MIN, RDP_DESKTOP_SCALE_MAX,
    clampInteger(fallback, RDP_DESKTOP_SCALE_MIN, RDP_DESKTOP_SCALE_MAX, 100));
}

export function isRdpDeviceScalePercent(value: number): boolean {
  return value === 100 || value === 140 || value === 180;
}

export function validateRemoteDisplayGeometry(width: number, height: number,
  fallbackWidth: number = 1920, fallbackHeight: number = 1080): RemoteDisplayGeometryValidation {
  if (!integer(width) || !integer(height) || width < REMOTE_DISPLAY_MIN_EDGE ||
      width > REMOTE_DISPLAY_MAX_EDGE || height < REMOTE_DISPLAY_MIN_EDGE ||
      height > REMOTE_DISPLAY_MAX_EDGE) {
    return { accepted: false, width: normalizeEvenEdge(fallbackWidth, 1920),
      height: clampInteger(fallbackHeight, REMOTE_DISPLAY_MIN_EDGE, REMOTE_DISPLAY_MAX_EDGE, 1080),
      reason: '尺寸必须为 200–8192 的整数' };
  }
  if (width % 2 !== 0) {
    return { accepted: false, width: width - 1, height,
      reason: '宽度必须为偶数' };
  }
  return { accepted: true, width, height, reason: 'accepted' };
}

export function normalizeRemoteDisplayGeometry(width: number, height: number): RemoteDisplayGeometryValidation {
  const normalizedWidth: number = normalizeEvenEdge(width, 1920);
  const normalizedHeight: number = clampInteger(height, REMOTE_DISPLAY_MIN_EDGE,
    REMOTE_DISPLAY_MAX_EDGE, 1080);
  return {
    accepted: finite(width) && finite(height),
    width: normalizedWidth,
    height: normalizedHeight,
    reason: finite(width) && finite(height) ? 'normalized' : 'invalid_number'
  };
}

export function defaultRemoteDisplayProfile(hostId: string, protocol: string,
  profileId: string = 'default', nowMs: number = 0): RemoteDisplayProfile {
  const now: number = finite(nowMs) && nowMs >= 0 ? nowMs : 0;
  return {
    schemaVersion: REMOTE_DISPLAY_PROFILE_SCHEMA_VERSION,
    profileId,
    hostId,
    protocol: normalizeProtocol(protocol),
    targetDisplay: -1,
    deviceScope: 'unknown',
    displayScope: 'default',
    orientationScope: 'any',
    resolution: { mode: 'auto', presetId: 'auto', width: 1920, height: 1080 },
    rdpScale: { desktopMode: 'auto', desktopPercent: 100, deviceMode: 'auto', devicePercent: 100 },
    localViewMode: 'fit',
    localViewCustomPercent: 100,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * Migrate the released RDP fields into the versioned model.  The legacy
 * values remain valid inputs; unknown or damaged values deliberately become
 * free Auto/100% choices rather than a protected custom request.
 */
export function migrateLegacyRdpDisplayProfile(hostId: string, resolutionId: string,
  legacyPreset: number, remoteUiScale: string, deviceScope: string = 'unknown',
  displayScope: string = 'default', nowMs: number = 0): RemoteDisplayProfile {
  const profile: RemoteDisplayProfile = defaultRemoteDisplayProfile(hostId, 'rdp', 'default', nowMs);
  profile.deviceScope = normalizeDeviceScope(deviceScope);
  profile.displayScope = displayScope.trim().length > 0 ? displayScope.trim() : 'default';
  let id: string = resolutionId;
  if (id.length === 0 || (id !== 'auto' && id.indexOf('x') < 1)) {
    id = legacyPreset === 2 ? '2560x1440' : legacyPreset === 3 ? '3840x2160' :
      legacyPreset === 1 ? '1920x1080' : 'auto';
  }
  if (id === 'auto') {
    profile.resolution = { mode: 'auto', presetId: 'auto', width: 1920, height: 1080 };
  } else {
    const parts: string[] = id.split('x');
    const width: number = parts.length > 0 ? Number(parts[0]) : 1920;
    const height: number = parts.length > 1 ? Number(parts[1]) : 1080;
    const checked: RemoteDisplayGeometryValidation = validateRemoteDisplayGeometry(width, height);
    profile.resolution = checked.accepted ?
      { mode: 'preset', presetId: id, width: checked.width, height: checked.height } :
      { mode: 'auto', presetId: 'auto', width: 1920, height: 1080 };
  }
  if (remoteUiScale === '100' || remoteUiScale === '140' || remoteUiScale === '180') {
    profile.rdpScale = {
      desktopMode: 'preset', desktopPercent: Number(remoteUiScale),
      deviceMode: 'fixed', devicePercent: normalizeDeviceScalePercent(Number(remoteUiScale))
    };
  }
  return profile;
}

export function resolveRdpScaleProfile(desktopMode: string, desktopPercent: number,
  deviceMode: string, devicePercent: number): RdpScaleProfile {
  const normalizedDesktop: number = normalizeRdpDesktopScalePercent(desktopPercent);
  const normalizedDevice: number = normalizeDeviceScalePercent(devicePercent);
  return {
    desktopMode: desktopMode === 'custom' || desktopMode === 'preset' ? desktopMode : 'auto',
    desktopPercent: normalizedDesktop,
    deviceMode: deviceMode === 'fixed' ? 'fixed' : 'auto',
    devicePercent: normalizedDevice
  };
}

function versionParts(version: string): number[] | null {
  const trimmed: string = version.trim();
  if (trimmed.length === 0) { return null; }
  const raw: string[] = trimmed.split('.');
  if (raw.length < 2) { return null; }
  const result: number[] = [];
  for (let index = 0; index < 3; index++) {
    const value: number = Number(raw[index] ?? '0');
    if (!integer(value) || value < 0) { return null; }
    result.push(value);
  }
  return result;
}

function atLeastVersion(version: number[], minimum: number[]): boolean {
  for (let index = 0; index < minimum.length; index++) {
    if (version[index] !== minimum[index]) { return version[index] > minimum[index]; }
  }
  return true;
}

/** Custom RustDesk requests are capability based and fail closed when peer
 * version/platform/permission evidence is incomplete. */
export function rustDeskCustomResolutionDecision(
  capability: RustDeskCustomResolutionCapability): RustDeskCustomResolutionDecision {
  const parsed: number[] | null = versionParts(capability.peerVersion);
  if (parsed === null) {
    return { allowed: false, reason: 'version_unknown', detail: '远端版本未知，先使用候选分辨率' };
  }
  if (!atLeastVersion(parsed, [1, 2, 4])) {
    return { allowed: false, reason: 'version_unsupported', detail: '远端版本不支持显示器索引请求' };
  }
  if (capability.platform !== 'windows' && capability.platform !== 'linux_x11') {
    return { allowed: false, reason: 'platform_unsupported', detail: '当前远端平台只开放候选分辨率' };
  }
  if (!capability.hasDisplayIndex) {
    return { allowed: false, reason: 'display_index_unavailable', detail: '远端未提供可操作的显示器索引' };
  }
  if (!capability.hasPermission) {
    return { allowed: false, reason: 'permission_required', detail: '远端未授予显示设置权限' };
  }
  if (capability.platform === 'linux_x11' && !capability.hasVirtualDisplay) {
    return { allowed: false, reason: 'virtual_display_required', detail: 'Linux X11 需要已验证的显示器/虚拟显示器' };
  }
  return { allowed: true, reason: 'allowed', detail: '允许提交自定义远端分辨率' };
}

export function remoteDisplayProfileRequiresPro(profile: RemoteDisplayProfile): boolean {
  const customDesktopScale: boolean = profile.rdpScale.desktopMode === 'custom' ||
    (profile.rdpScale.desktopMode === 'preset' &&
      profile.rdpScale.desktopPercent !== 100 &&
      profile.rdpScale.desktopPercent !== 140 &&
      profile.rdpScale.desktopPercent !== 180);
  return profile.resolution.mode === 'custom' || customDesktopScale;
}

export function remoteDisplayRequestStateLabel(state: string): string {
  switch (state) {
    case 'accepted': return '已接受';
    case 'queued': return '排队中';
    case 'applied': return '已应用';
    case 'server_adjusted': return '远端已调整';
    case 'rejected': return '远端拒绝';
    case 'not_ready': return '能力未就绪';
    case 'unsupported': return '不支持';
    case 'timeout': return '等待超时';
    default: return '未应用';
  }
}

/** Windows scale steps every user gets (RDPEDISP DeviceScaleFactor values). */
export const RDP_FREE_DESKTOP_SCALES: number[] = [100, 140, 180];
export function isRdpFreeDesktopScale(percent: number): boolean {
  return RDP_FREE_DESKTOP_SCALES.indexOf(percent) >= 0;
}

/**
 * Which Windows scale chip is selected: exactly one of 'auto', '100', '140', '180' or 'custom'.
 * A Pro value that the current account cannot use falls back to 'auto', which is what the session will negotiate.
 */
export function rdpDesktopScaleSelection(mode: string, percent: number, proUsable: boolean): string {
  if (mode === 'preset' && isRdpFreeDesktopScale(percent)) { return percent.toString(); }
  if (mode === 'custom' || mode === 'preset') { return proUsable ? 'custom' : 'auto'; }
  return 'auto';
}

/** Which desktop-size chip is selected; a custom size the account cannot use falls back to 自适应. */
export function rdpResolutionSelection(id: string, proUsable: boolean): string {
  return id === 'custom' && !proUsable ? 'auto' : id;
}

/** Label of the custom size, e.g. 2560 × 1600. */
export function remoteDisplaySizeLabel(width: number, height: number): string {
  return Math.round(width).toString() + ' × ' + Math.round(height).toString();
}

/** Aspect ratio in the usual short form (16:10, 21:9 …), or W:H reduced when it is not a common one. */
export function remoteDisplayAspectLabel(width: number, height: number): string {
  if (!finite(width) || !finite(height) || width <= 0 || height <= 0) { return ''; }
  const ratio: number = width / height;
  const known: string[] = ['16:9', '16:10', '3:2', '4:3', '5:4', '21:9', '32:9', '1:1'];
  for (const item of known) {
    const parts: string[] = item.split(':');
    // Relative tolerance: ultrawide 3440 × 1440 is sold as 21:9; 16:10 and 3:2 still stay apart.
    const target: number = Number(parts[0]) / Number(parts[1]);
    if (Math.abs(ratio - target) / target < 0.025) { return item; }
  }
  let a: number = Math.round(width);
  let b: number = Math.round(height);
  while (b !== 0) { const t: number = b; b = a % b; a = t; }
  return Math.round(width / a).toString() + ':' + Math.round(height / a).toString();
}

/** All Windows scale steps offered to Pro in one grid (free and Pro values together, in order). */
export const RDP_PRO_DESKTOP_SCALE_GRID: number[] = [100, 125, 140, 150, 175, 180, 200];

/** One line for the Pro 远端显示方案 entry: desktop size, then Windows scale. */
export function rdpDisplayProfileSummary(resolutionId: string, width: number, height: number, presetLabel: string,
  scaleMode: string, scalePercent: number): string {
  const size: string = resolutionId === 'auto' ? '自适应' :
    resolutionId === 'custom' ? remoteDisplaySizeLabel(width, height) : presetLabel;
  const selection: string = rdpDesktopScaleSelection(scaleMode, scalePercent, true);
  const scale: string = selection === 'auto' ? '自动' : (selection === 'custom' ? scalePercent : Number(selection)).toString() + '%';
  return size + ' · Windows 缩放 ' + scale;
}
