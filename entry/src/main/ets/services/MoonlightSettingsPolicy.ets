import {
  defaultMoonlightSettings,
  MoonlightEffectiveSettings,
  MoonlightSettings,
  MoonlightSettingsAdjustment,
  moonlightSettingsAreValid
} from '../model/MoonlightModels';
import { MoonlightEffectiveCapabilities } from './MoonlightCapabilityPolicy';
import { moonlightMutableFieldPaths } from './MoonlightRecordPolicy';

export type MoonlightSettingsLayerScope = 'host' | 'profile' | 'session';

export interface MoonlightSettingsLayer {
  scope: MoonlightSettingsLayerScope;
  values: MoonlightSettings;
  overriddenPaths: string[];
}

const PROFILE_PATH_PREFIXES: string[] = ['video.', 'input.'];
const SESSION_BLOCKED_PATHS: string[] = [
  'security.identityStorage', 'security.blockCertificateChanges', 'network.allowLegacySha1'
];

function cloneSettings(settings: MoonlightSettings): MoonlightSettings {
  return JSON.parse(JSON.stringify(settings)) as MoonlightSettings;
}

function valueAtPath(root: Object, path: string): Object | undefined {
  const parts: string[] = path.split('.');
  let current: Object = root;
  for (let i = 0; i < parts.length; i++) {
    if (current === null || Array.isArray(current) || typeof current !== 'object') { return undefined; }
    const values = current as Record<string, Object>;
    const next: Object | undefined = values[parts[i]];
    if (next === undefined) { return undefined; }
    current = next;
  }
  return current;
}

function setValueAtPath(root: Object, path: string, value: Object): boolean {
  const parts: string[] = path.split('.');
  let current: Object = root;
  for (let i = 0; i < parts.length - 1; i++) {
    if (current === null || Array.isArray(current) || typeof current !== 'object') { return false; }
    const values = current as Record<string, Object>;
    const next: Object | undefined = values[parts[i]];
    if (next === undefined || next === null || Array.isArray(next) || typeof next !== 'object') {
      return false;
    }
    current = next;
  }
  if (current === null || Array.isArray(current) || typeof current !== 'object') { return false; }
  (current as Record<string, Object>)[parts[parts.length - 1]] = value;
  return true;
}

function pathAllowedForLayer(path: string, scope: MoonlightSettingsLayerScope): boolean {
  if (moonlightMutableFieldPaths('settings').indexOf(path) < 0) { return false; }
  if (scope === 'host') { return true; }
  if (scope === 'session') { return SESSION_BLOCKED_PATHS.indexOf(path) < 0; }
  for (let i = 0; i < PROFILE_PATH_PREFIXES.length; i++) {
    if (path.startsWith(PROFILE_PATH_PREFIXES[i])) { return true; }
  }
  return false;
}

function applyLayer(
  target: MoonlightSettings, layer: MoonlightSettingsLayer,
  adjustments: MoonlightSettingsAdjustment[]
): void {
  const seen: string[] = [];
  for (let i = 0; i < layer.overriddenPaths.length; i++) {
    const path: string = layer.overriddenPaths[i];
    if (seen.indexOf(path) >= 0) { continue; }
    seen.push(path);
    if (!pathAllowedForLayer(path, layer.scope)) {
      adjustments.push({
        path: path, requested: '', effective: '', reason: 'override_not_allowed_for_' + layer.scope
      });
      continue;
    }
    const value: Object | undefined = valueAtPath(layer.values as Object, path);
    if (value === undefined || !setValueAtPath(target as Object, path, value)) {
      adjustments.push({ path: path, requested: '', effective: '', reason: 'override_value_missing' });
    }
  }
}

function valueText(value: Object): string {
  if (typeof value === 'string') { return value as string; }
  return JSON.stringify(value);
}

function addAdjustment(
  adjustments: MoonlightSettingsAdjustment[], path: string,
  requested: Object, effective: Object, reason: string
): void {
  adjustments.push({
    path: path,
    requested: valueText(requested),
    effective: valueText(effective),
    reason: reason
  });
}

function bestCodec(capabilities: MoonlightEffectiveCapabilities): string {
  if (capabilities.codecs.indexOf('h264') >= 0) { return 'h264'; }
  return capabilities.codecs.length > 0 ? capabilities.codecs[0] : 'h264';
}

function bestResolution(capabilities: MoonlightEffectiveCapabilities): string {
  const order: string[] = ['2160p', '1440p', '1080p', '720p', 'host'];
  for (let i = 0; i < order.length; i++) {
    if (capabilities.resolutions.indexOf(order[i] as 'host') >= 0) { return order[i]; }
  }
  return 'host';
}

