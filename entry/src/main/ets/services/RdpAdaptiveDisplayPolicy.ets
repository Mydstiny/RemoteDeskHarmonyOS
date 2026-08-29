export type RdpRemoteUiScalePreference = 'auto' | '100' | '140' | '180';

export type RdpDisplayFallbackReason =
  'none' | 'invalid_surface' | 'dpi_scale_unavailable' | 'max_edge_limited';

export interface RdpAdaptiveDisplayInput {
  surfaceWidthPx: number;
  surfaceHeightPx: number;
  densityPixels: number;
  densityDpi: number;
  uiScalePreference: string;
  dpiScaleSupported: boolean;
  maxEdgePx?: number;
}

export interface RdpAdaptiveDisplayResult {
  width: number;
  height: number;
  desktopScaleFactor: number;
  deviceScaleFactor: number;
  physicalWidthMm: number;
  physicalHeightMm: number;
  orientation: number;
  requestedUiScale: number;
  usesDpiScale: boolean;
  fallbackReason: RdpDisplayFallbackReason;
}

export const RDP_ADAPTIVE_MAX_EDGE_PX: number = 3840;
export const RDP_DYNAMIC_LAYOUT_SETTLE_MS: number = 500;

function validPositive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function evenDimension(value: number): number {
  const rounded: number = Math.max(200, Math.round(value));
  return rounded % 2 === 0 ? rounded : rounded - 1;
}

export function normalizeRdpRemoteUiScalePreference(value: string): RdpRemoteUiScalePreference {
  if (value === '100' || value === '140' || value === '180') {
    return value;
  }
  return 'auto';
}

export function resolveRdpRemoteUiScale(value: string, densityPixels: number): number {
  const preference: RdpRemoteUiScalePreference = normalizeRdpRemoteUiScalePreference(value);
  if (preference !== 'auto') {
    return Number(preference);
  }
  const density: number = validPositive(densityPixels) ? densityPixels : 1;
  if (density < 1.2) { return 100; }
  if (density < 1.7) { return 140; }
  return 180;
}

export function rdpRemoteUiScaleLabel(value: string): string {
  const preference: RdpRemoteUiScalePreference = normalizeRdpRemoteUiScalePreference(value);
  if (preference === '100') { return '标准'; }
  if (preference === '140') { return '大'; }
  if (preference === '180') { return '特大'; }
  return '自动';
}

function physicalMillimetres(pixels: number, densityDpi: number): number {
  if (!validPositive(pixels) || !validPositive(densityDpi)) { return 0; }
  return Math.max(10, Math.min(10000, Math.round(pixels * 25.4 / densityDpi)));
}

/**
 * Resolves the single-monitor RDP geometry contract. Both axes always use the
 * same multiplier, so contain rendering does not gain ratio black bars merely
 * because the local display is high-density.
 */
export function resolveRdpAdaptiveDisplay(input: RdpAdaptiveDisplayInput): RdpAdaptiveDisplayResult {
  if (!validPositive(input.surfaceWidthPx) || !validPositive(input.surfaceHeightPx)) {
    return {
      width: 1920,
      height: 1080,
      desktopScaleFactor: 100,
      deviceScaleFactor: 100,
      physicalWidthMm: 0,
      physicalHeightMm: 0,
      orientation: 0,
      requestedUiScale: 100,
      usesDpiScale: false,
      fallbackReason: 'invalid_surface'
    };
  }

  const requestedUiScale: number = resolveRdpRemoteUiScale(
    input.uiScalePreference, input.densityPixels);
  const requestedMaxEdge: number = input.maxEdgePx ?? 0;
  const maxEdge: number = validPositive(requestedMaxEdge) ?
    Math.max(200, Math.min(8192, Math.round(requestedMaxEdge))) :
    RDP_ADAPTIVE_MAX_EDGE_PX;
  const dpiMultiplier: number = input.dpiScaleSupported ? 1 : 100 / requestedUiScale;
  let width: number = input.surfaceWidthPx * dpiMultiplier;
  let height: number = input.surfaceHeightPx * dpiMultiplier;
  const longEdge: number = Math.max(width, height);
  const capMultiplier: number = longEdge > maxEdge ? maxEdge / longEdge : 1;
  width *= capMultiplier;
  height *= capMultiplier;

  let fallbackReason: RdpDisplayFallbackReason = 'none';
  if (!input.dpiScaleSupported && requestedUiScale > 100) {
    fallbackReason = 'dpi_scale_unavailable';
  } else if (capMultiplier < 1) {
    fallbackReason = 'max_edge_limited';
  }
  return {
    width: evenDimension(width),
    height: evenDimension(height),
    desktopScaleFactor: input.dpiScaleSupported ? requestedUiScale : 100,
    deviceScaleFactor: input.dpiScaleSupported ? requestedUiScale : 100,
    physicalWidthMm: physicalMillimetres(input.surfaceWidthPx, input.densityDpi),
    physicalHeightMm: physicalMillimetres(input.surfaceHeightPx, input.densityDpi),
    orientation: input.surfaceWidthPx >= input.surfaceHeightPx ? 0 : 90,
    requestedUiScale,
    usesDpiScale: input.dpiScaleSupported && requestedUiScale > 100,
    fallbackReason
  };
}
