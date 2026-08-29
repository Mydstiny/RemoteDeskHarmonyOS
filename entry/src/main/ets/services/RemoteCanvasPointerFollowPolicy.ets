import {
  canvasTransformCanPan,
  CanvasTransform,
  CanvasViewport,
  clampCanvasTransform,
  panCanvasTransform
} from './RemoteCanvasTransformPolicy';
import {
  remotePointToSurface,
  RemoteSurfaceTransform
} from './RemoteSurfaceTransformPolicy';

export const CANVAS_POINTER_SAFE_AREA_RATIO: number = 0.66;
export const CANVAS_POINTER_EDGE_INSET_VP: number = 72;
export const CANVAS_POINTER_EDGE_STEP_VP: number = 18;

export interface CanvasPointerFollowResult {
  transform: CanvasTransform;
  moved: boolean;
  panDeltaX: number;
  panDeltaY: number;
  reason: string;
}

export interface CanvasRemotePointerFollowRequest {
  enabled: boolean;
  transform: CanvasTransform;
  viewport: CanvasViewport;
  surfaceTransform: RemoteSurfaceTransform;
  remoteX: number;
  remoteY: number;
  safeAreaRatio?: number;
}

export interface CanvasPhysicalPointerFollowRequest {
  enabled: boolean;
  transform: CanvasTransform;
  viewport: CanvasViewport;
  surfaceWidthVp: number;
  surfaceHeightVp: number;
  localX: number;
  localY: number;
  pxPerVpX: number;
  pxPerVpY: number;
  armed: boolean;
  edgeInsetVp?: number;
  maxStepVp?: number;
}

export interface CanvasPhysicalPointerFollowResult extends CanvasPointerFollowResult {
  armed: boolean;
  active: boolean;
}

export interface CanvasLocalPointerFollowRequest {
  enabled: boolean;
  transform: CanvasTransform;
  viewport: CanvasViewport;
  surfaceWidthVp: number;
  surfaceHeightVp: number;
  localX: number;
  localY: number;
  pxPerVpX: number;
  pxPerVpY: number;
  safeAreaRatio?: number;
}

export interface CanvasLocalPointerFollowResult extends CanvasPointerFollowResult {
  pointerX: number;
  pointerY: number;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function strictViewport(viewport: CanvasViewport): CanvasViewport {
  return {
    surfaceWidth: viewport.surfaceWidth,
    surfaceHeight: viewport.surfaceHeight,
    sourceWidth: viewport.sourceWidth,
    sourceHeight: viewport.sourceHeight,
    freePanInsetRatio: 0
  };
}

function changed(before: CanvasTransform, after: CanvasTransform): boolean {
  return Math.abs(before.panX - after.panX) > 0.01 ||
    Math.abs(before.panY - after.panY) > 0.01 ||
    Math.abs(before.scale - after.scale) > 0.0001;
}

function noMove(transform: CanvasTransform, reason: string): CanvasPointerFollowResult {
  return { transform, moved: false, panDeltaX: 0, panDeltaY: 0, reason };
}

/**
 * Keep a relative/virtual pointer inside a central safe area while hidden
 * content remains. The pointer itself is never clamped by this policy.
 */
export function followCanvasForRemotePointer(
  request: CanvasRemotePointerFollowRequest
): CanvasPointerFollowResult {
  if (!request.enabled) {
    return noMove(request.transform, 'disabled');
  }
  const viewport: CanvasViewport = strictViewport(request.viewport);
  const strict: CanvasTransform = clampCanvasTransform(request.transform, viewport);
  if (!canvasTransformCanPan(strict, viewport)) {
    return noMove(request.transform, 'content-visible');
  }
  const point = remotePointToSurface(request.surfaceTransform, request.remoteX, request.remoteY);
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    return noMove(request.transform, 'invalid-pointer');
  }
  const widthVp: number = Math.max(1, finite(request.surfaceTransform.surfaceWidthVp, 1));
  const heightVp: number = Math.max(1, finite(request.surfaceTransform.surfaceHeightVp, 1));
  const ratio: number = clamp(
    finite(request.safeAreaRatio ?? CANVAS_POINTER_SAFE_AREA_RATIO,
      CANVAS_POINTER_SAFE_AREA_RATIO), 0.5, 0.85);
  const sideX: number = widthVp * (1 - ratio) / 2;
  const sideY: number = heightVp * (1 - ratio) / 2;
  let deltaVpX: number = 0;
  let deltaVpY: number = 0;
  if (point.x < sideX) {
    deltaVpX = sideX - point.x;
  } else if (point.x > widthVp - sideX) {
    deltaVpX = widthVp - sideX - point.x;
  }
  if (point.y < sideY) {
    deltaVpY = sideY - point.y;
  } else if (point.y > heightVp - sideY) {
    deltaVpY = heightVp - sideY - point.y;
  }
  if (deltaVpX === 0 && deltaVpY === 0) {
    return noMove(request.transform, 'inside-safe-area');
  }
  const pxPerVpX: number = Math.max(0.01,
    finite(request.surfaceTransform.surfaceWidthPx, widthVp) / widthVp);
  const pxPerVpY: number = Math.max(0.01,
    finite(request.surfaceTransform.surfaceHeightPx, heightVp) / heightVp);
  const next: CanvasTransform = panCanvasTransform(strict, viewport,
    deltaVpX * pxPerVpX, deltaVpY * pxPerVpY);
  if (!changed(request.transform, next)) {
    return noMove(request.transform, 'content-boundary');
  }
  return {
    transform: next,
    moved: true,
    panDeltaX: next.panX - request.transform.panX,
    panDeltaY: next.panY - request.transform.panY,
    reason: 'safe-area-follow'
  };
}