function applyCapabilities(
  requested: MoonlightSettings,
  capabilities: MoonlightEffectiveCapabilities,
  adjustments: MoonlightSettingsAdjustment[]
): MoonlightSettings {
  const effective: MoonlightSettings = cloneSettings(requested);
  const requestedCodec: string = requested.video.codecPreference;
  if (requestedCodec === 'auto') {
    effective.video.codecPreference = bestCodec(capabilities) as 'h264';
    addAdjustment(adjustments, 'video.codecPreference', requestedCodec,
      effective.video.codecPreference, 'auto_selected_from_capability_intersection');
  } else if (capabilities.codecs.indexOf(requested.video.codecPreference) < 0) {
    effective.video.codecPreference = bestCodec(capabilities) as 'h264';
    addAdjustment(adjustments, 'video.codecPreference', requestedCodec,
      effective.video.codecPreference, 'requested_codec_unavailable');
  }

  if (capabilities.resolutions.indexOf(requested.video.resolutionMode) < 0) {
    effective.video.resolutionMode = bestResolution(capabilities) as 'host';
    addAdjustment(adjustments, 'video.resolutionMode', requested.video.resolutionMode,
      effective.video.resolutionMode, 'requested_resolution_unavailable');
  }
  if (capabilities.maxWidth > 0 && effective.video.customWidth > capabilities.maxWidth) {
    effective.video.customWidth = capabilities.maxWidth;
    addAdjustment(adjustments, 'video.customWidth', requested.video.customWidth,
      effective.video.customWidth, 'device_or_host_width_limit');
  }
  if (capabilities.maxHeight > 0 && effective.video.customHeight > capabilities.maxHeight) {
    effective.video.customHeight = capabilities.maxHeight;
    addAdjustment(adjustments, 'video.customHeight', requested.video.customHeight,
      effective.video.customHeight, 'device_or_host_height_limit');
  }
  if (capabilities.maxFps > 0 && effective.video.fps > capabilities.maxFps) {
    effective.video.fps = capabilities.maxFps;
    addAdjustment(adjustments, 'video.fps', requested.video.fps,
      effective.video.fps, 'device_or_host_fps_limit');
  }
  if (effective.video.hdr && !capabilities.hdr) {
    effective.video.hdr = false;
    addAdjustment(adjustments, 'video.hdr', true, false, 'hdr_pipeline_unavailable');
  }
  if (effective.video.yuv444 && !capabilities.yuv444) {
    effective.video.yuv444 = false;
    addAdjustment(adjustments, 'video.yuv444', true, false, 'yuv444_pipeline_unavailable');
  }
  if (capabilities.audioChannels.indexOf(effective.audio.channels) < 0) {
    const fallback: string = capabilities.audioChannels.indexOf('stereo') >= 0 ? 'stereo' : 'stereo';
    effective.audio.channels = fallback as 'stereo';
    addAdjustment(adjustments, 'audio.channels', requested.audio.channels,
      effective.audio.channels, 'requested_audio_layout_unavailable');
  }
  if (effective.input.touchMode === 'relativeMouse' && !capabilities.relativePointer) {
    effective.input.touchMode = 'absoluteMouse';
    addAdjustment(adjustments, 'input.touchMode', 'relativeMouse', 'absoluteMouse',
      'relative_pointer_unavailable');
  }
  if (effective.input.enableRumble && !capabilities.controllerRumble) {
    effective.input.enableRumble = false;
    addAdjustment(adjustments, 'input.enableRumble', true, false, 'controller_feedback_unavailable');
  }
  return effective;
}

export function resolveEffectiveMoonlightSettings(
  globalSettings: MoonlightSettings,
  hostLayer: MoonlightSettingsLayer | null,
  profileLayer: MoonlightSettingsLayer | null,
  sessionLayer: MoonlightSettingsLayer | null,
  capabilities: MoonlightEffectiveCapabilities
): MoonlightEffectiveSettings {
  const adjustments: MoonlightSettingsAdjustment[] = [];
  const requested: MoonlightSettings = moonlightSettingsAreValid(globalSettings) ?
    cloneSettings(globalSettings) : defaultMoonlightSettings();
  if (!moonlightSettingsAreValid(globalSettings)) {
    adjustments.push({
      path: '*', requested: 'invalid_global_settings', effective: 'safe_defaults',
      reason: 'invalid_global_settings'
    });
  }
  if (hostLayer !== null) { applyLayer(requested, hostLayer, adjustments); }
  if (profileLayer !== null) { applyLayer(requested, profileLayer, adjustments); }
  if (sessionLayer !== null) { applyLayer(requested, sessionLayer, adjustments); }
  if (!moonlightSettingsAreValid(requested)) {
    adjustments.push({
      path: '*', requested: 'invalid_layer_result', effective: 'safe_defaults',
      reason: 'invalid_override_value'
    });
    const safe: MoonlightSettings = defaultMoonlightSettings();
    return { requested: safe, effective: applyCapabilities(safe, capabilities, adjustments),
      adjustments: adjustments };
  }
  return {
    requested: cloneSettings(requested),
    effective: applyCapabilities(requested, capabilities, adjustments),
    adjustments: adjustments
  };
}

/**
 * Product truth for the currently shipped HarmonyOS media/input runtime.
 * Keep this projection conservative until a real device probe is carried in
 * the launch lease. User intent remains in `requested`; only `effective` is
 * allowed to reach host launch, NAPI and common-c.
 */
