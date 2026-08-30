import { isRustDeskPhoneSessionForPeer } from './RemoteOrientationPolicy';

/**
 * Persisted device-local value. Canonical values are `axes_<mask>` where:
 * bit 0 = visual Y, bit 1 = visual X, bit 2 = control Y, bit 3 = control X.
 * `reset` remains the zero value so older backups and cloud projections keep
 * their fail-open contract.
 */
export type RustDeskDesktopFlipMode = string;
export type RustDeskDesktopFlipAxis =
  'visual_y' | 'visual_x' | 'control_y' | 'control_x';

export interface RustDeskDesktopFlipState {
  visualFlipY: boolean;
  visualFlipX: boolean;
  controlFlipY: boolean;
  controlFlipX: boolean;
}

export interface RustDeskDesktopFlipPan {
  panX: number;
  panY: number;
}

const VISUAL_FLIP_Y: number = 1;
const VISUAL_FLIP_X: number = 2;
const CONTROL_FLIP_Y: number = 4;
const CONTROL_FLIP_X: number = 8;
const ALL_FLIP_FLAGS: number = 15;

function stateFromMask(mask: number): RustDeskDesktopFlipState {
  return {
    visualFlipY: (mask & VISUAL_FLIP_Y) !== 0,
    visualFlipX: (mask & VISUAL_FLIP_X) !== 0,
    controlFlipY: (mask & CONTROL_FLIP_Y) !== 0,
    controlFlipX: (mask & CONTROL_FLIP_X) !== 0
  };
}

function maskFromState(state: RustDeskDesktopFlipState): number {
  let mask: number = 0;
  if (state.visualFlipY) { mask |= VISUAL_FLIP_Y; }
  if (state.visualFlipX) { mask |= VISUAL_FLIP_X; }
  if (state.controlFlipY) { mask |= CONTROL_FLIP_Y; }
  if (state.controlFlipX) { mask |= CONTROL_FLIP_X; }
  return mask;
}

function modeFromMask(mask: number): RustDeskDesktopFlipMode {
  const bounded: number = Math.max(0, Math.min(ALL_FLIP_FLAGS, Math.round(mask)));
  return bounded === 0 ? 'reset' : 'axes_' + bounded.toString();
}

/**
 * Normalize current values and migrate the released three-state workaround.
 * The old 180-degree modes meant both visual axes, optionally both controls.
 */
export function normalizeRustDeskDesktopFlipMode(
  value: Object | null | undefined
): RustDeskDesktopFlipMode {
  if (typeof value !== 'string') {
    return 'reset';
  }
  if (value === 'image_only') {
    return modeFromMask(VISUAL_FLIP_Y | VISUAL_FLIP_X);
  }
  if (value === 'image_and_controls') {
    return modeFromMask(ALL_FLIP_FLAGS);
  }
  if (value === 'reset') {
    return 'reset';
  }
  if (value.startsWith('axes_')) {
    const mask: number = Number(value.substring(5));
    if (Number.isInteger(mask) && mask >= 0 && mask <= ALL_FLIP_FLAGS) {
      return modeFromMask(mask);
    }
  }
  return 'reset';
}

export function rustDeskDesktopFlipState(
  value: string | undefined
): RustDeskDesktopFlipState {
  const mode: RustDeskDesktopFlipMode = normalizeRustDeskDesktopFlipMode(value);
  if (mode === 'reset') {
    return stateFromMask(0);
  }
  return stateFromMask(Number(mode.substring(5)));
}

export function toggleRustDeskDesktopFlipAxis(
  value: string | undefined,
  axis: RustDeskDesktopFlipAxis
): RustDeskDesktopFlipMode {
  const state: RustDeskDesktopFlipState = rustDeskDesktopFlipState(value);
  if (axis === 'visual_y') { state.visualFlipY = !state.visualFlipY; }
  else if (axis === 'visual_x') { state.visualFlipX = !state.visualFlipX; }
  else if (axis === 'control_y') { state.controlFlipY = !state.controlFlipY; }
  else { state.controlFlipX = !state.controlFlipX; }
  return modeFromMask(maskFromState(state));
}

/**
 * The workaround is deliberately scoped to desktop RustDesk computer peers.
 * Phone targets retain their existing quarter-turn control and Phone/Pad
 * viewers never inherit this host-local desktop override.
 */
export function effectiveRustDeskDesktopFlipMode(
  value: string | undefined,
  protocol: string,
  isDesktopDevice: boolean,
  targetDevice: string,
  peerPlatform: string = 'unknown'
): RustDeskDesktopFlipMode {
  if (protocol !== 'rustdesk' || !isDesktopDevice ||
    isRustDeskPhoneSessionForPeer(targetDevice, peerPlatform)) {
    return 'reset';
  }
  return normalizeRustDeskDesktopFlipMode(value);
}

/** Continuity reconnects transiently publish Unknown before re-authentication. */
export function stableRustDeskDesktopFlipPeerPlatform(
  previousPlatform: string,
  observedPlatform: string
): string {
  const previous: string = previousPlatform.trim().toLowerCase();
  const observed: string = observedPlatform.trim().toLowerCase();
  const previousAuthenticated: boolean = previous === 'android' || previous === 'ios' ||
    previous === 'windows' || previous === 'macos' || previous === 'linux';
  if ((observed === '' || observed === 'unknown') && previousAuthenticated) {
    return previous;
  }
  return observed === '' ? 'unknown' : observed;
}

/** Preserve the same remote focus point when one visual mirror axis changes. */
export function reprojectRustDeskDesktopFlipPan(
  previousMode: string | undefined,
  nextMode: string | undefined,
  panX: number,
  panY: number
): RustDeskDesktopFlipPan {
  const previous: RustDeskDesktopFlipState = rustDeskDesktopFlipState(previousMode);
  const next: RustDeskDesktopFlipState = rustDeskDesktopFlipState(nextMode);
  return {
    panX: previous.visualFlipX === next.visualFlipX ? panX : -panX,
    panY: previous.visualFlipY === next.visualFlipY ? panY : -panY
  };
}
