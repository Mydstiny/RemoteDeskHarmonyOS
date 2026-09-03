export interface CanvasGestureOwnership {
  pinchActive: boolean;
  panActive: boolean;
}

/** One two-finger stream has exactly one owner until it is released. */
export type CanvasTwoFingerOwner =
  'idle' |
  'candidate' |
  'canvas-pinch' |
  'canvas-pan' |
  'remote-touch-scale' |
  'remote-touch-pan' |
  'touchpad-scroll' |
  'touchpad-right-click';

export interface CanvasTwoFingerState {
  owner: CanvasTwoFingerOwner;
  sequenceId: number;
  startX: number;
  startY: number;
  lastX: number;
  lastY: number;
  startSpan: number;
  lastSpan: number;
  moved: boolean;
  canPan: boolean;
  zoomEnabled: boolean;
}

export type CanvasTwoFingerMoveAction = 'none' | 'scroll' | 'pan';

export interface CanvasTwoFingerMoveResult {
  state: CanvasTwoFingerState;
  action: CanvasTwoFingerMoveAction;
  deltaX: number;
  deltaY: number;
}

/** ArkUI's PinchGesture uses the same five-vp recognition distance. */
export const CANVAS_TWO_FINGER_PINCH_SLOP_VP: number = 5;
export const CANVAS_TWO_FINGER_TRANSLATION_SLOP_VP: number = 5;

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function distanceFromStart(state: CanvasTwoFingerState, x: number, y: number): number {
  const dx: number = x - state.startX;
  const dy: number = y - state.startY;
  return Math.sqrt(dx * dx + dy * dy);
}

function copyState(state: CanvasTwoFingerState): CanvasTwoFingerState {
  return {
    owner: state.owner,
    sequenceId: state.sequenceId,
    startX: state.startX,
    startY: state.startY,
    lastX: state.lastX,
    lastY: state.lastY,
    startSpan: state.startSpan,
    lastSpan: state.lastSpan,
    moved: state.moved,
    canPan: state.canPan,
    zoomEnabled: state.zoomEnabled
  };
}

export function idleCanvasTwoFingerState(): CanvasTwoFingerState {
  return {
    owner: 'idle',
    sequenceId: 0,
    startX: 0,
    startY: 0,
    lastX: 0,
    lastY: 0,
    startSpan: 0,
    lastSpan: 0,
    moved: false,
    canPan: false,
    zoomEnabled: false
  };
}

export function beginCanvasTwoFingerCandidate(sequenceId: number,
  startX: number, startY: number, _nowMs: number,
  zoomEnabled: boolean, canPan: boolean, startSpan: number = 0): CanvasTwoFingerState {
  const normalizedSpan: number = Math.max(0, finite(startSpan, 0));
  return {
    owner: 'candidate',
    sequenceId: Math.max(1, Math.floor(finite(sequenceId, 1))),
    startX: finite(startX, 0),
    startY: finite(startY, 0),
    lastX: finite(startX, 0),
    lastY: finite(startY, 0),
    startSpan: normalizedSpan,
    lastSpan: normalizedSpan,
    moved: false,
    canPan,
    zoomEnabled
  };
}

export function claimCanvasTwoFingerPinch(state: CanvasTwoFingerState,
  remote: boolean): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner === 'touchpad-right-click' || next.owner === 'canvas-pan' ||
    next.owner === 'remote-touch-pan') {
    return next;
  }
  if (!remote && !next.zoomEnabled) {
    return next;
  }
  // Scroll is provisional until the real span threshold is crossed. This is
  // what lets a slow pinch win even when its centroid moved first.
  next.owner = remote ? 'remote-touch-scale' : 'canvas-pinch';
  return next;
}

export function claimCanvasTwoFingerPan(state: CanvasTwoFingerState,
  remote: boolean): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner !== 'candidate' || !next.canPan) {
    return next;
  }
  next.owner = remote ? 'remote-touch-pan' : 'canvas-pan';
  next.moved = true;
  return next;
}

/**
 * Span wins before translation. An overflowing canvas pans immediately;
 * otherwise a centroid translation keeps the established remote-wheel path.
 */
export function advanceCanvasTwoFingerMove(state: CanvasTwoFingerState,
  x: number, y: number, _nowMs: number, remote: boolean = false,
  span: number = -1): CanvasTwoFingerMoveResult {
  const next: CanvasTwoFingerState = copyState(state);
  const currentX: number = finite(x, next.lastX);
  const currentY: number = finite(y, next.lastY);
  const currentSpan: number = span >= 0 ? finite(span, next.lastSpan) : next.lastSpan;
  const deltaX: number = currentX - next.lastX;
  const deltaY: number = currentY - next.lastY;
  next.lastX = currentX;
  next.lastY = currentY;
  next.lastSpan = currentSpan;
  const moved: boolean = Math.abs(deltaX) > 0.01 || Math.abs(deltaY) > 0.01;

  if (next.owner === 'candidate') {
    const spanMoved: boolean = next.zoomEnabled && next.startSpan > 0 && currentSpan > 0 &&
      Math.abs(currentSpan - next.startSpan) >= CANVAS_TWO_FINGER_PINCH_SLOP_VP;
    if (spanMoved) {
      next.owner = remote ? 'remote-touch-scale' : 'canvas-pinch';
      next.moved = true;
      return { state: next, action: 'none', deltaX, deltaY };
    }
    if (distanceFromStart(next, currentX, currentY) >= CANVAS_TWO_FINGER_TRANSLATION_SLOP_VP) {
      next.owner = next.canPan ?
        (remote ? 'remote-touch-pan' : 'canvas-pan') : 'touchpad-scroll';
      next.moved = true;
      return {
        state: next,
        action: next.owner === 'touchpad-scroll' ? 'scroll' : 'pan',
        deltaX,
        deltaY
      };
    }
  }

  if (next.owner === 'canvas-pan' || next.owner === 'remote-touch-pan') {
    next.moved = next.moved || moved;
    return { state: next, action: moved ? 'pan' : 'none', deltaX, deltaY };
  }
  if (next.owner === 'touchpad-scroll') {
    next.moved = next.moved || moved;
    return { state: next, action: moved ? 'scroll' : 'none', deltaX, deltaY };
  }
  return { state: next, action: 'none', deltaX, deltaY };
}

export function finishCanvasTwoFingerCandidate(state: CanvasTwoFingerState,
  wasMoved: boolean): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner === 'candidate' && !wasMoved && !next.moved) {
    next.owner = 'touchpad-right-click';
  }
  return next;
}

export function shouldSendCanvasTwoFingerScroll(state: CanvasTwoFingerState): boolean {
  return state.owner === 'touchpad-scroll';
}

export function shouldApplyCanvasTwoFingerPan(state: CanvasTwoFingerState): boolean {
  return state.owner === 'canvas-pan' || state.owner === 'remote-touch-pan';
}

export function shouldPreserveCanvasTwoFingerRightClick(state: CanvasTwoFingerState): boolean {
  return state.owner === 'candidate' || state.owner === 'touchpad-right-click';
}

export function endCanvasPinchOwnership(state: CanvasGestureOwnership): CanvasGestureOwnership {
  return { pinchActive: false, panActive: state.panActive };
}

export function endCanvasPanOwnership(state: CanvasGestureOwnership): CanvasGestureOwnership {
  return { pinchActive: state.pinchActive, panActive: false };
}

export function shouldReleaseCanvasGestureOwnership(state: CanvasGestureOwnership): boolean {
  return !state.pinchActive && !state.panActive;
}
