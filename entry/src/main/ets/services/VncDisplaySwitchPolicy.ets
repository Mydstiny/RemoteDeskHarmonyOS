/**
 * Session-scoped VNC monitor switch state.
 *
 * UltraVNC exposes a monitor count but no per-request acknowledgement. The
 * native layer therefore reports the first complete framebuffer update after
 * a request as the confirmation point. This policy keeps input blocked until
 * that point and fences stale generations in ArkTS.
 */

export interface VncDisplaySwitchState {
  generation: number
  pendingMonitor: number
  startedAtMs: number
  inputBlocked: boolean
  timeoutNotified: boolean
}

export interface VncDisplaySwitchSignal {
  currentMonitor: number
  pendingMonitor: number
  switchGeneration: number
  inputBlocked: boolean
  lastResult: string
}

export interface VncDisplaySwitchObservation {
  state: VncDisplaySwitchState
  adopt: boolean
  notifyTimeout: boolean
}

export interface VncDisplaySwitchInputReleaseHooks {
  discardPendingMouseMove: () => void
  releaseCanvasPinchInput: () => void
  resetTouchGesture: () => void
  releaseAllHeldKeys: () => void
  clearHeldPointerState: () => void
  resetAllLatches: () => void
  resetTouchpadState: () => void
  invalidateViewport: () => void
}

export function idleVncDisplaySwitchState(): VncDisplaySwitchState {
  return {
    generation: 0,
    pendingMonitor: -1,
    startedAtMs: 0,
    inputBlocked: false,
    timeoutNotified: false
  };
}

export function releaseVncInputForDisplaySwitch(
  hooks: VncDisplaySwitchInputReleaseHooks
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

export function beginVncDisplaySwitchState(accepted: boolean, generation: number,
  monitor: number, nowMs: number): VncDisplaySwitchState {
  if (!accepted || generation <= 0 || monitor < 0) {
    return idleVncDisplaySwitchState();
  }
  return {
    generation,
    pendingMonitor: monitor,
    startedAtMs: nowMs,
    inputBlocked: true,
    timeoutNotified: false
  };
}

export function shouldRequestVncDisplaySwitch(state: VncDisplaySwitchState,
  monitor: number, currentMonitor: number): boolean {
  if (monitor < 0) {
    return false;
  }
  if (!state.inputBlocked) {
    return monitor !== currentMonitor;
  }
  // UltraVNC has no request acknowledgement or request cancellation wire
  // contract. Serialize requests until the pending framebuffer is confirmed
  // or times out, so an early frame cannot confirm a later target by mistake.
  return state.timeoutNotified;
}

export function observeVncDisplaySwitch(state: VncDisplaySwitchState,
  signal: VncDisplaySwitchSignal, nowMs: number,
  timeoutMs: number): VncDisplaySwitchObservation {
  if (!state.inputBlocked || state.pendingMonitor < 0 || state.generation <= 0) {
    return { state: idleVncDisplaySwitchState(), adopt: true, notifyTimeout: false };
  }
  const confirmed: boolean = signal.currentMonitor === state.pendingMonitor &&
    signal.switchGeneration >= state.generation &&
    signal.pendingMonitor < 0 && !signal.inputBlocked &&
    signal.lastResult === 'confirmed';
  if (confirmed) {
    return { state: idleVncDisplaySwitchState(), adopt: true, notifyTimeout: false };
  }
  const timedOut: boolean = timeoutMs > 0 &&
    nowMs - state.startedAtMs >= timeoutMs && !state.timeoutNotified;
  return {
    state: timedOut ? {
      generation: state.generation,
      pendingMonitor: state.pendingMonitor,
      startedAtMs: state.startedAtMs,
      inputBlocked: true,
      timeoutNotified: true
    } : state,
    adopt: false,
    notifyTimeout: timedOut
  };
}

export function vncMonitorLabel(monitor: number): string {
  return monitor >= 0 ? '显示器 ' + (monitor + 1).toString() : '显示器';
}
