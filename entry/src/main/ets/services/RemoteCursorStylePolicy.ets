export type RemoteCursorStyle = 'circle' | 'arrow';

export const VIRTUAL_MOUSE_STYLE_RESTORE_VERSION: number = 1;
export const VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY: string = 'virtualMouseStyleRestoreVersion';

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

export function shouldRenderCircleCursor(style: RemoteCursorStyle, cursorReady: boolean,
  connected: boolean, touchpadMode: boolean): boolean {
  return style === 'circle' && shouldRenderVirtualTouchpadCursor(connected, touchpadMode, cursorReady);
}

export function shouldRefreshRemoteCursorBitmap(shapeRevision: number, hasPixelMap: boolean,
  visible: boolean, lastRefreshAtMs: number, nowMs: number, refreshIntervalMs: number): boolean {
  if (shapeRevision <= 0) {
    return false;
  }
  if (!hasPixelMap) {
    const retryIntervalMs: number = Math.min(refreshIntervalMs, 1000);
    return lastRefreshAtMs <= 0 || retryIntervalMs <= 0 ||
      nowMs - lastRefreshAtMs >= retryIntervalMs;
  }
  return visible && lastRefreshAtMs > 0 && refreshIntervalMs > 0 &&
    nowMs - lastRefreshAtMs >= refreshIntervalMs;
}
