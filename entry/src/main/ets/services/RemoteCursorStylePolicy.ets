export type RemoteCursorStyle = 'circle' | 'arrow';

export const VIRTUAL_MOUSE_STYLE_RESTORE_VERSION: number = 1;
export const VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY: string = 'virtualMouseStyleRestoreVersion';
export const REMOTE_CURSOR_FALLBACK_EDGE_VP: number = 22;
export const REMOTE_CURSOR_MIN_EDGE_VP: number = 18;
export const REMOTE_CURSOR_MAX_EDGE_VP: number = 48;

export function remoteCursorSnapshotChanged(previousX: number, previousY: number,
  previousReady: boolean, nextX: number, nextY: number, nextReady: boolean): boolean {
  return previousX !== nextX || previousY !== nextY || previousReady !== nextReady;
}

export function normalizeRemoteCursorStyle(value: string | undefined): RemoteCursorStyle {
  return value === 'arrow' ? 'arrow' : 'circle';
}

export function shouldApplyCloudVirtualMouseStyle(localVersion: number): boolean {
  return Number.isFinite(localVersion) && localVersion >= VIRTUAL_MOUSE_STYLE_RESTORE_VERSION;
}

export function shouldRenderVirtualTouchpadCursor(connected: boolean, touchpadMode: boolean,
  cursorReady: boolean): boolean {
  return connected && touchpadMode && cursorReady;
}

export function shouldRenderArrowCursor(style: RemoteCursorStyle, connected: boolean,
  touchpadMode: boolean, cursorReady: boolean): boolean {
  return style === 'arrow' && shouldRenderVirtualTouchpadCursor(connected, touchpadMode, cursorReady);
}

/**
 * The controller-side bootstrap bitmap is not a remote cursor shape. Keep it
 * out of the official arrow path so a delayed RustDesk shape cannot present a
 * misleading triangle for the lifetime of the connection.
 */
export function shouldRenderRemoteCursorArrow(style: RemoteCursorStyle, connected: boolean,
  touchpadMode: boolean, cursorReady: boolean, nativeVisible: boolean,
  hasPixelMap: boolean, fallbackShape: boolean): boolean {
  return shouldRenderArrowCursor(style, connected, touchpadMode, cursorReady) &&
    nativeVisible && hasPixelMap && !fallbackShape;
}

/**
 * While RustDesk has not replayed a real shape, retain a visible and stable
 * touchpad affordance without drawing the non-authoritative bootstrap bitmap.
 */
export function shouldRenderRemoteCursorFallbackIndicator(fallbackShape: boolean,
  connected: boolean, touchpadMode: boolean, cursorReady: boolean): boolean {
  return fallbackShape && shouldRenderVirtualTouchpadCursor(connected, touchpadMode, cursorReady);
}

export function shouldRenderCircleCursor(style: RemoteCursorStyle, cursorReady: boolean,
  connected: boolean, touchpadMode: boolean): boolean {
  return style === 'circle' && shouldRenderVirtualTouchpadCursor(connected, touchpadMode, cursorReady);
}

export function shouldRefreshRemoteCursorBitmap(shapeRevision: number, hasPixelMap: boolean,
  _visible: boolean, lastRefreshAtMs: number, nowMs: number, retryIntervalMs: number): boolean {
  if (shapeRevision <= 0 || hasPixelMap) {
    return false;
  }
  const boundedRetryMs: number = Math.min(Math.max(0, retryIntervalMs), 1000);
  return lastRefreshAtMs <= 0 || boundedRetryMs <= 0 ||
    nowMs - lastRefreshAtMs >= boundedRetryMs;
}

/**
 * Resolve one uniform visual scale for a protocol cursor. The bootstrap shape
 * is controller-side metadata, not part of the remote desktop; if it is kept
 * during a transition, it has a fixed physical edge. Protocol shapes retain
 * their aspect ratio while staying legible on Phone/Pad and bounded during a
 * stale viewport handoff.
 */
export function resolveRemoteCursorVisualScale(width: number, height: number,
  projectedScale: number, fallbackShape: boolean): number {
  const edge: number = Math.max(width, height);
  if (!Number.isFinite(edge) || edge <= 0) {
    return 1;
  }
  if (fallbackShape) {
    return REMOTE_CURSOR_FALLBACK_EDGE_VP / edge;
  }
  const safeProjectedScale: number = Number.isFinite(projectedScale) && projectedScale > 0 ?
    projectedScale : REMOTE_CURSOR_MIN_EDGE_VP / edge;
  const minScale: number = REMOTE_CURSOR_MIN_EDGE_VP / edge;
  const maxScale: number = REMOTE_CURSOR_MAX_EDGE_VP / edge;
  return Math.max(minScale, Math.min(maxScale, safeProjectedScale));
}
