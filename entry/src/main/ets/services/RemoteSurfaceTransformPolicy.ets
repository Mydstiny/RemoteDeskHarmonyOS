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
  // Clockwise quarter turns applied to the displayed remote canvas.
  rotation?: number;
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

export interface NormalizedRendererViewport {
  viewportX: number;
  viewportY: number;
  viewportW: number;
  viewportH: number;
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

function normalizeRotation(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return 0;
  }
  const rounded: number = Math.round(value) % 4;
  return rounded < 0 ? rounded + 4 : rounded;
}

function displayedRemoteWidth(remoteW: number, remoteH: number, rotation: number): number {
  return rotation % 2 === 1 ? remoteH : remoteW;
}

function displayedRemoteHeight(remoteW: number, remoteH: number, rotation: number): number {
  return rotation % 2 === 1 ? remoteW : remoteH;
}

function rawPointToDisplayed(remoteW: number, remoteH: number, rotation: number,
  rawX: number, rawY: number): RemoteSurfacePoint {
  switch (rotation) {
    case 1:
      return { x: remoteH - rawY, y: rawX, inside: true };
    case 2:
      return { x: remoteW - rawX, y: remoteH - rawY, inside: true };
    case 3:
      return { x: rawY, y: remoteW - rawX, inside: true };
    default:
      return { x: rawX, y: rawY, inside: true };
  }
}

function displayedPointToRaw(remoteW: number, remoteH: number, rotation: number,
  displayedX: number, displayedY: number): RemoteSurfacePoint {
  switch (rotation) {
    case 1:
      return { x: displayedY, y: remoteH - displayedX, inside: true };
    case 2:
      return { x: remoteW - displayedX, y: remoteH - displayedY, inside: true };
    case 3:
      return { x: remoteW - displayedY, y: displayedX, inside: true };
    default:
      return { x: displayedX, y: displayedY, inside: true };
  }
}

/**
 * Renderer viewport coordinates are relative to the EGL surface that produced
 * them. Normalize them before combining them with a newer ArkUI surface size.
 */
export function normalizeRendererViewportToSurface(viewportX: number, viewportY: number,
  viewportW: number, viewportH: number, rendererSurfaceWidth: number,
  rendererSurfaceHeight: number, targetSurfaceWidth: number,
  targetSurfaceHeight: number): NormalizedRendererViewport | null {
  if (!Number.isFinite(viewportX) || !Number.isFinite(viewportY) ||
    !Number.isFinite(viewportW) || !Number.isFinite(viewportH) ||
    !Number.isFinite(rendererSurfaceWidth) || !Number.isFinite(rendererSurfaceHeight) ||
    !Number.isFinite(targetSurfaceWidth) || !Number.isFinite(targetSurfaceHeight) ||
    viewportW <= 0 || viewportH <= 0 || rendererSurfaceWidth <= 0 ||
    rendererSurfaceHeight <= 0 || targetSurfaceWidth <= 0 || targetSurfaceHeight <= 0) {
    return null;
  }
  const scaleX: number = targetSurfaceWidth / rendererSurfaceWidth;
  const scaleY: number = targetSurfaceHeight / rendererSurfaceHeight;
  return {
    viewportX: viewportX * scaleX,
    viewportY: viewportY * scaleY,
    viewportW: viewportW * scaleX,
    viewportH: viewportH * scaleY
  };
}

/** Project a remote logical point to the ArkUI surface (vp). */
export function remotePointToSurface(transform: RemoteSurfaceTransform,
  remoteX: number, remoteY: number): RemoteSurfacePoint {
  const remoteW: number = positive(transform.remoteWidth, 1);
  const remoteH: number = positive(transform.remoteHeight, 1);
  const rotation: number = normalizeRotation(transform.rotation);
  const displayW: number = displayedRemoteWidth(remoteW, remoteH, rotation);
  const displayH: number = displayedRemoteHeight(remoteW, remoteH, rotation);
  const viewportW: number = positive(transform.viewportW, displayW);
  const viewportH: number = positive(transform.viewportH, displayH);
  const pxToVpX: number = positive(transform.surfaceWidthVp, 1) /
    positive(transform.surfaceWidthPx, 1);
  const pxToVpY: number = positive(transform.surfaceHeightVp, 1) /
    positive(transform.surfaceHeightPx, 1);
  const validInput: boolean = Number.isFinite(remoteX) && Number.isFinite(remoteY);
  const x: number = finite(remoteX, 0);
  const y: number = finite(remoteY, 0);
  const displayed: RemoteSurfacePoint = rawPointToDisplayed(remoteW, remoteH, rotation, x, y);
  const xPx: number = transform.viewportX + displayed.x * viewportW / displayW;
  const yPx: number = transform.viewportY + displayed.y * viewportH / displayH;
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
  const rotation: number = normalizeRotation(transform.rotation);
  const displayW: number = displayedRemoteWidth(remoteW, remoteH, rotation);
  const displayH: number = displayedRemoteHeight(remoteW, remoteH, rotation);
  const viewportW: number = positive(transform.viewportW, displayW);
  const viewportH: number = positive(transform.viewportH, displayH);
  const vpToPxX: number = positive(transform.surfaceWidthPx, 1) /
    positive(transform.surfaceWidthVp, 1);
  const vpToPxY: number = positive(transform.surfaceHeightPx, 1) /
    positive(transform.surfaceHeightVp, 1);
  const validInput: boolean = Number.isFinite(localX) && Number.isFinite(localY);
  const localPxX: number = finite(localX, 0) * vpToPxX;
  const localPxY: number = finite(localY, 0) * vpToPxY;
  const displayedX: number = (localPxX - transform.viewportX) * displayW / viewportW;
  const displayedY: number = (localPxY - transform.viewportY) * displayH / viewportH;
  const raw: RemoteSurfacePoint = displayedPointToRaw(
    remoteW, remoteH, rotation, displayedX, displayedY);
  const rawX: number = raw.x;
  const rawY: number = raw.y;
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
  const rotation: number = normalizeRotation(transform.rotation);
  const displayW: number = displayedRemoteWidth(remoteW, remoteH, rotation);
  const displayH: number = displayedRemoteHeight(remoteW, remoteH, rotation);
  const viewportW: number = positive(transform.viewportW, displayW);
  const viewportH: number = positive(transform.viewportH, displayH);
  const vpToPxX: number = positive(transform.surfaceWidthPx, 1) /
    positive(transform.surfaceWidthVp, 1);
  const vpToPxY: number = positive(transform.surfaceHeightPx, 1) /
    positive(transform.surfaceHeightVp, 1);
  const dx: number = finite(deltaX, 0);
  const dy: number = finite(deltaY, 0);
  const displayedDx: number = dx * vpToPxX * displayW / viewportW;
  const displayedDy: number = dy * vpToPxY * displayH / viewportH;
  switch (rotation) {
    case 1:
      return { x: displayedDy, y: -displayedDx };
    case 2:
      return { x: -displayedDx, y: -displayedDy };
    case 3:
      return { x: -displayedDy, y: displayedDx };
    default:
      return {
        x: displayedDx,
        y: displayedDy
      };
  }
}
