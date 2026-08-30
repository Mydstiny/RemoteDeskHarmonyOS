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
  // Independent mirrors applied in displayed-canvas coordinates after rotation.
  flipX?: boolean;
  flipY?: boolean;
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
  flipX: boolean, flipY: boolean, rawX: number, rawY: number): RemoteSurfacePoint {
  let rotated: RemoteSurfacePoint;
  switch (rotation) {
    case 1:
      rotated = { x: remoteH - rawY, y: rawX, inside: true };
      break;
    case 2:
      rotated = { x: remoteW - rawX, y: remoteH - rawY, inside: true };
      break;
    case 3:
      rotated = { x: rawY, y: remoteW - rawX, inside: true };
      break;
    default:
      rotated = { x: rawX, y: rawY, inside: true };
      break;
  }
  const displayW: number = displayedRemoteWidth(remoteW, remoteH, rotation);
  const displayH: number = displayedRemoteHeight(remoteW, remoteH, rotation);
  return {
    x: flipX ? displayW - rotated.x : rotated.x,
    y: flipY ? displayH - rotated.y : rotated.y,
    inside: true
  };
}

function displayedPointToRaw(remoteW: number, remoteH: number, rotation: number,
  flipX: boolean, flipY: boolean,
  displayedX: number, displayedY: number): RemoteSurfacePoint {
  const displayW: number = displayedRemoteWidth(remoteW, remoteH, rotation);
  const displayH: number = displayedRemoteHeight(remoteW, remoteH, rotation);
  const unflippedX: number = flipX ? displayW - displayedX : displayedX;
  const unflippedY: number = flipY ? displayH - displayedY : displayedY;
  switch (rotation) {
    case 1:
      return { x: unflippedY, y: remoteH - unflippedX, inside: true };
    case 2:
      return { x: remoteW - unflippedX, y: remoteH - unflippedY, inside: true };
    case 3:
      return { x: remoteW - unflippedY, y: unflippedX, inside: true };
    default:
      return { x: unflippedX, y: unflippedY, inside: true };
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
  const flipX: boolean = transform.flipX === true;
  const flipY: boolean = transform.flipY === true;
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
  const displayed: RemoteSurfacePoint = rawPointToDisplayed(
    remoteW, remoteH, rotation, flipX, flipY, x, y);
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
  const flipX: boolean = transform.flipX === true;
  const flipY: boolean = transform.flipY === true;
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
    remoteW, remoteH, rotation, flipX, flipY, displayedX, displayedY);
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
  const flipX: boolean = transform.flipX === true;
  const flipY: boolean = transform.flipY === true;
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
  const unflippedDx: number = flipX ? -displayedDx : displayedDx;
  const unflippedDy: number = flipY ? -displayedDy : displayedDy;
  switch (rotation) {
    case 1:
      return { x: unflippedDy, y: -unflippedDx };
    case 2:
      return { x: -unflippedDx, y: -unflippedDy };
    case 3:
      return { x: -unflippedDy, y: unflippedDx };
    default:
      return {
        x: unflippedDx,
        y: unflippedDy
      };
  }
}
