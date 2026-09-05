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

export interface RdpConfirmedDesktopGeometry {
  width: number;
  height: number;
}

export type RdpInputGeometryObservationStatus = 'stale' | 'pending' | 'confirmed';

export interface RdpInputGeometryObservation {
  status: RdpInputGeometryObservationStatus;
  geometry: RdpConfirmedDesktopGeometry | null;
  geometryChanged: boolean;
  inputReady: boolean;
}

export interface RdpInputReadinessTransition {
  inputReady: boolean;
  becameReady: boolean;
}

export interface RdpGeometryInputReleaseHooks {
  discardPendingMouseMove: () => void;
  releaseCanvasPinchInput: () => void;
  releaseAllHeldKeys: () => void;
  releaseHeldPointerState: () => void;
  resetTouchGesture: () => void;
  resetAllLatches: () => void;
  resetTouchpadState: () => void;
  invalidateViewport: () => void;
}

export interface RdpRestoreGeometryHooks {
  blockInputUntilConfirmed: () => void;
  synchronizeGeometry: () => void;
  startRenderWatchdog: () => void;
  startNativeStateMonitor: () => void;
}

export const RDP_ADAPTIVE_MAX_EDGE_PX: number = 3840;
export const RDP_DYNAMIC_LAYOUT_SETTLE_MS: number = 500;
export const RDP_INPUT_STABILITY_DELAY_MS: number = 2000;

export function shouldUseRdpPcAdaptiveDisplay(isDesktopDevice: boolean,
  resolutionId: string): boolean {
  return isDesktopDevice && resolutionId === 'auto';
}

/** PC auto starts conservatively then upgrades through Display Control. Fixed
 * layouts and mobile adaptive sessions have no later window-follow upgrade,
 * so their connection handshake must carry the requested Windows DPI scale. */
export function shouldUseRdpInitialDpiScale(isDesktopDevice: boolean,
  resolutionId: string): boolean {
  return !isDesktopDevice || resolutionId !== 'auto';
}

/** A display move can change either the auto desktop geometry or the auto DPI
 * scale. Fixed geometry therefore still needs a refresh when UI scale is auto. */
export function shouldRefreshRdpLayoutOnDisplayChange(resolutionId: string,
  uiScalePreference: string): boolean {
  return resolutionId === 'auto' ||
    normalizeRdpRemoteUiScalePreference(uiScalePreference) === 'auto';
}

/** A window-follow event is a no-op for fixed resolution and must not replace
 * an already scheduled explicit/DPI-only refresh. */
export function shouldReplaceRdpDynamicLayoutTimer(resolutionId: string,
  windowFollowingOnly: boolean): boolean {
  return !windowFollowingOnly || resolutionId === 'auto';
}

export function rdpSessionOrientationPolicy(isDesktopDevice: boolean,
  resolutionId: string): 'unspecified' | 'landscape' {
  return shouldUseRdpPcAdaptiveDisplay(isDesktopDevice, resolutionId) ?
    'unspecified' : 'landscape';
}

export function shouldAttemptInitialRdpDynamicUpgrade(displayControlReady: boolean,
  displayControlDisabled: boolean, requestCount: number): boolean {
  return displayControlReady && !displayControlDisabled && requestCount === 0;
}

/**
 * Collapse the independent-window video-stability and geometry barriers into
 * one edge-triggered decision. Whichever barrier completes last owns the sole
 * ready publication, so a slow Display Control resize cannot miss handoff.
 */
export function resolveRdpInputReadinessTransition(previousReady: boolean,
  connected: boolean, sessionId: number, stabilityGateReady: boolean,
  geometryReady: boolean): RdpInputReadinessTransition {
  const inputReady: boolean = connected && sessionId > 0 &&
    stabilityGateReady && geometryReady;
  return {
    inputReady,
    becameReady: inputReady && !previousReady
  };
}

export function resolveRdpDisplaySourceId(windowDisplayId: number,
  defaultDisplayId: number): number {
  return Number.isSafeInteger(windowDisplayId) && windowDisplayId >= 0 ?
    windowDisplayId : defaultDisplayId;
}

function validPositive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

