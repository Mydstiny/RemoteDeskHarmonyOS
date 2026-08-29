/**
 * Pure Moonlight domain models.
 *
 * These DTOs contain durable user intent and bounded catalog metadata only.
 * Runtime reachability, PINs, session keys, rikey/rikeyid, decoder state and
 * controller device handles deliberately live outside this file.
 */
import {
  EndpointAddressResult,
  parseEndpointFields
} from '../services/EndpointAddressPolicy';

export type MoonlightAddressFamily = 'ipv4' | 'ipv6' | 'hostname';
export type MoonlightHostType = 'sunshine' | 'gamestream';
export type MoonlightCodecPreference = 'auto' | 'h264' | 'hevc' | 'av1';
export type MoonlightResolutionMode = 'host' | '720p' | '1080p' | '1440p' | '2160p' | 'custom';
export type MoonlightAdaptiveResolution = 'host' | 'device' | 'off';
export type MoonlightAudioChannels = 'stereo' | 'surround51' | 'surround71';
export type MoonlightTouchMode = 'touch' | 'absoluteMouse' | 'relativeMouse';
export type MoonlightInputControlMode = 'adaptive' | 'keyboardMouse' | 'trackpad';
/**
 * Remote keyboard semantics for the Windows virtual-key protocol used by
 * Moonlight. `ask` keeps legacy/local/cloud records compatible and requires a
 * deliberate choice before physical keyboard events are admitted.
 */
export type MoonlightKeyboardTarget = 'ask' | 'windows' | 'macos';
export type MoonlightDiscoveryMode = 'manualOrMdns' | 'manualOnly';
export type MoonlightAddressPreference = 'auto' | 'ipv4' | 'ipv6';
export type MoonlightStreamEncryption = 'auto' | 'required' | 'compatible';
export type MoonlightMeteredNetworkPolicy = 'ask' | 'allow' | 'deny';
export type MoonlightLatencyMode = 'lowLatency' | 'balanced' | 'smooth';
export type MoonlightScalingMode = 'fit' | 'fill' | 'oneToOne';
export type MoonlightBackgroundVideoPolicy = 'drop' | 'pause';
export type MoonlightLogLevel = 'error' | 'info' | 'debug';
export type MoonlightIdentityStorageMode = 'localSecure' | 'cloudEncryptedPending';

/** Official GameStream/Sunshine HTTPS Host Control default. */
export const MOONLIGHT_DEFAULT_HTTPS_PORT: number = 47984;

export interface MoonlightAddress {
  host: string;
  family: MoonlightAddressFamily;
  port: number;
}

export interface MoonlightWakeOnLan {
  enabled: boolean;
  mac: string;
  broadcast: string;
}

export interface MoonlightHost {
  id: string;
  serverUuid: string;
  displayName: string;
  addresses: MoonlightAddress[];
  preferredAddressKey: string;
  /**
   * HTTPS Host Control port advertised by serverinfo. Optional only for
   * records written before this field was persisted; those use 47984.
   */
  httpsPort?: number;
  hostType: MoonlightHostType;
  wakeOnLan: MoonlightWakeOnLan;
  /**
   * Host-card privacy lock. Optional only for records written before the
   * unified host-card interaction was introduced; legacy records are
   * interpreted as unlocked.
   */
  locked?: boolean;
  userOrder: number;
}

export interface MoonlightApp {
  hostId: string;
  appId: string;
  title: string;
  iconRef: string;
  sortOrder: number;
  available: boolean;
  lastCatalogAt: number;
}

export interface MoonlightStreamOverrides {
  codecPreference?: MoonlightCodecPreference;
  resolutionMode?: MoonlightResolutionMode;
  adaptiveResolution?: MoonlightAdaptiveResolution;
  customWidth?: number;
  customHeight?: number;
  fps?: number;
  bitrateKbps?: number;
  hdr?: boolean;
  latencyMode?: MoonlightLatencyMode;
  scalingMode?: MoonlightScalingMode;
}

export interface MoonlightInputOverrides {
  touchMode?: MoonlightTouchMode;
  captureKeyboard?: boolean;
  controllerSlot?: number;
}

