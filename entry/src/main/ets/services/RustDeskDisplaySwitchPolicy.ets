/**
 * ArkTS-side projection of the native RustDesk display-switch barrier.
 *
 * Geometry is adopted only when the exact latest generation has received a
 * remote display acknowledgement and its target keyframe. A timeout requests
 * a return to the last confirmed display, but never re-enables input into an
 * unconfirmed coordinate space.
 */

export interface RustDeskDisplaySwitchState {
  generation: number
  pendingDisplay: number
  startedAtMs: number
  inputBlocked: boolean
  timeoutNotified: boolean
}

export interface RustDeskDisplaySwitchSignal {
  currentDisplay: number
  readySwitchGeneration: number
  pendingDisplay: number
  confirmedDisplay: number
  inputBlocked: boolean
}

export interface RustDeskDisplaySwitchObservation {
  state: RustDeskDisplaySwitchState
  adoptCapabilities: boolean
  notifyTimeout: boolean
  fallbackDisplay: number
}

export interface RustDeskDisplaySwitchNativeRequest {
  accepted: boolean
  generation: number
}

export interface RustDeskDisplaySwitchBeginHooks {
  releaseInput: () => void
  requestDisplay: (display: number) => RustDeskDisplaySwitchNativeRequest
}

export interface RustDeskDisplaySwitchBeginOutcome {
  request: RustDeskDisplaySwitchNativeRequest
  state: RustDeskDisplaySwitchState
}

export interface RustDeskDisplaySwitchInputReleaseHooks {
  discardPendingMouseMove: () => void
  releaseCanvasPinchInput: () => void
  resetTouchGesture: () => void
  releaseAllHeldKeys: () => void
  clearHeldPointerState: () => void
  resetAllLatches: () => void
  resetTouchpadState: () => void
  invalidateViewport: () => void
}

export function idleRustDeskDisplaySwitchState(): RustDeskDisplaySwitchState {
  return {
    generation: 0,
    pendingDisplay: -1,
    startedAtMs: 0,
    inputBlocked: false,
    timeoutNotified: false
  };
}

export function beginRustDeskDisplaySwitchState(
  accepted: boolean,
  generation: number,
  display: number,
  nowMs: number
): RustDeskDisplaySwitchState {
  if (!accepted || generation <= 0 || display < 0) {
    return idleRustDeskDisplaySwitchState();
  }
  return {
    generation,
    pendingDisplay: display,
    startedAtMs: nowMs,
    inputBlocked: true,
    timeoutNotified: false
  };
}

export function shouldRequestRustDeskDisplaySwitch(
  state: RustDeskDisplaySwitchState,
  display: number,
  currentDisplay: number
): boolean {
  if (display < 0) {
    return false;
  }
  if (!state.inputBlocked) {
    return display !== currentDisplay;
  }
  return display !== state.pendingDisplay || state.timeoutNotified;
}

export function releaseRustDeskInputForDisplaySwitch(
  hooks: RustDeskDisplaySwitchInputReleaseHooks
): void {
  hooks.discardPendingMouseMove();
  hooks.releaseCanvasPinchInput();
  hooks.resetTouchGesture();
  hooks.releaseAllHeldKeys();
  hooks.clearHeldPointerState();
  hooks.resetAllLatches();
  hooks.resetTouchpadState();
  hooks.invalidateViewport();
}

export function requestRustDeskDisplaySwitch(
  display: number,
  nowMs: number,
  hooks: RustDeskDisplaySwitchBeginHooks
): RustDeskDisplaySwitchBeginOutcome {
  if (display < 0) {
    const invalidRequest: RustDeskDisplaySwitchNativeRequest = {
      accepted: false,
      generation: 0
    };
    return {
      request: invalidRequest,
      state: idleRustDeskDisplaySwitchState()
    };
  }
  // Releasing input before entering native is part of the switch transaction:
  // no held control or coalesced move may cross the generation boundary.
  hooks.releaseInput();
  const request: RustDeskDisplaySwitchNativeRequest = hooks.requestDisplay(display);
  return {
    request,
    state: beginRustDeskDisplaySwitchState(
      request.accepted, request.generation, display, nowMs)
  };
}

export function observeRustDeskDisplaySwitch(
  state: RustDeskDisplaySwitchState,
  signal: RustDeskDisplaySwitchSignal,
  nowMs: number,
  timeoutMs: number
): RustDeskDisplaySwitchObservation {
  if (!state.inputBlocked || state.pendingDisplay < 0 || state.generation <= 0) {
    return {
      state: idleRustDeskDisplaySwitchState(),
      adoptCapabilities: true,
      notifyTimeout: false,
      fallbackDisplay: -1
    };
  }
  const ready: boolean =
    signal.currentDisplay === state.pendingDisplay &&
    signal.readySwitchGeneration >= state.generation &&
    signal.pendingDisplay < 0 &&
    !signal.inputBlocked;
  if (ready) {
    return {
      state: idleRustDeskDisplaySwitchState(),
      adoptCapabilities: true,
      notifyTimeout: false,
      fallbackDisplay: -1
    };
  }
  const timedOut: boolean = timeoutMs > 0 &&
    nowMs - state.startedAtMs >= timeoutMs &&
    !state.timeoutNotified;
  return {
    state: timedOut ? {
      generation: state.generation,
      pendingDisplay: state.pendingDisplay,
      startedAtMs: state.startedAtMs,
      inputBlocked: true,
      timeoutNotified: true
    } : state,
    adoptCapabilities: false,
    notifyTimeout: timedOut,
    fallbackDisplay: timedOut && signal.confirmedDisplay >= 0 &&
      signal.confirmedDisplay !== state.pendingDisplay ? signal.confirmedDisplay : -1
  };
}
