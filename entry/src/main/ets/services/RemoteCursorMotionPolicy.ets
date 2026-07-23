export type RemoteCursorOwner = 'remote' | 'local-gesture' | 'local-settling' | 'remote-silent';

export interface RemoteCursorMotionState {
  displayX: number;
  displayY: number;
  localTargetX: number;
  localTargetY: number;
  remoteObservedX: number;
  remoteObservedY: number;
  remoteReady: boolean;
  owner: RemoteCursorOwner;
  localGestureActive: boolean;
  localLastInputAtMs: number;
  localSettlingUntilMs: number;
  remoteObservedAtMs: number;
}

export const REMOTE_CURSOR_LOCAL_SETTLE_MS: number = 180;
export const REMOTE_CURSOR_REMOTE_CONVERGENCE_PX: number = 12;
export const REMOTE_CURSOR_REMOTE_SILENCE_MS: number = 750;

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function nonNegativeTime(value: number): number {
  return Math.max(0, finite(value, 0));
}

function distance(x1: number, y1: number, x2: number, y2: number): number {
  const dx: number = x1 - x2;
  const dy: number = y1 - y2;
  return Math.sqrt(dx * dx + dy * dy);
}

function copyState(previous: RemoteCursorMotionState): RemoteCursorMotionState {
  return {
    displayX: previous.displayX,
    displayY: previous.displayY,
    localTargetX: previous.localTargetX,
    localTargetY: previous.localTargetY,
    remoteObservedX: previous.remoteObservedX,
    remoteObservedY: previous.remoteObservedY,
    remoteReady: previous.remoteReady,
    owner: previous.owner,
    localGestureActive: previous.localGestureActive,
    localLastInputAtMs: previous.localLastInputAtMs,
    localSettlingUntilMs: previous.localSettlingUntilMs,
    remoteObservedAtMs: previous.remoteObservedAtMs
  };
}

/**
 * The cursor bitmap and cursor coordinates arrive on different protocol paths.
 * This policy intentionally keeps local touchpad output separate from remote
 * observation so a delayed remote echo cannot pull an active pointer backward.
 */
export function createRemoteCursorMotionState(initialX: number,
  initialY: number): RemoteCursorMotionState {
  const x: number = finite(initialX, 0);
  const y: number = finite(initialY, 0);
  return {
    displayX: x,
    displayY: y,
    localTargetX: x,
    localTargetY: y,
    remoteObservedX: x,
    remoteObservedY: y,
    remoteReady: false,
    owner: 'remote',
    localGestureActive: false,
    localLastInputAtMs: 0,
    localSettlingUntilMs: 0,
    remoteObservedAtMs: 0
  };
}

export function beginLocalCursorGesture(previous: RemoteCursorMotionState,
  nowMs: number): RemoteCursorMotionState {
  const next: RemoteCursorMotionState = copyState(previous);
  const now: number = nonNegativeTime(nowMs);
  next.localGestureActive = true;
  next.owner = 'local-gesture';
  next.localSettlingUntilMs = Math.max(next.localSettlingUntilMs, now);
  return next;
}

/** Apply a controller-originated target immediately to the rendered cursor. */
export function applyLocalCursorTarget(previous: RemoteCursorMotionState, x: number, y: number,
  nowMs: number): RemoteCursorMotionState {
  const next: RemoteCursorMotionState = copyState(previous);
  const now: number = nonNegativeTime(nowMs);
  const targetX: number = finite(x, previous.displayX);
  const targetY: number = finite(y, previous.displayY);
  next.displayX = targetX;
  next.displayY = targetY;
  next.localTargetX = targetX;
  next.localTargetY = targetY;
  next.localLastInputAtMs = now;
  next.localSettlingUntilMs = now + REMOTE_CURSOR_LOCAL_SETTLE_MS;
  next.owner = next.localGestureActive ? 'local-gesture' : 'local-settling';
  return next;
}

/** Keep the final local target stable briefly after the finger leaves the surface. */
export function endLocalCursorGesture(previous: RemoteCursorMotionState,
  nowMs: number): RemoteCursorMotionState {
  const next: RemoteCursorMotionState = copyState(previous);
  const now: number = nonNegativeTime(nowMs);
  next.localGestureActive = false;
  if (next.localLastInputAtMs > 0) {
    next.localSettlingUntilMs = Math.max(next.localSettlingUntilMs,
      now + REMOTE_CURSOR_LOCAL_SETTLE_MS);
    next.owner = 'local-settling';
  } else {
    next.owner = 'remote';
  }
  return next;
}

/**
 * Advance a local settling window without inventing a remote acknowledgement.
 * A previously deferred remote value may only converge when it is close to the
 * final local target; large values wait for a later independent observation.
 */
export function advanceRemoteCursorMotion(previous: RemoteCursorMotionState,
  nowMs: number): RemoteCursorMotionState {
  const next: RemoteCursorMotionState = copyState(previous);
  const now: number = nonNegativeTime(nowMs);
  if (next.localGestureActive || next.owner !== 'local-settling' ||
    now < next.localSettlingUntilMs) {
    return next;
  }

  const freshRemote: boolean = next.remoteReady && next.remoteObservedAtMs >= next.localLastInputAtMs;
  const closeToTarget: boolean = freshRemote && distance(next.remoteObservedX, next.remoteObservedY,
    next.localTargetX, next.localTargetY) <= REMOTE_CURSOR_REMOTE_CONVERGENCE_PX;
  if (closeToTarget) {
    next.displayX = next.remoteObservedX;
    next.displayY = next.remoteObservedY;
    next.owner = 'remote';
    return next;
  }
  next.owner = 'remote-silent';
  return next;
}

/**
 * Record a peer-originated cursor coordinate. During local input it is only an
 * observation. After the local settle window, a near echo can converge at once.
 * A far coordinate takes ownership only after a full silent interval since the
 * last local input, so queued old events can never win by arriving twice.
 */
export function observeRemoteCursorPosition(previous: RemoteCursorMotionState,
  x: number, y: number, nowMs: number): RemoteCursorMotionState {
  const next: RemoteCursorMotionState = copyState(previous);
  const now: number = nonNegativeTime(nowMs);
  next.remoteObservedX = finite(x, previous.remoteObservedX);
  next.remoteObservedY = finite(y, previous.remoteObservedY);
  next.remoteReady = true;
  next.remoteObservedAtMs = now;

  if (next.localGestureActive || (next.owner === 'local-settling' &&
    now < next.localSettlingUntilMs)) {
    return next;
  }

  const idleForMs: number = next.localLastInputAtMs > 0 ? now - next.localLastInputAtMs :
    REMOTE_CURSOR_REMOTE_SILENCE_MS;
  const closeToTarget: boolean = distance(next.remoteObservedX, next.remoteObservedY,
    next.localTargetX, next.localTargetY) <= REMOTE_CURSOR_REMOTE_CONVERGENCE_PX;
  const trustedRemote: boolean = next.localLastInputAtMs <= 0 ||
    (now >= next.localLastInputAtMs &&
      (closeToTarget || idleForMs >= REMOTE_CURSOR_REMOTE_SILENCE_MS));
  if (trustedRemote) {
    next.displayX = next.remoteObservedX;
    next.displayY = next.remoteObservedY;
    next.owner = 'remote';
  } else {
    next.owner = 'remote-silent';
  }
  return next;
}
