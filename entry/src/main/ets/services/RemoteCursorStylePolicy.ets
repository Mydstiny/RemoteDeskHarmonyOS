export type RemoteCursorStyle = 'circle' | 'arrow';

export function remoteCursorSnapshotChanged(previousX: number, previousY: number,
  previousReady: boolean, nextX: number, nextY: number, nextReady: boolean): boolean {
  return previousX !== nextX || previousY !== nextY || previousReady !== nextReady;
}

export function normalizeRemoteCursorStyle(value: string | undefined): RemoteCursorStyle {
  return value === 'arrow' ? 'arrow' : 'circle';
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