/**
 * Accept a new RDP input coordinate space only after FreeRDP's completed
 * graphics lifecycle and the renderer independently expose the same desktop.
 * During cbDesktopResize one side can advance before the other; adopting that
 * transient state would make pointer input jump between two geometries.
 */
export function resolveConfirmedRdpDesktopGeometry(rendererSourceWidth: number,
  rendererSourceHeight: number, desktopWidth: number,
  desktopHeight: number): RdpConfirmedDesktopGeometry | null {
  const maximumDimension: number = 16384;
  const dimensions: number[] = [
    rendererSourceWidth, rendererSourceHeight, desktopWidth, desktopHeight
  ];
  for (const dimension of dimensions) {
    if (!Number.isSafeInteger(dimension) || dimension <= 0 || dimension > maximumDimension) {
      return null;
    }
  }
  if (rendererSourceWidth !== desktopWidth || rendererSourceHeight !== desktopHeight) {
    return null;
  }
  return { width: desktopWidth, height: desktopHeight };
}

/**
 * Fence RDP input across native resize transactions and window handoffs.
 * A queued/sent Display Control request is not settled merely because both
 * sources still expose the old desktop; the completed resize callback must
 * publish a terminal result before coordinates are accepted again.
 */
export function resolveRdpInputGeometryObservation(currentSessionId: number,
  currentAttemptId: number, observedSessionId: number, observedAttemptId: number,
  rendererSourceWidth: number, rendererSourceHeight: number,
  desktopWidth: number, desktopHeight: number,
  currentRemoteWidth: number, currentRemoteHeight: number,
  nativeLayoutPending: boolean, nativeLayoutInFlight: boolean,
  nativeResizeInProgress: boolean, nativeInputGeometryReady: boolean,
  stabilityGateReady: boolean): RdpInputGeometryObservation {
  if (currentSessionId <= 0 || currentSessionId !== observedSessionId ||
    currentAttemptId !== observedAttemptId) {
    return {
      status: 'stale', geometry: null, geometryChanged: false, inputReady: false
    };
  }
  const geometry: RdpConfirmedDesktopGeometry | null =
    resolveConfirmedRdpDesktopGeometry(rendererSourceWidth, rendererSourceHeight,
      desktopWidth, desktopHeight);
  const nativeTransactionPending: boolean = nativeLayoutPending ||
    nativeLayoutInFlight || nativeResizeInProgress;
  if (geometry === null || nativeTransactionPending) {
    return {
      status: 'pending', geometry: null, geometryChanged: false, inputReady: false
    };
  }
  return {
    status: 'confirmed',
    geometry,
    geometryChanged: geometry.width !== currentRemoteWidth ||
      geometry.height !== currentRemoteHeight,
    inputReady: stabilityGateReady && nativeInputGeometryReady
  };
}

/** A new independent PC window must inherit the cold-session stability wait. */
export function rdpRendererAttachStabilityDelayMs(sessionWindowId: string,
  contentReadyCommitted: boolean): number {
  return sessionWindowId.length > 0 && !contentReadyCommitted ?
    RDP_INPUT_STABILITY_DELAY_MS : 0;
}

export function shouldPreserveLiveRdpGeometry(protocol: string,
  connected: boolean, sessionId: number): boolean {
  return protocol === 'rdp' && connected && Number.isSafeInteger(sessionId) && sessionId > 0;
}

export function rdpCursorPositionRevisionAfterGeometryChange(currentRevision: number,
  geometryChanged: boolean): number {
  return geometryChanged ? -1 : currentRevision;
}

export function releaseRdpInputForGeometryChange(hooks: RdpGeometryInputReleaseHooks): void {
  hooks.discardPendingMouseMove();
  hooks.releaseCanvasPinchInput();
  hooks.releaseAllHeldKeys();
  hooks.releaseHeldPointerState();
  hooks.resetTouchGesture();
  hooks.resetAllLatches();
  hooks.resetTouchpadState();
  hooks.invalidateViewport();
}

/** The authenticated PC-window handoff and foreground restore share this barrier. */
export function resumeRdpGeometryAfterRendererAttach(hooks: RdpRestoreGeometryHooks): void {
  hooks.blockInputUntilConfirmed();
  hooks.synchronizeGeometry();
  hooks.startRenderWatchdog();
  hooks.startNativeStateMonitor();
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
