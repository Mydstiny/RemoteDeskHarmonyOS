import {
  VncColorDepth,
  VncDisplayScaleMode,
  VncHostValues,
  VncImageQualityPreset,
  VncLocalCursorMode,
  VncPreferredEncoding,
  VncSecurityPolicy,
  VncSettingsValues
} from './VncModelPolicy';

export interface EffectiveVncSessionSettings {
  viewOnly: boolean;
  clipboardEnabled: boolean;
  securityPolicy: VncSecurityPolicy;
  tls: boolean;
  controlMode: number;
  displayScaleMode: VncDisplayScaleMode;
  customScalePercent: number;
  imageQualityPreset: VncImageQualityPreset;
  preferredEncoding: VncPreferredEncoding;
  colorDepth: VncColorDepth;
  frameRateLimit: number;
  localCursorMode: VncLocalCursorMode;
  touchpadSpeed: number;
  reverseWheel: boolean;
  swapMouseButtons: boolean;
  showDiagnostics: boolean;
  diagnosticsExpanded: boolean;
  diagnosticsRefreshMs: number;
  diagnosticsMetricMask: number;
}

function displayModeFromHost(host: VncHostValues): VncDisplayScaleMode {
  if (host.scalingMode === 'integer') { return 'integer'; }
  if (host.scalingMode === 'one_to_one' || host.scalingMode === 'pan') { return '100'; }
  return 'fit';
}

/** Resolve one immutable VNC-only preference snapshot at route entry. */
export function resolveEffectiveVncSessionSettings(settings: VncSettingsValues,
  host: VncHostValues): EffectiveVncSessionSettings {
  return {
    viewOnly: host.viewOnly,
    clipboardEnabled: host.clipboardEnabled,
    securityPolicy: host.securityPolicy,
    tls: host.tls,
    controlMode: settings.controlMode,
    displayScaleMode: host.displayOverrideEnabled ?
      displayModeFromHost(host) : settings.displayScaleMode,
    customScalePercent: settings.customScalePercent,
    imageQualityPreset: settings.imageQualityPreset,
    preferredEncoding: settings.preferredEncoding,
    colorDepth: settings.colorDepth,
    frameRateLimit: settings.frameRateLimit,
    localCursorMode: settings.localCursorMode,
    touchpadSpeed: settings.touchpadSpeed,
    reverseWheel: settings.reverseWheel,
    swapMouseButtons: settings.swapMouseButtons,
    showDiagnostics: settings.showDiagnostics,
    diagnosticsExpanded: settings.diagnosticsExpanded,
    diagnosticsRefreshMs: settings.diagnosticsRefreshMs,
    diagnosticsMetricMask: settings.diagnosticsMetricMask
  };
}
