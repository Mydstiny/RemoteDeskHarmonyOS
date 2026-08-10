export type LocalViewScaleMode = 'fit' | '100' | '125' | '150' | '175' | '200' | 'custom';

// Keep the ArkTS geometry mirror aligned with GLRenderer::SetCanvasTransform.
export const CANVAS_TRANSFORM_MAX_SCALE: number = 12;
// RDP keeps a near-half-surface per-axis drag reserve once the canvas is
// enlarged beyond Fit. This leaves a useful portion visible at the boundary
// while avoiding the short travel caused by strict content-edge clamping.
export const RDP_CANVAS_FREE_PAN_INSET_RATIO: number = 0.45;

// The first shared-display implementation persisted a derived value without
// recording whether the user had actually selected it.  Versioned values are
// user intent; older values are repaired to the previous Fit behaviour.
export const REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY: string =
  'remoteDisplayScalePreferenceVersion';
// Version 1 was written by the first rollout before we could distinguish an
// inherited 100% value from an explicit user choice.  Treat it as a legacy
// derived value once more so affected installations return to the historical
// Fit default.  Choices made by this version and later remain user intent.
export const REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION: number = 2;

export interface CanvasViewport {
  surfaceWidth: number;
  surfaceHeight: number;
  sourceWidth: number;
  sourceHeight: number;
  // Optional per-axis surface reserve for protocols that support bounded
  // free-pan. A missing/zero value preserves strict content-edge clamping.
  freePanInsetRatio?: number;
}

export interface CanvasTransform {
  // Multiplier applied to the renderer's contain scale.
  scale: number;
  // Translation in physical surface pixels, using a top-left origin.
  panX: number;
  panY: number;
  // Clockwise quarter turns applied to the remote canvas.  Keep this optional
  // so persisted/legacy transform literals continue to be valid.
  rotation?: number;
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

/** Normalize a canvas rotation to clockwise quarter turns in [0, 3]. */
export function normalizeCanvasRotation(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return 0;
  }
  const rounded: number = Math.round(value) % 4;
  return rounded < 0 ? rounded + 4 : rounded;
}

function displayedSourceWidth(transform: CanvasTransform, viewport: CanvasViewport): number {
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  return normalizeCanvasRotation(transform.rotation) % 2 === 1 ? sourceHeight : sourceWidth;
}

