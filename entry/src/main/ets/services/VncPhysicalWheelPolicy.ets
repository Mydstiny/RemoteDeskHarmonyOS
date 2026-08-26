/**
 * VNC physical touchpad normalization for PC mode and emulator bridges.
 *
 * Some HarmonyOS PC bridges expose a host touchpad as MOUSE and report about
 * +/-45 axis units per sample. Treating those samples as discrete wheel
 * detents invokes VNC burst acceleration and expands one gesture into dozens
 * of RFB button-4/5 clicks.
 */

export const VNC_PHYSICAL_TOUCHPAD_AXIS_UNITS_PER_TICK: number = 45;
export const VNC_PHYSICAL_TOUCHPAD_MAX_DELTA: number = 2;
export const VNC_PHYSICAL_TOUCHPAD_RAPID_SAMPLE_MS: number = 40;

export interface VncPhysicalWheelAccumulation {
  delta: number;
  remainder: number;
}

/**
 * Axis lifecycle and a missing discrete step identify continuous input. A
 * rapid follow-up sample covers emulator bridges that omit both signals.
 */
export function shouldTreatPhysicalAxisAsContinuous(sourceIsTouchpad: boolean,
  axisAction: number, scrollStep: number | undefined, elapsedMs: number): boolean {
  if (sourceIsTouchpad || axisAction > 0) {
    return true;
  }
  if (scrollStep === undefined || !Number.isFinite(scrollStep) || scrollStep === 0) {
    return true;
  }
  return Number.isFinite(elapsedMs) && elapsedMs > 0 &&
    elapsedMs < VNC_PHYSICAL_TOUCHPAD_RAPID_SAMPLE_MS;
}

/** Convert continuous +/-45 axis samples into bounded RFB wheel ticks. */
export function accumulateVncPhysicalTouchpadWheel(rawDelta: number,
  previousRemainder: number, speedMultiplier: number): VncPhysicalWheelAccumulation {
  if (!Number.isFinite(rawDelta) || !Number.isFinite(previousRemainder) ||
    !Number.isFinite(speedMultiplier) || rawDelta === 0 || speedMultiplier <= 0) {
    return { delta: 0, remainder: Number.isFinite(previousRemainder) ? previousRemainder : 0 };
  }
  const rawTotal: number = previousRemainder +
    rawDelta * speedMultiplier / VNC_PHYSICAL_TOUCHPAD_AXIS_UNITS_PER_TICK;
  const boundedTotal: number = Math.max(-VNC_PHYSICAL_TOUCHPAD_MAX_DELTA * 2,
    Math.min(VNC_PHYSICAL_TOUCHPAD_MAX_DELTA * 2, rawTotal));
  let delta: number = boundedTotal > 0 ? Math.floor(boundedTotal) : Math.ceil(boundedTotal);
  delta = Math.max(-VNC_PHYSICAL_TOUCHPAD_MAX_DELTA,
    Math.min(VNC_PHYSICAL_TOUCHPAD_MAX_DELTA, delta));
  return { delta, remainder: boundedTotal - delta };
}