export interface MoonlightProfile {
  id: string;
  hostId: string;
  appId: string;
  titleSnapshot: string;
  streamOverrides: MoonlightStreamOverrides;
  inputOverrides: MoonlightInputOverrides;
  favorite: boolean;
  userOrder: number;
  lastUsedAt: number;
}

export interface MoonlightVideoSettings {
  codecPreference: MoonlightCodecPreference;
  resolutionMode: MoonlightResolutionMode;
  /**
   * Additive compatibility field. Records written before adaptive resolution
   * omit it; `host` mode is then interpreted as host-compatible and every
   * other legacy mode as exact. Older app versions safely ignore this field.
   */
  adaptiveResolution?: MoonlightAdaptiveResolution;
  customWidth: number;
  customHeight: number;
  fps: number;
  bitrateKbps: number;
  hdr: boolean;
  yuv444: boolean;
  latencyMode: MoonlightLatencyMode;
  /** Legacy read compatibility; display scale is owned by app common settings. */
  scalingMode?: MoonlightScalingMode;
}

export interface MoonlightAudioSettings {
  enabled: boolean;
  channels: MoonlightAudioChannels;
  volume: number;
  playOnHost: boolean;
}

export interface MoonlightInputSettings {
  touchMode: MoonlightTouchMode;
  /**
   * Additive UI/runtime input preference. Records created before this field
   * are mapped from touchMode so old local/cloud settings remain readable.
   */
  controlMode?: MoonlightInputControlMode;
  /** Additive field; records created before keyboard-target selection omit it. */
  keyboardTarget?: MoonlightKeyboardTarget;
  captureKeyboard: boolean;
  forwardSystemShortcuts: boolean;
  controllerSlot: number;
  enableRumble: boolean;
}

export interface MoonlightNetworkSettings {
  discovery: MoonlightDiscoveryMode;
  preferredAddressFamily: MoonlightAddressPreference;
  streamEncryption: MoonlightStreamEncryption;
  allowLegacySha1: boolean;
  meteredNetwork: MoonlightMeteredNetworkPolicy;
  autoReconnect: boolean;
  reconnectBudgetMs: number;
}

export interface MoonlightBackgroundSettings {
  /** Legacy read compatibility; PIP is owned by app common live-view settings. */
  allowPip?: boolean;
  allowAudioInBackground: boolean;
  noSurfaceVideo: MoonlightBackgroundVideoPolicy;
}

export interface MoonlightSecuritySettings {
  blockCertificateChanges: boolean;
  identityStorage: MoonlightIdentityStorageMode;
}

export interface MoonlightDiagnosticsSettings {
  showPerformanceHud: boolean;
  logLevel: MoonlightLogLevel;
}

export interface MoonlightSettings {
  schemaVersion: number;
  video: MoonlightVideoSettings;
  audio: MoonlightAudioSettings;
  input: MoonlightInputSettings;
  network: MoonlightNetworkSettings;
  background: MoonlightBackgroundSettings;
  security: MoonlightSecuritySettings;
  diagnostics: MoonlightDiagnosticsSettings;
}

export interface MoonlightTrustCandidate {
  hostId: string;
  serverUuid: string;
  serverCertificateSha256: string;
  pairingGeneration: number;
  candidateObservedAt: number;
}

export interface MoonlightIdentityMetadata {
  identityVersion: number;
  certificateSha256: string;
  ownerScopeFingerprint: string;
  storageMode: MoonlightIdentityStorageMode;
  localSecureStoreRef: string;
  createdAt: number;
  rotatedAt: number;
}

export interface MoonlightSettingsAdjustment {
  path: string;
  requested: string;
  effective: string;
  reason: string;
}

export interface MoonlightEffectiveSettings {
  requested: MoonlightSettings;
  effective: MoonlightSettings;
  adjustments: MoonlightSettingsAdjustment[];
}

const ID_MAX_LENGTH: number = 128;
const NAME_MAX_LENGTH: number = 128;
const ADDRESS_MAX_LENGTH: number = 255;
const TITLE_MAX_LENGTH: number = 256;
const ICON_REF_MAX_LENGTH: number = 512;
const SECURE_REF_MAX_LENGTH: number = 256;
const MAX_ADDRESSES: number = 16;

function isFiniteInteger(value: number): boolean {
  return Number.isSafeInteger(value);
}

