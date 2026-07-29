export interface CanvasGestureOwnership {
  pinchActive: boolean;
  panActive: boolean;
}

/**
 * A two-finger sequence has one semantic owner at a time.  The candidate
 * state deliberately exists outside ArkUI's recognizers so the XComponent
 * onTouch path and the transparent Gesture overlay can make the same choice.
 */
export type CanvasTwoFingerOwner =
  'idle' |
  'candidate' |
  'canvas-pinch' |
  'canvas-pan-armed' |
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
  holdDeadlineMs: number;
  holdTimerPending: boolean;
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

/** The initial UX target; tune only with API 23 device evidence. */
export const CANVAS_TWO_FINGER_HOLD_MS: number = 400;
export const CANVAS_TWO_FINGER_HOLD_SLOP_VP: number = 12;

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
    holdDeadlineMs: state.holdDeadlineMs,
    holdTimerPending: state.holdTimerPending,
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
    holdDeadlineMs: 0,
    holdTimerPending: false,
    moved: false,
    canPan: false,
    zoomEnabled: false
  };
}

export function beginCanvasTwoFingerCandidate(sequenceId: number,
  startX: number, startY: number, nowMs: number,
  zoomEnabled: boolean, canPan: boolean): CanvasTwoFingerState {
  return {
    owner: 'candidate',
    sequenceId: Math.max(1, Math.floor(finite(sequenceId, 1))),
    startX: finite(startX, 0),
    startY: finite(startY, 0),
    lastX: finite(startX, 0),
    lastY: finite(startY, 0),
    holdDeadlineMs: finite(nowMs, 0) + CANVAS_TWO_FINGER_HOLD_MS,
    holdTimerPending: zoomEnabled && canPan,
    moved: false,
    canPan,
    zoomEnabled
  };
}

/** Timer expiry only arms pan; it does not consume the stream or send input. */
export function expireCanvasTwoFingerHold(state: CanvasTwoFingerState,
  nowMs: number): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner !== 'candidate' || !next.zoomEnabled || !next.canPan ||
    finite(nowMs, 0) < next.holdDeadlineMs) {
    return next;
  }
  next.owner = 'canvas-pan-armed';
  next.holdTimerPending = false;
  return next;
}

export function claimCanvasTwoFingerPinch(state: CanvasTwoFingerState,
  remote: boolean): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner === 'touchpad-scroll' || next.owner === 'touchpad-right-click' ||
    next.owner === 'canvas-pan' || next.owner === 'remote-touch-pan') {
    return next;
  }
  next.owner = remote ? 'remote-touch-scale' : 'canvas-pinch';
  next.holdTimerPending = false;
  return next;
}

export function claimCanvasTwoFingerPan(state: CanvasTwoFingerState,
  remote: boolean): CanvasTwoFingerState {
  const next: CanvasTwoFingerState = copyState(state);
  if (next.owner !== 'canvas-pan-armed') {
    return next;
  }
  next.owner = remote ? 'remote-touch-pan' : 'canvas-pan';
  next.holdTimerPending = false;
  next.moved = true;
  return next;
}

/**
 * Classify a centroid move.  Before the hold deadline, any meaningful move
 * belongs to the touchpad; after arming, the first meaningful move claims pan.
 */
export function advanceCanvasTwoFingerMove(state: CanvasTwoFingerState,
  x: number, y: number, nowMs: number): CanvasTwoFingerMoveResult {
  const next: CanvasTwoFingerState = copyState(state);
  const currentX: number = finite(x, next.lastX);
  const currentY: number = finite(y, next.lastY);
  const deltaX: number = currentX - next.lastX;
  const deltaY: number = currentY - next.lastY;
  next.lastX = currentX;
  next.lastY = currentY;
  const moved: boolean = Math.abs(deltaX) > 0.01 || Math.abs(deltaY) > 0.01;

  if (next.owner === 'candidate') {
    const distance: number = distanceFromStart(next, currentX, currentY);
    // The timer normally arms the state, but input delivery can run before a
    // delayed timer callback. Once the deadline has passed, honor the hold
    // before classifying this move so a valid long-press cannot become scroll.
    if (finite(nowMs, 0) >= next.holdDeadlineMs && next.canPan && next.zoomEnabled) {
      next.owner = 'canvas-pan-armed';
      next.holdTimerPending = false;
    } else if (distance > CANVAS_TWO_FINGER_HOLD_SLOP_VP) {
      next.owner = 'touchpad-scroll';
      next.holdTimerPending = false;
      next.moved = true;
      return { state: next, action: 'scroll', deltaX, deltaY };
    }
  }

  if (next.owner === 'canvas-pan-armed' && moved) {
    next.owner = 'canvas-pan';
    next.moved = true;
    return { state: next, action: 'pan', deltaX, deltaY };
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
  next.holdTimerPending = false;
  if ((next.owner === 'candidate' || next.owner === 'canvas-pan-armed') &&
    !wasMoved && !next.moved) {
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
