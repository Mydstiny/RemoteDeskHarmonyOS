/**
 * RemoteWheelPolicy.ets - shared remote wheel normalization.
 *
 * HarmonyOS reports a physical mouse wheel as discrete axis events while a
 * touchpad and the in-app two-finger gesture produce continuous deltas. Keep
 * those curves separate, then apply the user's one global direction choice at
 * the final protocol boundary.
 */

export const LEGACY_CONTINUOUS_WHEEL_GAIN: number = 0.08;
// RustDesk forwards each trackpad pan update at its native magnitude and emits
// at least one unit once the delta clears a small noise floor. One RFB wheel
// click is smaller on macOS Screen Sharing, so VNC applies a bounded 2x
// protocol compensation before converting the result into button-4/5 clicks.
export const VNC_CONTINUOUS_WHEEL_GAIN: number = 2.0;
export const LEGACY_CONTINUOUS_WHEEL_MAX_DELTA: number = 2;
export const VNC_CONTINUOUS_WHEEL_MAX_DELTA: number = 32;
export const VNC_CONTINUOUS_WHEEL_NOISE_FLOOR: number = 0.1;
// One physical detent maps to the four-click macOS VNC baseline verified on
// device. RustDesk-style burst acceleration raises consecutive detents to 2x
// or 3x without allowing vendor-specific raw axis magnitudes to over-amplify
// the protocol click count.
export const VNC_PHYSICAL_WHEEL_STEPS: number = 4;
export const VNC_PHYSICAL_WHEEL_MAX_DELTA: number = 12;
export const REMOTE_WHEEL_FAST_BURST_MS: number = 40;
export const REMOTE_WHEEL_MEDIUM_BURST_MS: number = 80;
export const VNC_TOUCHPAD_FLING_INTERVAL_MS: number = 30;
export const VNC_TOUCHPAD_FLING_DECAY: number = 0.97;
export const MOONLIGHT_HIGH_RES_WHEEL_DETENT: number = 120;
export const MOONLIGHT_TOUCHPAD_WHEEL_GAIN: number = 4;

export interface RemoteWheelAccumulation {
  delta: number;
  remainder: number;
}

export function continuousRemoteWheelGain(protocol: string): number {
  return protocol === 'vnc' ? VNC_CONTINUOUS_WHEEL_GAIN : LEGACY_CONTINUOUS_WHEEL_GAIN;
}

export function continuousRemoteWheelMaxDelta(protocol: string): number {
  return protocol === 'vnc' ? VNC_CONTINUOUS_WHEEL_MAX_DELTA :
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
    const scaled: number = rawDelta * VNC_CONTINUOUS_WHEEL_GAIN * speedMultiplier;
    if (Math.abs(scaled) <= VNC_CONTINUOUS_WHEEL_NOISE_FLOOR) {
      return { delta: 0, remainder: 0 };
    }
    let delta: number = scaled > 0 ? Math.floor(scaled) : Math.ceil(scaled);
    // Match RustDesk's trackpad path: a real, non-noise movement must not be
    // swallowed merely because this individual update is fractional.
    if (delta === 0) {
      delta = scaled > 0 ? 1 : -1;
    }
    delta = Math.max(-VNC_CONTINUOUS_WHEEL_MAX_DELTA,
      Math.min(VNC_CONTINUOUS_WHEEL_MAX_DELTA, delta));
    return { delta, remainder: 0 };
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

export function discreteRemoteWheelDelta(rawDelta: number, protocol: string,
  elapsedMs: number = 0): number {
  if (!Number.isFinite(rawDelta) || rawDelta === 0) {
    return 0;
  }
  let burstMultiplier: number = 1;
  if (protocol === 'vnc' && Number.isFinite(elapsedMs) && elapsedMs > 0) {
    if (elapsedMs < REMOTE_WHEEL_FAST_BURST_MS) {
      burstMultiplier = 3;
    } else if (elapsedMs <= REMOTE_WHEEL_MEDIUM_BURST_MS) {
      burstMultiplier = 2;
    }
  }
  let steps: number = 1;
  if (protocol === 'vnc') {
    steps = Math.min(VNC_PHYSICAL_WHEEL_MAX_DELTA,
      VNC_PHYSICAL_WHEEL_STEPS * burstMultiplier);
  }
  return rawDelta > 0 ? steps : -steps;
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

export function shouldStartVncTouchpadFling(lastRawDelta: number,
  speedMultiplier: number): boolean {
  return Number.isFinite(lastRawDelta) && Number.isFinite(speedMultiplier) &&
    speedMultiplier > 0 &&
    Math.abs(lastRawDelta * speedMultiplier) > 2 * speedMultiplier;
}

export function nextVncTouchpadFlingDelta(currentRawDelta: number): number {
  if (!Number.isFinite(currentRawDelta)) {
    return 0;
  }
  return currentRawDelta * VNC_TOUCHPAD_FLING_DECAY;
}

export function applyRemoteWheelDirection(delta: number, reverseWheel: boolean): number {
  return reverseWheel ? -delta : delta;
}
