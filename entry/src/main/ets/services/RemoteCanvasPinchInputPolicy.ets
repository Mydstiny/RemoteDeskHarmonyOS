/** A pinch owns a finger stream until the final Up/Cancel has been delivered. */
export type CanvasPinchInputPhase = 'idle' | 'gesture' | 'draining';
export type CanvasPinchTouchEvent = 'down' | 'move' | 'up' | 'cancel';

export interface CanvasPinchTouchState {
  phase: CanvasPinchInputPhase;
  fingerCount: number;
}

function nonNegative(value: number): number {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

/**
 * A recognized ArkUI pinch may consume only the finger stream that produced
 * it. Mouse, pen and physical touchpad events continue through their normal
 * input path.
 */
export function shouldConsumeCanvasPinchTouch(inputConsumed: boolean,
  isFingerSource: boolean): boolean {
  return inputConsumed && isFingerSource;
}

export function claimCanvasPinchTouchState(observedFingerCount: number): CanvasPinchTouchState {
  return {
    phase: 'gesture',
    // PinchGesture has two fingers even when the preceding TouchEvent was
    // coalesced and did not expose the current touches array.
    fingerCount: Math.max(2, nonNegative(observedFingerCount))
  };
}

export function drainCanvasPinchTouchState(state: CanvasPinchTouchState): CanvasPinchTouchState {
  if (state.phase === 'idle') {
    return { phase: 'idle', fingerCount: 0 };
  }
  return {
    phase: 'draining',
    fingerCount: Math.max(0, nonNegative(state.fingerCount))
  };
}

function remainingAfterLift(previousCount: number, activeCount: number,
  changedCount: number): number {
  const previous: number = nonNegative(previousCount);
  const active: number = nonNegative(activeCount);
  const changed: number = nonNegative(changedCount);
  if (changed > 0) {
    // HarmonyOS may include the lifted finger in touches for Up, or may
    // expose only the fingers that remain. The minimum of both interpretations
    // gives the same result for either event shape.
    const fromPrevious: number = Math.max(0, previous - changed);
    return active > 0 ? Math.min(fromPrevious, active) : fromPrevious;
  }
  if (active > 0) {
    return previous > 0 ? Math.min(previous, active) : active;
  }
  return Math.max(0, previous - 1);
}

/** Advance ownership using only the counts guaranteed by TouchEvent. */
export function advanceCanvasPinchTouchState(state: CanvasPinchTouchState,
  event: CanvasPinchTouchEvent, activeTouchCount: number,
  changedTouchCount: number): CanvasPinchTouchState {
  if (state.phase === 'idle') {
    return { phase: 'idle', fingerCount: 0 };
  }
  const active: number = nonNegative(activeTouchCount);
  const changed: number = nonNegative(changedTouchCount);
  if (event === 'cancel') {
    return { phase: 'idle', fingerCount: 0 };
  }
  if (event === 'up') {
    const remaining: number = remainingAfterLift(state.fingerCount, active, changed);
    return remaining <= 0 ? { phase: 'idle', fingerCount: 0 } : {
      phase: state.phase,
      fingerCount: remaining
    };
  }
  if (event === 'down') {
    return {
      phase: state.phase,
      fingerCount: Math.max(state.fingerCount, active > 0 ? active : state.fingerCount + Math.max(1, changed))
    };
  }
  return {
    phase: state.phase,
    fingerCount: active > 0 ? active : state.fingerCount
  };
}

/**
 * A Down with one newly observed finger after gesture end is a new sequence,
 * not a third finger in the old pinch. Let the normal touch state machine own
 * it so a missed terminal event cannot permanently swallow input.
 */
export function shouldStartNewCanvasPinchTouchSequence(phase: CanvasPinchInputPhase,
  event: CanvasPinchTouchEvent, activeTouchCount: number, changedTouchCount: number): boolean {
  return phase === 'draining' && event === 'down' &&
    nonNegative(activeTouchCount) <= 1 && nonNegative(changedTouchCount) <= 1;
}
