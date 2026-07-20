/**
 * Remote surface coordinate contract.
 *
 * Remote coordinates are protocol/display coordinates. Renderer source pixels
 * are only used to describe the contain viewport; they must not be silently
 * substituted for the remote logical desktop size.
 */
export interface RemoteSurfaceTransform {
  remoteWidth: number;
  remoteHeight: number;
  viewportX: number;
  viewportY: number;
  viewportW: number;
  viewportH: number;
  surfaceWidthPx: number;
  surfaceHeightPx: number;
  surfaceWidthVp: number;
  surfaceHeightVp: number;
}

export interface RemoteSurfacePoint {
  x: number;
  y: number;
  inside: boolean;
}

export interface RemoteSurfaceDelta {
  x: number;
  y: number;
}

function positive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

/** Project a remote logical point to the ArkUI surface (vp). */
export function remotePointToSurface(transform: RemoteSurfaceTransform,
  remoteX: number, remoteY: number): RemoteSurfacePoint {
  const remoteW: number = positive(transform.remoteWidth, 1);
  const remoteH: number = positive(transform.remoteHeight, 1);
  const viewportW: number = positive(transform.viewportW, remoteW);
  const viewportH: number = positive(transform.viewportH, remoteH);
  const pxToVpX: number = positive(transform.surfaceWidthVp, 1) /
    positive(transform.surfaceWidthPx, 1);
  const pxToVpY: number = positive(transform.surfaceHeightVp, 1) /
    positive(transform.surfaceHeightPx, 1);
  const validInput: boolean = Number.isFinite(remoteX) && Number.isFinite(remoteY);
  const x: number = finite(remoteX, 0);
  const y: number = finite(remoteY, 0);
  const xPx: number = transform.viewportX + x * viewportW / remoteW;
  const yPx: number = transform.viewportY + y * viewportH / remoteH;
  return {
    x: xPx * pxToVpX,
    y: yPx * pxToVpY,
    inside: validInput && x >= 0 && y >= 0 && x < remoteW && y < remoteH
  };
}

/** Project an ArkUI surface point (vp) to remote logical coordinates. */
export function surfacePointToRemote(transform: RemoteSurfaceTransform,
  localX: number, localY: number): RemoteSurfacePoint {
  const remoteW: number = positive(transform.remoteWidth, 1);
  const remoteH: number = positive(transform.remoteHeight, 1);
  const viewportW: number = positive(transform.viewportW, remoteW);
  const viewportH: number = positive(transform.viewportH, remoteH);
  const vpToPxX: number = positive(transform.surfaceWidthPx, 1) /
    positive(transform.surfaceWidthVp, 1);
  const vpToPxY: number = positive(transform.surfaceHeightPx, 1) /
    positive(transform.surfaceHeightVp, 1);
  const validInput: boolean = Number.isFinite(localX) && Number.isFinite(localY);
  const localPxX: number = finite(localX, 0) * vpToPxX;
  const localPxY: number = finite(localY, 0) * vpToPxY;
  const rawX: number = (localPxX - transform.viewportX) * remoteW / viewportW;
  const rawY: number = (localPxY - transform.viewportY) * remoteH / viewportH;
  return {
    x: clamp(rawX, 0, Math.max(0, remoteW - 1)),
    y: clamp(rawY, 0, Math.max(0, remoteH - 1)),
    inside: validInput && rawX >= 0 && rawY >= 0 && rawX < remoteW && rawY < remoteH
  };
}

/** Convert a relative ArkUI surface movement (vp) to remote delta. */
export function surfaceDeltaToRemote(transform: RemoteSurfaceTransform,
  deltaX: number, deltaY: number): RemoteSurfaceDelta {
  const remoteW: number = positive(transform.remoteWidth, 1);
  const remoteH: number = positive(transform.remoteHeight, 1);
  const viewportW: number = positive(transform.viewportW, remoteW);
  const viewportH: number = positive(transform.viewportH, remoteH);
  const vpToPxX: number = positive(transform.surfaceWidthPx, 1) /
    positive(transform.surfaceWidthVp, 1);
  const vpToPxY: number = positive(transform.surfaceHeightPx, 1) /
    positive(transform.surfaceHeightVp, 1);
  const dx: number = finite(deltaX, 0);
  const dy: number = finite(deltaY, 0);
  return {
    x: dx * vpToPxX * remoteW / viewportW,
    y: dy * vpToPxY * remoteH / viewportH
  };
}
