import {
  accumulateContinuousRemoteWheel,
  applyRemoteWheelDirection
} from './RemoteWheelPolicy';
import {
  HARMONY_KEYCODE_CTRL_LEFT,
  HARMONY_KEYCODE_META_LEFT,
  RemoteKeyboardLayout
} from './RemotePhysicalKeyboardPolicy';

export const RUSTDESK_PC_CONTROL_MODE: number = 2;
export const RUSTDESK_TOUCHPAD_ZOOM_EQUALS_KEYCODE: number = 2058;
export const RUSTDESK_TOUCHPAD_ZOOM_MINUS_KEYCODE: number = 2057;
export const PHYSICAL_TOUCHPAD_PINCH_STEP_THRESHOLD: number = 0.08;
export const PHYSICAL_TOUCHPAD_PINCH_MAX_STEPS: number = 3;

export interface PhysicalTouchpadWheelState {
  horizontalRemainder: number;
  verticalRemainder: number;
}

export interface PhysicalTouchpadWheelResult {
  x: number;
  y: number;
  state: PhysicalTouchpadWheelState;
}

export interface PhysicalTouchpadPinchState {
  accumulation: number;
}

export interface PhysicalTouchpadPinchResult {
  steps: number;
  state: PhysicalTouchpadPinchState;
}

export function shouldUseRustDeskPhysicalTouchpad(protocol: string,
  isDesktopDevice: boolean, controlMode: number, sourceIsTouchpad: boolean): boolean {
  return protocol === 'rustdesk' && isDesktopDevice &&
    controlMode === RUSTDESK_PC_CONTROL_MODE && sourceIsTouchpad;
}

export function resetPhysicalTouchpadWheelState(): PhysicalTouchpadWheelState {
  return { horizontalRemainder: 0, verticalRemainder: 0 };
}

export function accumulateRustDeskPhysicalTouchpadWheel(rawX: number, rawY: number,
  previous: PhysicalTouchpadWheelState, speedMultiplier: number,
  reverseWheel: boolean): PhysicalTouchpadWheelResult {
  const x = accumulateContinuousRemoteWheel(rawX, previous.horizontalRemainder,
    speedMultiplier, 'rustdesk');
  const y = accumulateContinuousRemoteWheel(rawY, previous.verticalRemainder,
    speedMultiplier, 'rustdesk');
  return {
    x: applyRemoteWheelDirection(x.delta, reverseWheel),
    y: applyRemoteWheelDirection(y.delta, reverseWheel),
    state: { horizontalRemainder: x.remainder, verticalRemainder: y.remainder }
  };
}

export function resetPhysicalTouchpadPinchState(): PhysicalTouchpadPinchState {
  return { accumulation: 0 };
}

export function accumulatePhysicalTouchpadPinch(rawScale: number,
  previous: PhysicalTouchpadPinchState): PhysicalTouchpadPinchResult {
  const previousAccumulation: number = Number.isFinite(previous.accumulation) ?
    previous.accumulation : 0;
  if (!Number.isFinite(rawScale) || rawScale <= 0) {
    return { steps: 0, state: { accumulation: previousAccumulation } };
  }

  // API 23 reports a scale ratio around 1. Accumulate the ratio delta so both
  // per-frame and cumulative device reporting styles reach the same threshold.
  const boundedDelta: number = Math.max(-0.5, Math.min(0.5, rawScale - 1));
  const maxAccumulation = PHYSICAL_TOUCHPAD_PINCH_STEP_THRESHOLD *
    PHYSICAL_TOUCHPAD_PINCH_MAX_STEPS;
  const total: number = Math.max(-maxAccumulation,
    Math.min(maxAccumulation, previousAccumulation + boundedDelta));
  let steps: number = total >= 0 ?
    Math.floor(total / PHYSICAL_TOUCHPAD_PINCH_STEP_THRESHOLD) :
    Math.ceil(total / PHYSICAL_TOUCHPAD_PINCH_STEP_THRESHOLD);
  steps = Math.max(-PHYSICAL_TOUCHPAD_PINCH_MAX_STEPS,
    Math.min(PHYSICAL_TOUCHPAD_PINCH_MAX_STEPS, steps));
  return {
    steps,
    state: {
      accumulation: total - steps * PHYSICAL_TOUCHPAD_PINCH_STEP_THRESHOLD
    }
  };
}

export function physicalTouchpadZoomModifierKeyCode(layout: RemoteKeyboardLayout): number {
  return layout === RemoteKeyboardLayout.MACOS ?
    HARMONY_KEYCODE_META_LEFT : HARMONY_KEYCODE_CTRL_LEFT;
}

export function physicalTouchpadZoomKeyCode(steps: number): number {
  return steps >= 0 ? RUSTDESK_TOUCHPAD_ZOOM_EQUALS_KEYCODE :
    RUSTDESK_TOUCHPAD_ZOOM_MINUS_KEYCODE;
}
