export type LocalViewScaleMode = 'fit' | '100' | '125' | '150' | '175' | '200' | 'custom';

// The first shared-display implementation persisted a derived value without
// recording whether the user had actually selected it.  Versioned values are
// user intent; older values are repaired to the previous Fit behaviour.
export const REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY: string =
  'remoteDisplayScalePreferenceVersion';
export const REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION: number = 1;

export interface CanvasViewport {
  surfaceWidth: number;
  surfaceHeight: number;
  sourceWidth: number;
  sourceHeight: number;
}

export interface CanvasTransform {
  // Multiplier applied to the renderer's contain scale.
  scale: number;
  // Translation in physical surface pixels, using a top-left origin.
  panX: number;
  panY: number;
}

interface CanvasScaleLimits {
  min: number;
  max: number;
}

function positive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

export function normalizeLocalViewScaleMode(value: string): LocalViewScaleMode {
  if (value === '100' || value === '125' || value === '150' || value === '175' ||
    value === '200' || value === 'custom') {
    return value;
  }
  // Released RustDesk values remain readable during the settings migration.
  if (value === 'original') {
    return '100';
  }
  return 'fit';
}

/** Resolve a stored display scale without turning an old derived value into a new default. */
export function resolveInitialRemoteDisplayScaleMode(value: string, preferenceVersion: number): LocalViewScaleMode {
  if (Number.isFinite(preferenceVersion) && preferenceVersion >= REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION) {
    return normalizeLocalViewScaleMode(value);
  }
  return 'fit';
}

export function localViewScalePercent(mode: LocalViewScaleMode, customPercent: number): number {
  if (mode === '100') { return 100; }
  if (mode === '125') { return 125; }
  if (mode === '150') { return 150; }
  if (mode === '175') { return 175; }
  if (mode === '200') { return 200; }
  if (mode === 'custom') {
    return clamp(Number.isFinite(customPercent) ? customPercent : 100, 50, 300);
  }
  return 0;
}

export function containScale(viewport: CanvasViewport): number {
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  return Math.min(surfaceWidth / sourceWidth, surfaceHeight / sourceHeight);
}

function scaleLimits(viewport: CanvasViewport): CanvasScaleLimits {
  const fit: number = containScale(viewport);
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  return {
    // Keep the official mobile lower-bound behaviour, while permitting the
    // product's 200% preset on small high-density displays.
    min: Math.max(0.05, fit / 1.5),
    max: Math.max(3, surfaceWidth / sourceWidth, surfaceHeight / sourceHeight)
  };
}

function absoluteScale(transform: CanvasTransform, viewport: CanvasViewport): number {
  return containScale(viewport) * Math.max(0.01, transform.scale);
}

export function clampCanvasTransform(transform: CanvasTransform, viewport: CanvasViewport): CanvasTransform {
  const fit: number = containScale(viewport);
  const limits: CanvasScaleLimits = scaleLimits(viewport);
  const physicalScale: number = clamp(absoluteScale(transform, viewport), limits.min, limits.max);
  const scale: number = physicalScale / fit;
  const contentWidth: number = positive(viewport.sourceWidth, 1) * physicalScale;
  const contentHeight: number = positive(viewport.sourceHeight, 1) * physicalScale;
  const maxPanX: number = Math.max(0, (contentWidth - positive(viewport.surfaceWidth, 1)) / 2);
  const maxPanY: number = Math.max(0, (contentHeight - positive(viewport.surfaceHeight, 1)) / 2);
  return {
    scale,
    panX: clamp(Number.isFinite(transform.panX) ? transform.panX : 0, -maxPanX, maxPanX),
    panY: clamp(Number.isFinite(transform.panY) ? transform.panY : 0, -maxPanY, maxPanY)
  };
}

export function baseCanvasTransform(mode: LocalViewScaleMode, customPercent: number,
  viewport: CanvasViewport): CanvasTransform {
  const fit: number = containScale(viewport);
  const percent: number = localViewScalePercent(mode, customPercent);
  const physicalScale: number = percent > 0 ? percent / 100 : fit;
  return clampCanvasTransform({ scale: physicalScale / fit, panX: 0, panY: 0 }, viewport);
}

/** Apply a RustDesk-mobile-style relative pinch plus focal-point pan. */
export function pinchCanvasTransform(current: CanvasTransform, viewport: CanvasViewport,
  focalX: number, focalY: number, relativeScale: number, panDeltaX: number,
  panDeltaY: number): CanvasTransform {
  const old: CanvasTransform = clampCanvasTransform(current, viewport);
  const oldScale: number = absoluteScale(old, viewport);
  const nextScale: number = oldScale * clamp(relativeScale, 0.5, 2.0);
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  const oldLeft: number = (surfaceWidth - sourceWidth * oldScale) / 2 + old.panX;
  const oldTop: number = (surfaceHeight - sourceHeight * oldScale) / 2 + old.panY;
  const remoteAtFocalX: number = (focalX - oldLeft) / oldScale;
  const remoteAtFocalY: number = (focalY - oldTop) / oldScale;
  const newLeft: number = (surfaceWidth - sourceWidth * nextScale) / 2;
  const newTop: number = (surfaceHeight - sourceHeight * nextScale) / 2;
  return clampCanvasTransform({
    scale: nextScale / containScale(viewport),
    panX: focalX - newLeft - remoteAtFocalX * nextScale + panDeltaX,
    panY: focalY - newTop - remoteAtFocalY * nextScale + panDeltaY
  }, viewport);
}