export function resolveMoonlightProductSettings(
  settings: MoonlightSettings
): MoonlightEffectiveSettings {
  const capabilities: MoonlightEffectiveCapabilities = {
    codecs: ['h264'],
    resolutions: ['host', '720p', '1080p'],
    audioChannels: ['stereo'],
    hdr: false,
    yuv444: false,
    relativePointer: false,
    gameControllerInput: true,
    controllerRumble: false,
    pip: false,
    maxWidth: 1920,
    maxHeight: 1080,
    maxFps: 60,
    hostControlReady: true,
    streamingTransportReady: true,
    reasons: []
  };
  const resolved: MoonlightEffectiveSettings = resolveEffectiveMoonlightSettings(
    settings, null, null, null, capabilities);
  if (resolved.effective.network.streamEncryption === 'required') {
    addAdjustment(resolved.adjustments, 'network.streamEncryption', 'required', 'auto',
      'required_encryption_proof_unavailable');
    resolved.effective.network.streamEncryption = 'auto';
  }
  if (resolved.effective.video.latencyMode !== 'lowLatency') {
    addAdjustment(resolved.adjustments, 'video.latencyMode',
      resolved.requested.video.latencyMode, 'lowLatency', 'product_low_latency_only');
    resolved.effective.video.latencyMode = 'lowLatency';
  }
  // The single product controller mapper currently owns Sunshine slot 0. Keep
  // Auto and explicit slot choices as durable intent, but never advertise a
  // different slot in the launch bitmap until the mapper itself is multi-slot.
  if (resolved.effective.input.controllerSlot !== 0) {
    addAdjustment(resolved.adjustments, 'input.controllerSlot',
      resolved.requested.input.controllerSlot, 0, 'product_controller_slot_zero');
    resolved.effective.input.controllerSlot = 0;
  }
  if (resolved.effective.input.forwardSystemShortcuts) {
    addAdjustment(resolved.adjustments, 'input.forwardSystemShortcuts', true, false,
      'product_system_shortcuts_unavailable');
    resolved.effective.input.forwardSystemShortcuts = false;
  }
  // The current Surface lifecycle keeps the one common-c connection alive,
  // drops video while no render target exists, then requests a fresh frame on
  // rebind. A persisted legacy `pause` value must not imply a second behavior.
  if (resolved.effective.background.noSurfaceVideo !== 'drop') {
    addAdjustment(resolved.adjustments, 'background.noSurfaceVideo',
      resolved.requested.background.noSurfaceVideo, 'drop',
      'product_no_surface_drop_only');
    resolved.effective.background.noSurfaceVideo = 'drop';
  }
  // Session diagnostics currently expose a bounded low-frequency snapshot and
  // sanitized copy action. Verbose native logging is not a product capability.
  if (resolved.effective.diagnostics.logLevel !== 'error') {
    addAdjustment(resolved.adjustments, 'diagnostics.logLevel',
      resolved.requested.diagnostics.logLevel, 'error',
      'product_verbose_logging_unavailable');
    resolved.effective.diagnostics.logLevel = 'error';
  }
  return resolved;
}

function adjustmentIsValid(value: MoonlightSettingsAdjustment): boolean {
  return value !== undefined && value !== null && typeof value === 'object' &&
    typeof value.path === 'string' && value.path.length > 0 && value.path.length <= 128 &&
    typeof value.requested === 'string' && value.requested.length <= 256 &&
    typeof value.effective === 'string' && value.effective.length <= 256 &&
    typeof value.reason === 'string' && value.reason.length > 0 && value.reason.length <= 128;
}

export function moonlightEffectiveSettingsAreValid(value: MoonlightEffectiveSettings): boolean {
  if (value === undefined || value === null || typeof value !== 'object' ||
      !moonlightSettingsAreValid(value.requested) ||
      !moonlightSettingsAreValid(value.effective) ||
      !Array.isArray(value.adjustments) || value.adjustments.length > 64) {
    return false;
  }
  for (let index: number = 0; index < value.adjustments.length; index++) {
    if (!adjustmentIsValid(value.adjustments[index])) { return false; }
  }
  return true;
}

export function encodeMoonlightEffectiveSettings(value: MoonlightEffectiveSettings): string {
  if (!moonlightEffectiveSettingsAreValid(value)) { return ''; }
  const encoded: string = JSON.stringify(value);
  return encoded.length > 0 && encoded.length <= 32768 ? encoded : '';
}

export function decodeMoonlightEffectiveSettings(encoded: string): MoonlightEffectiveSettings | null {
  if (typeof encoded !== 'string' || encoded.length === 0 || encoded.length > 32768) { return null; }
  try {
    const value: MoonlightEffectiveSettings = JSON.parse(encoded) as MoonlightEffectiveSettings;
    return moonlightEffectiveSettingsAreValid(value) ? value : null;
  } catch (_) {
    return null;
  }
}