/** Safe-area follow for protocols whose relative pointer is tracked in local coordinates. */
export function followCanvasForLocalPointer(
  request: CanvasLocalPointerFollowRequest
): CanvasLocalPointerFollowResult {
  const widthVp: number = Math.max(1, finite(request.surfaceWidthVp, 1));
  const heightVp: number = Math.max(1, finite(request.surfaceHeightVp, 1));
  const localX: number = finite(request.localX, widthVp / 2);
  const localY: number = finite(request.localY, heightVp / 2);
  if (!request.enabled) {
    return {
      transform: request.transform, moved: false, panDeltaX: 0, panDeltaY: 0,
      reason: 'disabled', pointerX: localX, pointerY: localY
    };
  }
  const viewport: CanvasViewport = strictViewport(request.viewport);
  const strict: CanvasTransform = clampCanvasTransform(request.transform, viewport);
  if (!canvasTransformCanPan(strict, viewport)) {
    return {
      transform: request.transform, moved: false, panDeltaX: 0, panDeltaY: 0,
      reason: 'content-visible', pointerX: localX, pointerY: localY
    };
  }
  const ratio: number = clamp(
    finite(request.safeAreaRatio ?? CANVAS_POINTER_SAFE_AREA_RATIO,
      CANVAS_POINTER_SAFE_AREA_RATIO), 0.5, 0.85);
  const sideX: number = widthVp * (1 - ratio) / 2;
  const sideY: number = heightVp * (1 - ratio) / 2;
  const pointerX: number = clamp(localX, sideX, widthVp - sideX);
  const pointerY: number = clamp(localY, sideY, heightVp - sideY);
  const deltaVpX: number = pointerX - localX;
  const deltaVpY: number = pointerY - localY;
  if (deltaVpX === 0 && deltaVpY === 0) {
    return {
      transform: request.transform, moved: false, panDeltaX: 0, panDeltaY: 0,
      reason: 'inside-safe-area', pointerX, pointerY
    };
  }
  const next: CanvasTransform = panCanvasTransform(strict, viewport,
    deltaVpX * Math.max(0.01, finite(request.pxPerVpX, 1)),
    deltaVpY * Math.max(0.01, finite(request.pxPerVpY, 1)));
  const moved: boolean = changed(request.transform, next);
  const panDeltaX: number = moved ? next.panX - request.transform.panX : 0;
  const panDeltaY: number = moved ? next.panY - request.transform.panY : 0;
  return {
    transform: moved ? next : request.transform,
    moved,
    panDeltaX,
    panDeltaY,
    reason: moved ? 'safe-area-follow' : 'content-boundary',
    // A content boundary can block one axis while the other keeps following.
    // Clamp only the pointer axis whose canvas actually moved; otherwise a
    // horizontal edge-follow would unexpectedly pull a free vertical cursor
    // back into the safe area (and vice versa).
    pointerX: Math.abs(panDeltaX) > 0.01 ? pointerX : localX,
    pointerY: Math.abs(panDeltaY) > 0.01 ? pointerY : localY
  };
}

