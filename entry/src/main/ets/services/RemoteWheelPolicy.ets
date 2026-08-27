/**
 * RemoteWheelPolicy.ets - shared remote wheel normalization.
 *
 * HarmonyOS reports a physical mouse wheel as discrete axis events while a
 * touchpad and the in-app two-finger gesture produce continuous deltas. Keep
 * those curves separate, then apply the user's one global direction choice at
 * the final protocol boundary.
 */

export const LEGACY_CONTINUOUS_WHEEL_GAIN: number = 0.08;
// Virtual touch coordinates are expressed in vp on every device class. Keep
// their VNC curve independent from physical-axis units and accumulate enough
// distance for one portable RFB button-4/5 detent.
export const VNC_VIRTUAL_WHEEL_VP_PER_TICK: number = 10;
export const VNC_VIRTUAL_WHEEL_MAX_DELTA: number = 2;
export const LEGACY_CONTINUOUS_WHEEL_MAX_DELTA: number = 2;
export const MOONLIGHT_HIGH_RES_WHEEL_DETENT: number = 120;
export const MOONLIGHT_TOUCHPAD_WHEEL_GAIN: number = 4;

export interface RemoteWheelAccumulation {
  delta: number;
  remainder: number;
}

/** Preserve all finite non-zero motion so sub-vp gestures can accumulate. */
export function shouldForwardContinuousRemoteWheelSample(rawDelta: number): boolean {
  return Number.isFinite(rawDelta) && rawDelta !== 0;
}

export function continuousRemoteWheelGain(protocol: string): number {
  return protocol === 'vnc' ? 1 / VNC_VIRTUAL_WHEEL_VP_PER_TICK :
    LEGACY_CONTINUOUS_WHEEL_GAIN;
}

export function continuousRemoteWheelMaxDelta(protocol: string): number {
  return protocol === 'vnc' ? VNC_VIRTUAL_WHEEL_MAX_DELTA :
    LEGACY_CONTINUOUS_WHEEL_MAX_DELTA;
}

export function accumulateContinuousRemoteWheel(
  rawDelta: number,
  previousRemainder: number,
  speedMultiplier: number,
  protocol: string
): RemoteWheelAccumulation {
  if (!Number.isFinite(rawDelta) || !Number.isFinite(previousRemainder) ||
    !Number.isFinite(speedMultiplier) || rawDelta === 0 || speedMultiplier <= 0) {
    return { delta: 0, remainder: Number.isFinite(previousRemainder) ? previousRemainder : 0 };
  }
  if (protocol === 'vnc') {
    const direction: number = rawDelta > 0 ? 1 : -1;
    const cleanRemainder: number = previousRemainder !== 0 &&
      (previousRemainder > 0 ? 1 : -1) !== direction ? 0 : previousRemainder;
    const total: number = cleanRemainder + rawDelta * speedMultiplier /
      VNC_VIRTUAL_WHEEL_VP_PER_TICK;
    const whole: number = total > 0 ? Math.floor(total) : Math.ceil(total);
    const delta: number = Math.max(-VNC_VIRTUAL_WHEEL_MAX_DELTA,
      Math.min(VNC_VIRTUAL_WHEEL_MAX_DELTA, whole));
    // Drop whole-tick overflow beyond the per-frame cap instead of retaining
    // a backlog that could continue after the user's fingers stop moving.
    return { delta, remainder: total - whole };
  }
  const maxDelta: number = continuousRemoteWheelMaxDelta(protocol);
  const rawTotal: number = previousRemainder +
    rawDelta * continuousRemoteWheelGain(protocol) * speedMultiplier;
  // Do not retain an unbounded wheel backlog after one unusually large axis
  // sample. Two output batches are enough to preserve acceleration smoothly.
  const total: number = Math.max(-maxDelta * 2, Math.min(maxDelta * 2, rawTotal));
  let delta: number = total > 0 ? Math.floor(total) : Math.ceil(total);
  delta = Math.max(-maxDelta, Math.min(maxDelta, delta));
  return {
    delta,
    remainder: total - delta
  };
}

export function discreteRemoteWheelDelta(rawDelta: number, _protocol: string,
  _elapsedMs: number = 0): number {
  if (!Number.isFinite(rawDelta) || rawDelta === 0) {
    return 0;
  }
  return rawDelta > 0 ? 1 : -1;
}

export function moonlightAxisScrollAmount(rawDelta: number,
  touchpadSource: boolean): number {
  if (!Number.isFinite(rawDelta) || rawDelta === 0) { return 0; }
  if (!touchpadSource) {
    // Harmony mouse vendors report one detent as either +/-1 or +/-120.
    // Moonlight already defines one high-resolution detent as 120, so only
    // the direction is portable. Multiplying the raw vendor value can turn a
    // single notch into 14,400 units and jump an entire remote page.
    return rawDelta > 0 ? MOONLIGHT_HIGH_RES_WHEEL_DETENT :
      -MOONLIGHT_HIGH_RES_WHEEL_DETENT;
  }
  let amount: number = Math.round(rawDelta * MOONLIGHT_TOUCHPAD_WHEEL_GAIN);
  if (amount === 0) { amount = rawDelta > 0 ? 1 : -1; }
  return Math.max(-MOONLIGHT_HIGH_RES_WHEEL_DETENT,
    Math.min(MOONLIGHT_HIGH_RES_WHEEL_DETENT, amount));
}

export function applyRemoteWheelDirection(delta: number, reverseWheel: boolean): number {
  return reverseWheel ? -delta : delta;
}