function isIntegerInRange(value: number, minimum: number, maximum: number): boolean {
  return isFiniteInteger(value) && value >= minimum && value <= maximum;
}

function isBoundedText(value: string, minimum: number, maximum: number): boolean {
  if (typeof value !== 'string' || value.length < minimum || value.length > maximum) {
    return false;
  }
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) { return false; }
  }
  return true;
}

function isOptionalBoundedText(value: string, maximum: number): boolean {
  return value === '' || isBoundedText(value, 1, maximum);
}

function isSha256Hex(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

function isOneOf(value: string, allowed: string[]): boolean {
  return allowed.indexOf(value) >= 0;
}

export function defaultMoonlightSettings(): MoonlightSettings {
  return {
    schemaVersion: 1,
    video: {
      codecPreference: 'auto',
      resolutionMode: 'host',
      adaptiveResolution: 'host',
      customWidth: 1920,
      customHeight: 1080,
      fps: 60,
      bitrateKbps: 20000,
      hdr: false,
      yuv444: false,
      latencyMode: 'lowLatency'
    },
    audio: {
      enabled: true,
      channels: 'stereo',
      volume: 1.0,
      playOnHost: false
    },
    input: {
      touchMode: 'touch',
      controlMode: 'adaptive',
      keyboardTarget: 'ask',
      captureKeyboard: false,
      forwardSystemShortcuts: false,
      controllerSlot: -1,
      enableRumble: false
    },
    network: {
      discovery: 'manualOrMdns',
      preferredAddressFamily: 'auto',
      streamEncryption: 'auto',
      allowLegacySha1: false,
      meteredNetwork: 'ask',
      autoReconnect: true,
      reconnectBudgetMs: 15500
    },
    background: {
      allowAudioInBackground: true,
      noSurfaceVideo: 'drop'
    },
    security: {
      blockCertificateChanges: true,
      identityStorage: 'localSecure'
    },
    diagnostics: {
      showPerformanceHud: false,
      logLevel: 'error'
    }
  };
}

/**
 * Remove fields that predate the common display/live-view ownership split.
 * They remain optional on the DTO so old local records can be read safely,
 * but new local writes must not carry a second Moonlight-owned value.
 */
export function normalizeMoonlightSettingsForLocalStorage(
  settings: MoonlightSettings
): MoonlightSettings {
  const normalized: MoonlightSettings = JSON.parse(JSON.stringify(settings)) as MoonlightSettings;
  normalized.video.scalingMode = undefined;
  normalized.background.allowPip = undefined;
  normalized.input.controlMode = moonlightInputControlMode(
    normalized.input.controlMode, normalized.input.touchMode);
  normalized.input.keyboardTarget = moonlightKeyboardTarget(
    normalized.input.keyboardTarget);
  return normalized;
}

/** Compatibility mapping for settings written before the three-mode control UI. */
export function moonlightInputControlMode(
  value: string | undefined, legacyTouchMode: MoonlightTouchMode = 'touch'
): MoonlightInputControlMode {
  if (value === 'adaptive' || value === 'keyboardMouse' || value === 'trackpad') {
    return value;
  }
  return legacyTouchMode === 'absoluteMouse' || legacyTouchMode === 'relativeMouse' ?
    'trackpad' : 'adaptive';
}

/** Compatibility mapping for settings written before keyboard-target choice. */
export function moonlightKeyboardTarget(
  value: string | undefined
): MoonlightKeyboardTarget {
  if (value === 'windows' || value === 'macos') { return value; }
  return 'ask';
}

export function moonlightAddressKey(address: MoonlightAddress): string {
  const normalized: MoonlightAddress = canonicalMoonlightAddress(address);
  const host: string = normalized.host.toLowerCase();
  return address.family + '|' + host + '|' + address.port.toString();
}

/** Canonical form used for every new durable Moonlight address write. */
export function canonicalMoonlightAddress(address: MoonlightAddress): MoonlightAddress {
  const parsed: EndpointAddressResult = parseEndpointFields(address.host, address.port);
  if (!parsed.ok || parsed.endpoint.scope !== '' || parsed.endpoint.family !== address.family) {
    return { host: address.host.trim(), family: address.family, port: address.port };
  }
  return {
    host: parsed.endpoint.canonicalHost,
    family: address.family,
    port: parsed.endpoint.port
  };
}

export function moonlightAddressIsValid(address: MoonlightAddress): boolean {
  if (address === undefined || address === null || typeof address !== 'object' ||
    typeof address.host !== 'string' || !isBoundedText(address.host, 1, ADDRESS_MAX_LENGTH) ||
    !isOneOf(address.family, ['ipv4', 'ipv6', 'hostname']) ||
    !isIntegerInRange(address.port, 1, 65535)) {
    return false;
  }
  const parsed: EndpointAddressResult = parseEndpointFields(address.host, address.port);
  return parsed.ok && parsed.endpoint.scope === '' && parsed.endpoint.family === address.family;
}

export function moonlightHostIsValid(host: MoonlightHost): boolean {
  if (host === undefined || host === null || typeof host !== 'object' ||
      !Array.isArray(host.addresses) || !isBoundedText(host.id, 1, ID_MAX_LENGTH) ||
      !isBoundedText(host.serverUuid, 1, ID_MAX_LENGTH) ||
      !isBoundedText(host.displayName, 1, NAME_MAX_LENGTH) ||
      (host.httpsPort !== undefined &&
        !isIntegerInRange(host.httpsPort, 1, 65535)) ||
      !isOneOf(host.hostType, ['sunshine', 'gamestream']) ||
      (host.locked !== undefined && typeof host.locked !== 'boolean') ||
      !isIntegerInRange(host.userOrder, 0, 1000000) ||
      host.addresses.length < 1 || host.addresses.length > MAX_ADDRESSES) {
    return false;
  }
  const keys: string[] = [];
  const compatiblePreferredKeys: string[] = [];
  for (let i = 0; i < host.addresses.length; i++) {
    if (!moonlightAddressIsValid(host.addresses[i])) { return false; }
    const key: string = moonlightAddressKey(host.addresses[i]);
    if (keys.indexOf(key) >= 0) { return false; }
    keys.push(key);
    compatiblePreferredKeys.push(host.addresses[i].family + '|' +
      host.addresses[i].host.trim().toLowerCase() + '|' + host.addresses[i].port.toString());
  }
  if (host.preferredAddressKey !== '' && keys.indexOf(host.preferredAddressKey) < 0 &&
    compatiblePreferredKeys.indexOf(host.preferredAddressKey) < 0) {
    return false;
  }
  return moonlightWakeOnLanIsValid(host.wakeOnLan);
}

export function moonlightWakeOnLanIsValid(wakeOnLan: MoonlightWakeOnLan): boolean {
  if (wakeOnLan === undefined || wakeOnLan === null || typeof wakeOnLan !== 'object' ||
      typeof wakeOnLan.enabled !== 'boolean' || typeof wakeOnLan.mac !== 'string' ||
      typeof wakeOnLan.broadcast !== 'string') { return false; }
  if (!wakeOnLan.enabled) {
    return isOptionalBoundedText(wakeOnLan.mac, 32) &&
      isOptionalBoundedText(wakeOnLan.broadcast, ADDRESS_MAX_LENGTH);
  }
  return /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(wakeOnLan.mac) &&
    isBoundedText(wakeOnLan.broadcast, 1, ADDRESS_MAX_LENGTH);
}

export function moonlightAppIsValid(app: MoonlightApp): boolean {
  return isBoundedText(app.hostId, 1, ID_MAX_LENGTH) &&
    isBoundedText(app.appId, 1, ID_MAX_LENGTH) &&
    isBoundedText(app.title, 1, TITLE_MAX_LENGTH) &&
    isOptionalBoundedText(app.iconRef, ICON_REF_MAX_LENGTH) &&
    isIntegerInRange(app.sortOrder, 0, 1000000) &&
    isFiniteInteger(app.lastCatalogAt) && app.lastCatalogAt >= 0;
}

export function moonlightStreamOverridesAreValid(overrides: MoonlightStreamOverrides): boolean {
  if (overrides === undefined || overrides === null || typeof overrides !== 'object') { return false; }
  if (overrides.codecPreference !== undefined &&
      !isOneOf(overrides.codecPreference, ['auto', 'h264', 'hevc', 'av1'])) { return false; }
  if (overrides.resolutionMode !== undefined &&
      !isOneOf(overrides.resolutionMode, ['host', '720p', '1080p', '1440p', '2160p', 'custom'])) {
    return false;
  }
  if (overrides.adaptiveResolution !== undefined &&
      !isOneOf(overrides.adaptiveResolution, ['host', 'device', 'off'])) { return false; }
  if (overrides.customWidth !== undefined && !isIntegerInRange(overrides.customWidth, 320, 7680)) {
    return false;
  }
  if (overrides.customHeight !== undefined && !isIntegerInRange(overrides.customHeight, 240, 4320)) {
    return false;
  }
  if (overrides.fps !== undefined && !isIntegerInRange(overrides.fps, 30, 240)) { return false; }
  if (overrides.bitrateKbps !== undefined && !isIntegerInRange(overrides.bitrateKbps, 1000, 200000)) {
    return false;
  }
  if (overrides.latencyMode !== undefined &&
      !isOneOf(overrides.latencyMode, ['lowLatency', 'balanced', 'smooth'])) { return false; }
  if (overrides.scalingMode !== undefined &&
      !isOneOf(overrides.scalingMode, ['fit', 'fill', 'oneToOne'])) { return false; }
  if (overrides.hdr !== undefined && typeof overrides.hdr !== 'boolean') { return false; }
  return true;
}

export function moonlightInputOverridesAreValid(overrides: MoonlightInputOverrides): boolean {
  if (overrides === undefined || overrides === null || typeof overrides !== 'object') { return false; }
  if (overrides.touchMode !== undefined &&
      !isOneOf(overrides.touchMode, ['touch', 'absoluteMouse', 'relativeMouse'])) { return false; }
  if (overrides.controllerSlot !== undefined &&
      !isIntegerInRange(overrides.controllerSlot, -1, 3)) { return false; }
  if (overrides.captureKeyboard !== undefined && typeof overrides.captureKeyboard !== 'boolean') {
    return false;
  }
  return true;
}

export function moonlightProfileIsValid(profile: MoonlightProfile): boolean {
  return profile !== undefined && profile !== null && typeof profile === 'object' &&
    typeof profile.favorite === 'boolean' && isBoundedText(profile.id, 1, ID_MAX_LENGTH) &&
    isBoundedText(profile.hostId, 1, ID_MAX_LENGTH) &&
    isBoundedText(profile.appId, 1, ID_MAX_LENGTH) &&
    isBoundedText(profile.titleSnapshot, 1, TITLE_MAX_LENGTH) &&
    moonlightStreamOverridesAreValid(profile.streamOverrides) &&
    moonlightInputOverridesAreValid(profile.inputOverrides) &&
    isIntegerInRange(profile.userOrder, 0, 1000000) &&
    isFiniteInteger(profile.lastUsedAt) && profile.lastUsedAt >= 0;
}

export function moonlightSettingsAreValid(settings: MoonlightSettings): boolean {
  if (settings === undefined || settings === null || typeof settings !== 'object' ||
      settings.video === undefined || settings.video === null || typeof settings.video !== 'object' ||
      settings.audio === undefined || settings.audio === null || typeof settings.audio !== 'object' ||
      settings.input === undefined || settings.input === null || typeof settings.input !== 'object' ||
      settings.network === undefined || settings.network === null || typeof settings.network !== 'object' ||
      settings.background === undefined || settings.background === null ||
      typeof settings.background !== 'object' || settings.security === undefined ||
      settings.security === null || typeof settings.security !== 'object' ||
      settings.diagnostics === undefined || settings.diagnostics === null ||
      typeof settings.diagnostics !== 'object') {
    return false;
  }
  const legacyScalingValid: boolean = settings.video.scalingMode === undefined ||
    isOneOf(settings.video.scalingMode, ['fit', 'fill', 'oneToOne']);
  const adaptiveResolutionValid: boolean = settings.video.adaptiveResolution === undefined ||
    isOneOf(settings.video.adaptiveResolution, ['host', 'device', 'off']);
  const legacyPipValid: boolean = settings.background.allowPip === undefined ||
    typeof settings.background.allowPip === 'boolean';
  const controlModeValid: boolean = settings.input.controlMode === undefined ||
    isOneOf(settings.input.controlMode, ['adaptive', 'keyboardMouse', 'trackpad']);
  const keyboardTargetValid: boolean = settings.input.keyboardTarget === undefined ||
    isOneOf(settings.input.keyboardTarget, ['ask', 'windows', 'macos']);
  return settings.schemaVersion === 1 &&
    isOneOf(settings.video.codecPreference, ['auto', 'h264', 'hevc', 'av1']) &&
    isOneOf(settings.video.resolutionMode, ['host', '720p', '1080p', '1440p', '2160p', 'custom']) &&
    adaptiveResolutionValid &&
    isIntegerInRange(settings.video.customWidth, 320, 7680) &&
    isIntegerInRange(settings.video.customHeight, 240, 4320) &&
    isIntegerInRange(settings.video.fps, 30, 240) &&
    isIntegerInRange(settings.video.bitrateKbps, 1000, 200000) &&
    typeof settings.video.hdr === 'boolean' && typeof settings.video.yuv444 === 'boolean' &&
    isOneOf(settings.video.latencyMode, ['lowLatency', 'balanced', 'smooth']) &&
    legacyScalingValid &&
    isOneOf(settings.audio.channels, ['stereo', 'surround51', 'surround71']) &&
    typeof settings.audio.enabled === 'boolean' && typeof settings.audio.playOnHost === 'boolean' &&
    Number.isFinite(settings.audio.volume) && settings.audio.volume >= 0 && settings.audio.volume <= 1 &&
    isOneOf(settings.input.touchMode, ['touch', 'absoluteMouse', 'relativeMouse']) &&
    controlModeValid &&
    keyboardTargetValid &&
    typeof settings.input.captureKeyboard === 'boolean' &&
    typeof settings.input.forwardSystemShortcuts === 'boolean' &&
    typeof settings.input.enableRumble === 'boolean' &&
    isIntegerInRange(settings.input.controllerSlot, -1, 3) &&
    isOneOf(settings.network.discovery, ['manualOrMdns', 'manualOnly']) &&
    isOneOf(settings.network.preferredAddressFamily, ['auto', 'ipv4', 'ipv6']) &&
    isOneOf(settings.network.streamEncryption, ['auto', 'required', 'compatible']) &&
    typeof settings.network.allowLegacySha1 === 'boolean' &&
    typeof settings.network.autoReconnect === 'boolean' &&
    isOneOf(settings.network.meteredNetwork, ['ask', 'allow', 'deny']) &&
    isIntegerInRange(settings.network.reconnectBudgetMs, 0, 120000) &&
    legacyPipValid &&
    typeof settings.background.allowAudioInBackground === 'boolean' &&
    isOneOf(settings.background.noSurfaceVideo, ['drop', 'pause']) &&
    settings.security.blockCertificateChanges &&
    isOneOf(settings.security.identityStorage, ['localSecure', 'cloudEncryptedPending']) &&
    typeof settings.diagnostics.showPerformanceHud === 'boolean' &&
    isOneOf(settings.diagnostics.logLevel, ['error', 'info', 'debug']);
}

export function moonlightTrustCandidateIsValid(candidate: MoonlightTrustCandidate): boolean {
  return isBoundedText(candidate.hostId, 1, ID_MAX_LENGTH) &&
    isBoundedText(candidate.serverUuid, 1, ID_MAX_LENGTH) &&
    isSha256Hex(candidate.serverCertificateSha256) &&
    isFiniteInteger(candidate.pairingGeneration) && candidate.pairingGeneration >= 0 &&
    isFiniteInteger(candidate.candidateObservedAt) && candidate.candidateObservedAt >= 0;
}

export function moonlightIdentityMetadataIsValid(metadata: MoonlightIdentityMetadata): boolean {
  return isIntegerInRange(metadata.identityVersion, 1, 1000) &&
    isSha256Hex(metadata.certificateSha256) &&
    isSha256Hex(metadata.ownerScopeFingerprint) &&
    isOneOf(metadata.storageMode, ['localSecure', 'cloudEncryptedPending']) &&
    isBoundedText(metadata.localSecureStoreRef, 1, SECURE_REF_MAX_LENGTH) &&
    isFiniteInteger(metadata.createdAt) && metadata.createdAt > 0 &&
    isFiniteInteger(metadata.rotatedAt) && metadata.rotatedAt >= 0 &&
    (metadata.rotatedAt === 0 || metadata.rotatedAt >= metadata.createdAt);
}
