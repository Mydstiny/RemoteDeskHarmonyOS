import { OverlayRect } from './RemoteOverlayViewportPolicy';

/**
 * Hit-test contract for the remote surface stack.
 *
 * `remoteInputSurface` is the real canvas gesture/keyboard fallback and must
 * remain full viewport.  Visible controls are separate, measured overlays;
 * they win hit testing by z-order/rect before a point is routed to canvas.
 * Hidden or stale-generation overlays are never allowed to consume a blank
 * canvas point.
 */
export const REMOTE_CANVAS_INPUT_SURFACE_ID: string = 'remoteInputSurface';

export interface RemoteCanvasPoint {
  x: number;
  y: number;
}

export interface RemoteVisibleOverlayHitTarget {
  ownerId: string;
  rect: OverlayRect;
  generation: number;
  visible: boolean;
  priority: number;
}

function contains(rect: OverlayRect, point: RemoteCanvasPoint): boolean {
  return rect.width > 0 && rect.height > 0 &&
    point.x >= rect.x && point.x <= rect.x + rect.width &&
    point.y >= rect.y && point.y <= rect.y + rect.height;
}

/** Return the visible overlay owner, or the real canvas surface for a blank. */
export function resolveRemoteInteractionTarget(point: RemoteCanvasPoint,
  overlays: Array<RemoteVisibleOverlayHitTarget>, generation: number): string {
  let selected: RemoteVisibleOverlayHitTarget | null = null;
  for (let index = 0; index < overlays.length; index++) {
    const candidate: RemoteVisibleOverlayHitTarget = overlays[index];
    if (!candidate.visible || candidate.generation !== generation ||
      !contains(candidate.rect, point)) {
      continue;
    }
    if (selected === null || candidate.priority > selected.priority) {
      selected = candidate;
    }
  }
  return selected === null ? REMOTE_CANVAS_INPUT_SURFACE_ID : selected.ownerId;
}

export function remoteCanvasGestureIsRemote(targetId: string): boolean {
  return targetId === REMOTE_CANVAS_INPUT_SURFACE_ID;
}
