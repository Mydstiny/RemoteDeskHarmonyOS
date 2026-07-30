/**
 * ArkTS-side projection of the native RustDesk display-switch barrier.
 *
 * Geometry is adopted only when the exact latest generation has received a
 * remote display acknowledgement and its target keyframe. A timeout may
 * notify the user, but never re-enables input into an unconfirmed coordinate
 * space.
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
  inputBlocked: boolean
}

export interface RustDeskDisplaySwitchObservation {
  state: RustDeskDisplaySwitchState
  adoptCapabilities: boolean
  notifyTimeout: boolean
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
      notifyTimeout: false
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
      notifyTimeout: false
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
    notifyTimeout: timedOut
  };
}
