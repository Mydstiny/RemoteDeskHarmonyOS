/**
 * VNC physical wheel normalization for HarmonyOS PC input.
 *
 * `scrollStep` is documented as mouse-wheel-only evidence. Some PC bridges
 * expose a physical touchpad as MOUSE, but those streams omit `scrollStep` and
 * carry device-specific raw units. Keep classification and normalization
 * independent so neither Axis lifecycle values nor a fixed raw divisor can
 * make an actual mouse or touchpad unusably slow.
 */

export const VNC_PHYSICAL_TOUCHPAD_SAMPLES_PER_TICK: number = 4;
export const VNC_PHYSICAL_TOUCHPAD_MAX_DELTA: number = 2;
export const VNC_PHYSICAL_TOUCHPAD_MAX_NORMALIZED_SAMPLE: number = 4;
export const VNC_PHYSICAL_TOUCHPAD_IDLE_RESET_MS: number = 160;
export const VNC_AXIS_ACTION_NONE: number = 0;
export const VNC_AXIS_ACTION_BEGIN: number = 1;
export const VNC_AXIS_ACTION_END: number = 3;
export const VNC_AXIS_ACTION_CANCEL: number = 4;

export interface VncPhysicalWheelState {
  remainder: number;
  axisUnit: number;
  direction: number;
  lastSampleAtMs: number;
  sourceTool: number;
}

export interface VncPhysicalWheelAccumulation {
  delta: number;
  state: VncPhysicalWheelState;
}

export interface VncPhysicalWheelRoute {
  continuous: boolean;
  resetBefore: boolean;
  resetAfter: boolean;
  cancel: boolean;
}

export function resetVncPhysicalWheelState(): VncPhysicalWheelState {
  return {
    remainder: 0,
    axisUnit: 0,
    direction: 0,
    lastSampleAtMs: 0,
    sourceTool: -1
  };
}

function finitePositive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

export function hasPhysicalMouseScrollStep(scrollStep: number | undefined): boolean {
  return scrollStep !== undefined && Number.isFinite(scrollStep) && scrollStep !== 0;
}

/** Resolve source classification and lifecycle before any wheel delta math. */
export function resolveVncPhysicalWheelRoute(sourceIsTouchpad: boolean,
  axisAction: number, scrollStep: number | undefined): VncPhysicalWheelRoute {
  if (hasPhysicalMouseScrollStep(scrollStep)) {
    return {
      continuous: false,
      resetBefore: false,
      resetAfter: false,
      cancel: false
    };
  }
  // An optional scrollStep cannot by itself distinguish an old mouse bridge.
  // MOUSE + NONE therefore remains one discrete detent. Explicit TOUCHPAD or
  // BEGIN/UPDATE/END/CANCEL lifecycle is the required continuous evidence.
  const continuous: boolean = sourceIsTouchpad || axisAction !== VNC_AXIS_ACTION_NONE;
  const cancel: boolean = continuous && axisAction === VNC_AXIS_ACTION_CANCEL;
  return {
    continuous,
    resetBefore: continuous && axisAction === VNC_AXIS_ACTION_BEGIN,
    resetAfter: continuous &&
      (axisAction === VNC_AXIS_ACTION_END || cancel),
    cancel
  };
}

export function shouldTreatPhysicalAxisAsContinuous(sourceIsTouchpad: boolean,
  axisAction: number, scrollStep: number | undefined, _elapsedMs: number = 0): boolean {
  return resolveVncPhysicalWheelRoute(sourceIsTouchpad, axisAction, scrollStep).continuous;
}

/** One physical mouse event represents one portable RFB wheel detent. */
export function vncPhysicalMouseWheelDelta(rawDelta: number): number {
  if (!Number.isFinite(rawDelta) || rawDelta === 0) {
    return 0;
  }
  return rawDelta > 0 ? 1 : -1;
}

/**
 * Normalize one continuous touchpad sample without assuming whether the
 * device reports 1, 45 or 120 raw units. The smallest meaningful sample in a
 * gesture is the device-unit floor; larger samples preserve bounded relative
 * velocity, while an immediate downward rebase prevents a large first sample
 * from starving later fine motion. A direction reversal drops only the stale
 * fractional remainder, never the new motion.
 */
export function accumulateVncPhysicalTouchpadWheel(rawDelta: number,
  previous: VncPhysicalWheelState,
  speedMultiplier: number,
  sampledAtMs: number = 0,
  sourceTool: number = -1): VncPhysicalWheelAccumulation {
  const validSampleAtMs: number = finitePositive(sampledAtMs) ? sampledAtMs : 0;
  const validPreviousAtMs: number = finitePositive(previous.lastSampleAtMs) ?
    previous.lastSampleAtMs : 0;
  const validSourceTool: number = Number.isFinite(sourceTool) ? sourceTool : -1;
  const validPreviousSourceTool: number = Number.isFinite(previous.sourceTool) ?
    previous.sourceTool : -1;
  const sourceChanged: boolean = validSourceTool >= 0 && validPreviousSourceTool >= 0 &&
    validSourceTool !== validPreviousSourceTool;
  const idleExpired: boolean = validSampleAtMs > 0 && validPreviousAtMs > 0 &&
    validSampleAtMs - validPreviousAtMs > VNC_PHYSICAL_TOUCHPAD_IDLE_RESET_MS;
  const previousRemainder: number = !sourceChanged && !idleExpired &&
    Number.isFinite(previous.remainder) ? previous.remainder : 0;
  const previousAxisUnit: number = !sourceChanged && !idleExpired &&
    finitePositive(previous.axisUnit) ? previous.axisUnit : 0;
  const previousDirection: number = !sourceChanged && !idleExpired ?
    (previous.direction > 0 ? 1 : (previous.direction < 0 ? -1 : 0)) : 0;
  if (!Number.isFinite(rawDelta) || rawDelta === 0 || !finitePositive(speedMultiplier)) {
    return {
      delta: 0,
      state: {
        remainder: previousRemainder,
        axisUnit: previousAxisUnit,
        direction: previousDirection,
        lastSampleAtMs: validPreviousAtMs,
        sourceTool: validPreviousSourceTool
      }
    };
  }

  const direction: number = rawDelta > 0 ? 1 : -1;
  const magnitude: number = Math.abs(rawDelta);
  const axisUnit: number = previousAxisUnit > 0 ?
    Math.min(previousAxisUnit, magnitude) : magnitude;
  const normalizedMagnitude: number = Math.min(VNC_PHYSICAL_TOUCHPAD_MAX_NORMALIZED_SAMPLE,
    magnitude / axisUnit);
  const cleanRemainder: number = previousDirection !== 0 && previousDirection !== direction ?
    0 : previousRemainder;
  const total: number = cleanRemainder + direction * normalizedMagnitude *
    speedMultiplier / VNC_PHYSICAL_TOUCHPAD_SAMPLES_PER_TICK;
  const whole: number = total > 0 ? Math.floor(total) : Math.ceil(total);
  const delta: number = Math.max(-VNC_PHYSICAL_TOUCHPAD_MAX_DELTA,
    Math.min(VNC_PHYSICAL_TOUCHPAD_MAX_DELTA, whole));
  // Drop any whole-tick overflow beyond the per-sample cap. Retaining it as a
  // backlog would keep scrolling after the physical gesture has slowed down.
  const remainder: number = total - whole;

  return {
    delta,
    state: {
      remainder,
      axisUnit,
      direction,
      lastSampleAtMs: validSampleAtMs,
      sourceTool: validSourceTool
    }
  };
}
