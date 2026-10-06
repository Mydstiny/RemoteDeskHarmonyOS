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
// 2026-10-07: 4 vp per tick (with the 10x wire gain below) scrolled a whole page per swipe; 12 vp keeps a
// two-finger swipe close to RDP's distance, and 设置 › 远程滚轮 scales it per user.
export const VNC_VIRTUAL_WHEEL_VP_PER_TICK: number = 12;
export const VNC_VIRTUAL_WHEEL_MAX_DELTA: number = 4;
// Device acceptance shows that one RFB button-4/5 click moves macOS and
// UltraVNC content far less than the high-resolution RDP/RustDesk paths.
// Apply one explicit VNC-only wire gain after source normalization so virtual
// touchpad, physical touchpad and physical mouse retain their own curves.
// 2026-10-07: 10 clicks per tick (30 per mouse notch with a 3-row scroll step) was far too fast on Windows and
// most servers; 3 is the default now and 设置 › 远程滚轮 › VNC 速度 (25%–400%) covers servers that scroll little.
export const VNC_WHEEL_OUTPUT_GAIN: number = 3;
export const VNC_WHEEL_OUTPUT_MAX_DELTA: number = 128;
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

/** Convert normalized VNC ticks into a bounded RFB button-4/5 burst. */
export function amplifyVncWheelOutputDelta(delta: number): number {
  if (!Number.isFinite(delta) || delta === 0) {
    return 0;
  }
  const whole: number = delta > 0 ? Math.floor(delta) : Math.ceil(delta);
  const amplified: number = whole * VNC_WHEEL_OUTPUT_GAIN;
  return Math.max(-VNC_WHEEL_OUTPUT_MAX_DELTA,
    Math.min(VNC_WHEEL_OUTPUT_MAX_DELTA, amplified));
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

export interface RemoteWheelSpeedScale {
  delta: number;
  remainder: number;
}

/** Most whole ticks one event may carry after the user's speed (a fast 400% flick is still bounded). */
export const REMOTE_WHEEL_SPEED_MAX_TICKS: number = 16;

/**
 * 设置 › 远程滚轮 › 速度: whole ticks after the protocol's own normalization, times the user's percentage. The fraction
 * carries to the next event (50% sends every other notch, 150% one and a half per notch on average); a change of
 * direction drops the stale fraction so a reversal never starts with a leftover tick the wrong way.
 */
export function scaleRemoteWheelTicks(delta: number, speedPercent: number, remainder: number): RemoteWheelSpeedScale {
  const carry: number = Number.isFinite(remainder) ? remainder : 0;
  if (!Number.isFinite(delta) || delta === 0) { return { delta: 0, remainder: carry }; }
  const percent: number = Number.isFinite(speedPercent) && speedPercent > 0 ? speedPercent : 100;
  const direction: number = delta > 0 ? 1 : -1;
  const kept: number = carry !== 0 && (carry > 0 ? 1 : -1) !== direction ? 0 : carry;
  const total: number = kept + delta * percent / 100;
  const whole: number = total > 0 ? Math.floor(total) : Math.ceil(total);
  const bounded: number = Math.max(-REMOTE_WHEEL_SPEED_MAX_TICKS, Math.min(REMOTE_WHEEL_SPEED_MAX_TICKS, whole));
  // Overflow beyond the bound is dropped rather than kept as a backlog that would scroll on after the hand stops.
  return { delta: bounded === 0 ? 0 : bounded, remainder: total - whole };
}

/** Moonlight's high-resolution wheel units (120 a notch) times the user's percentage; a motion never rounds to 0. */
export function scaleMoonlightWheelAmount(amount: number, speedPercent: number): number {
  if (!Number.isFinite(amount) || amount === 0) { return 0; }
  const percent: number = Number.isFinite(speedPercent) && speedPercent > 0 ? speedPercent : 100;
  let scaled: number = Math.round(amount * percent / 100);
  if (scaled === 0) { scaled = amount > 0 ? 1 : -1; }
  // The wire field is a signed 16-bit amount.
  return Math.max(-32768, Math.min(32767, scaled));
}

/** RDP carries one notch (120) per wheel event: n ticks are sent as n events, at most this many at once. */
export const RDP_WHEEL_MAX_EVENTS: number = 16;

export function rdpWheelEventCount(delta: number): number {
  if (!Number.isFinite(delta) || delta === 0) { return 0; }
  return Math.min(RDP_WHEEL_MAX_EVENTS, Math.abs(delta > 0 ? Math.floor(delta) : Math.ceil(delta)));
}

export function applyRemoteWheelDirection(delta: number, reverseWheel: boolean): number {
  return reverseWheel ? -delta : delta;
}