/**
 * Edge-follow for an absolute physical pointer. It must first be observed in
 * the inner region, preventing a pointer entering from outside from moving
 * the canvas immediately.
 */
export function followCanvasForPhysicalPointer(
  request: CanvasPhysicalPointerFollowRequest
): CanvasPhysicalPointerFollowResult {
  if (!request.enabled) {
    return {
      transform: request.transform,
      moved: false,
      panDeltaX: 0,
      panDeltaY: 0,
      reason: 'disabled',
      armed: false,
      active: false
    };
  }
  const widthVp: number = Math.max(1, finite(request.surfaceWidthVp, 1));
  const heightVp: number = Math.max(1, finite(request.surfaceHeightVp, 1));
  const edge: number = clamp(
    finite(request.edgeInsetVp ?? CANVAS_POINTER_EDGE_INSET_VP,
      CANVAS_POINTER_EDGE_INSET_VP), 48, 100);
  const localX: number = finite(request.localX, widthVp / 2);
  const localY: number = finite(request.localY, heightVp / 2);
  let armed: boolean = request.armed;
  if (!armed && localX >= edge && localX <= widthVp - edge &&
    localY >= edge && localY <= heightVp - edge) {
    armed = true;
  }
  const viewport: CanvasViewport = strictViewport(request.viewport);
  const strict: CanvasTransform = clampCanvasTransform(request.transform, viewport);
  if (!armed || !canvasTransformCanPan(strict, viewport)) {
    const reason: string = !armed ? 'not-armed' : 'content-visible';
    return {
      transform: request.transform,
      moved: false,
      panDeltaX: 0,
      panDeltaY: 0,
      reason,
      armed,
      active: false
    };
  }
  const maxStep: number = clamp(
    finite(request.maxStepVp ?? CANVAS_POINTER_EDGE_STEP_VP,
      CANVAS_POINTER_EDGE_STEP_VP), 4, 40);
  let deltaVpX: number = 0;
  let deltaVpY: number = 0;
  if (localX < edge) {
    deltaVpX = maxStep * clamp((edge - localX) / edge, 0, 1);
  } else if (localX > widthVp - edge) {
    deltaVpX = -maxStep * clamp((localX - (widthVp - edge)) / edge, 0, 1);
  }
  if (localY < edge) {
    deltaVpY = maxStep * clamp((edge - localY) / edge, 0, 1);
  } else if (localY > heightVp - edge) {
    deltaVpY = -maxStep * clamp((localY - (heightVp - edge)) / edge, 0, 1);
  }
  if (deltaVpX === 0 && deltaVpY === 0) {
    return {
      transform: request.transform,
      moved: false,
      panDeltaX: 0,
      panDeltaY: 0,
      reason: 'inside-edge-region',
      armed,
      active: false
    };
  }
  const next: CanvasTransform = panCanvasTransform(strict, viewport,
    deltaVpX * Math.max(0.01, finite(request.pxPerVpX, 1)),
    deltaVpY * Math.max(0.01, finite(request.pxPerVpY, 1)));
  const moved: boolean = changed(request.transform, next);
  return {
    transform: moved ? next : request.transform,
    moved,
    panDeltaX: moved ? next.panX - request.transform.panX : 0,
    panDeltaY: moved ? next.panY - request.transform.panY : 0,
    reason: moved ? 'edge-follow' : 'content-boundary',
    armed,
    active: moved && (deltaVpX !== 0 || deltaVpY !== 0)
  };
}
