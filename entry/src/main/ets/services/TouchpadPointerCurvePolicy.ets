export interface TouchpadPointerCurveState {
  smoothedSpeed: number;
  lastTimeMs: number;
}

export interface TouchpadPointerCurveResult {
  gain: number;
  state: TouchpadPointerCurveState;
}

export const TOUCHPAD_CURVE_MIN_GAIN: number = 0.55;
export const TOUCHPAD_CURVE_MAX_GAIN: number = 1.90;
export const TOUCHPAD_CURVE_SMOOTHING: number = 0.25;
const PRECISION_SPEED: number = 0.10;
const FAST_SPEED: number = 1.20;

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

export function resetTouchpadPointerCurveState(): TouchpadPointerCurveState {
  return { smoothedSpeed: 0, lastTimeMs: 0 };
}

export function touchpadPointerCurve(stepDx: number, stepDy: number, nowMs: number,
  previous: TouchpadPointerCurveState): TouchpadPointerCurveResult {
  const dx: number = finite(stepDx, 0);
  const dy: number = finite(stepDy, 0);
  const now: number = finite(nowMs, 0);
  const distance: number = Math.sqrt(dx * dx + dy * dy);
  let dt: number = previous.lastTimeMs > 0 && now > previous.lastTimeMs ? now - previous.lastTimeMs : 16;
  if (!Number.isFinite(dt) || dt < 8 || dt > 100) { dt = 16; }
  const instantSpeed: number = distance / dt;
  const smoothedSpeed: number = previous.lastTimeMs > 0 ?
    previous.smoothedSpeed + (instantSpeed - previous.smoothedSpeed) * TOUCHPAD_CURVE_SMOOTHING : instantSpeed;
  const normalized: number = Math.max(0, Math.min(1,
    (smoothedSpeed - PRECISION_SPEED) / (FAST_SPEED - PRECISION_SPEED)));
  const eased: number = normalized * normalized * (3 - 2 * normalized);
  const gain: number = TOUCHPAD_CURVE_MIN_GAIN +
    (TOUCHPAD_CURVE_MAX_GAIN - TOUCHPAD_CURVE_MIN_GAIN) * eased;
  return { gain, state: { smoothedSpeed, lastTimeMs: now > 0 ? now : previous.lastTimeMs } };
}

export function clampTouchpadEffectiveGain(gain: number, userSpeed: number): number {
  const base: number = Math.max(TOUCHPAD_CURVE_MIN_GAIN, Math.min(TOUCHPAD_CURVE_MAX_GAIN, finite(gain, 1)));
  const speed: number = Math.max(0.4, Math.min(2.2, finite(userSpeed, 1)));
  return Math.min(3.0, base * speed);
}