function displayedSourceHeight(transform: CanvasTransform, viewport: CanvasViewport): number {
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  return normalizeCanvasRotation(transform.rotation) % 2 === 1 ? sourceWidth : sourceHeight;
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

/** Resolve a stored display scale while preserving explicit state across app updates. */
export function resolveInitialRemoteDisplayScaleMode(value: string, preferenceVersion: number,
  storedPreferencePresent: boolean = false): LocalViewScaleMode {
  if (storedPreferencePresent ||
    (Number.isFinite(preferenceVersion) && preferenceVersion >= REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION)) {
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

function containScaleForRotation(viewport: CanvasViewport, rotation: number): number {
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  const sourceWidth: number = positive(viewport.sourceWidth, 1);
  const sourceHeight: number = positive(viewport.sourceHeight, 1);
  const displayWidth: number = rotation % 2 === 1 ? sourceHeight : sourceWidth;
  const displayHeight: number = rotation % 2 === 1 ? sourceWidth : sourceHeight;
  return Math.min(surfaceWidth / displayWidth, surfaceHeight / displayHeight);
}

function scaleLimits(viewport: CanvasViewport, rotation: number): CanvasScaleLimits {
  const fit: number = containScaleForRotation(viewport, rotation);
  const sourceWidth: number = rotation % 2 === 1 ?
    positive(viewport.sourceHeight, 1) : positive(viewport.sourceWidth, 1);
  const sourceHeight: number = rotation % 2 === 1 ?
    positive(viewport.sourceWidth, 1) : positive(viewport.sourceHeight, 1);
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  return {
    // Keep the official mobile lower-bound behaviour, while permitting the
    // product's 200% preset on small high-density displays.
    min: Math.max(0.05, fit / 1.5),
    max: Math.min(CANVAS_TRANSFORM_MAX_SCALE * fit,
      Math.max(3, surfaceWidth / sourceWidth, surfaceHeight / sourceHeight))
  };
}

function absoluteScale(transform: CanvasTransform, viewport: CanvasViewport): number {
  return containScaleForRotation(viewport, normalizeCanvasRotation(transform.rotation)) *
    Math.max(0.01, transform.scale);
}

function freePanInsetRatio(transformScale: number, viewport: CanvasViewport): number {
  if (transformScale <= 1.0005) {
    return 0;
  }
  let ratio: number = 0;
  if (viewport.freePanInsetRatio !== undefined && Number.isFinite(viewport.freePanInsetRatio)) {
    ratio = viewport.freePanInsetRatio;
  }
  return clamp(ratio, 0, 0.5);
}

export function clampCanvasTransform(transform: CanvasTransform, viewport: CanvasViewport): CanvasTransform {
  const rotation: number = normalizeCanvasRotation(transform.rotation);
  const fit: number = containScaleForRotation(viewport, rotation);
  const limits: CanvasScaleLimits = scaleLimits(viewport, rotation);
  const physicalScale: number = clamp(absoluteScale(transform, viewport), limits.min, limits.max);
  const scale: number = physicalScale / fit;
  const contentWidth: number = (rotation % 2 === 1 ?
    positive(viewport.sourceHeight, 1) : positive(viewport.sourceWidth, 1)) * physicalScale;
  const contentHeight: number = (rotation % 2 === 1 ?
    positive(viewport.sourceWidth, 1) : positive(viewport.sourceHeight, 1)) * physicalScale;
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  const insetRatio: number = freePanInsetRatio(scale, viewport);
  const maxPanX: number = Math.max(0, (contentWidth - surfaceWidth) / 2,
    surfaceWidth * insetRatio);
  const maxPanY: number = Math.max(0, (contentHeight - surfaceHeight) / 2,
    surfaceHeight * insetRatio);
  return {
    scale,
    panX: clamp(Number.isFinite(transform.panX) ? transform.panX : 0, -maxPanX, maxPanX),
    panY: clamp(Number.isFinite(transform.panY) ? transform.panY : 0, -maxPanY, maxPanY),
    rotation
  };
}

/** Whether the current canvas has content outside the surface that can be panned. */
export function canvasTransformCanPan(transform: CanvasTransform, viewport: CanvasViewport): boolean {
  const clamped: CanvasTransform = clampCanvasTransform(transform, viewport);
  if (freePanInsetRatio(clamped.scale, viewport) > 0) {
    return true;
  }
  const physicalScale: number = absoluteScale(clamped, viewport);
  const sourceWidth: number = displayedSourceWidth(clamped, viewport);
  const sourceHeight: number = displayedSourceHeight(clamped, viewport);
  const surfaceWidth: number = positive(viewport.surfaceWidth, 1);
  const surfaceHeight: number = positive(viewport.surfaceHeight, 1);
  return sourceWidth * physicalScale > surfaceWidth + 0.5 ||
    sourceHeight * physicalScale > surfaceHeight + 0.5;
}

/** Apply a local two-finger canvas pan in surface pixels and keep it bounded. */
export function panCanvasTransform(current: CanvasTransform, viewport: CanvasViewport,
  panDeltaX: number, panDeltaY: number): CanvasTransform {
  const old: CanvasTransform = clampCanvasTransform(current, viewport);
  const deltaX: number = Number.isFinite(panDeltaX) ? panDeltaX : 0;
  const deltaY: number = Number.isFinite(panDeltaY) ? panDeltaY : 0;
  return clampCanvasTransform({
    scale: old.scale,
    panX: old.panX + deltaX,
    panY: old.panY + deltaY,
    rotation: old.rotation
  }, viewport);
}

export function baseCanvasTransform(mode: LocalViewScaleMode, customPercent: number,
  viewport: CanvasViewport, rotation: number = 0): CanvasTransform {
  const normalizedRotation: number = normalizeCanvasRotation(rotation);
  const fit: number = containScaleForRotation(viewport, normalizedRotation);
  const percent: number = localViewScalePercent(mode, customPercent);
  const physicalScale: number = percent > 0 ? percent / 100 : fit;
  return clampCanvasTransform({
    scale: physicalScale / fit,
    panX: 0,
    panY: 0,
    rotation: normalizedRotation
  }, viewport);
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
  const sourceWidth: number = displayedSourceWidth(old, viewport);
  const sourceHeight: number = displayedSourceHeight(old, viewport);
  const oldLeft: number = (surfaceWidth - sourceWidth * oldScale) / 2 + old.panX;
  const oldTop: number = (surfaceHeight - sourceHeight * oldScale) / 2 + old.panY;
  const remoteAtFocalX: number = (focalX - oldLeft) / oldScale;
  const remoteAtFocalY: number = (focalY - oldTop) / oldScale;
  const newLeft: number = (surfaceWidth - sourceWidth * nextScale) / 2;
  const newTop: number = (surfaceHeight - sourceHeight * nextScale) / 2;
  return clampCanvasTransform({
    scale: nextScale / containScaleForRotation(viewport, normalizeCanvasRotation(old.rotation)),
    panX: focalX - newLeft - remoteAtFocalX * nextScale + panDeltaX,
    panY: focalY - newTop - remoteAtFocalY * nextScale + panDeltaY,
    rotation: old.rotation
  }, viewport);
}
