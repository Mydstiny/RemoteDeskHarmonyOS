import { isRustDeskPhoneSessionForPeer } from './RemoteOrientationPolicy';

export type RustDeskDesktopFlipMode = 'reset' | 'image_only' | 'image_and_controls';

export interface RustDeskDesktopFlipRotations {
  visualQuarterTurns: number;
  inputQuarterTurns: number;
}

export interface RustDeskDesktopFlipPan {
  panX: number;
  panY: number;
}

/** Unknown or future persisted values must fail open to the unmodified view. */
export function normalizeRustDeskDesktopFlipMode(
  value: string | undefined
): RustDeskDesktopFlipMode {
  if (value === 'image_only' || value === 'image_and_controls') {
    return value;
  }
  return 'reset';
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

export function rustDeskDesktopFlipRotations(
  mode: RustDeskDesktopFlipMode
): RustDeskDesktopFlipRotations {
  if (mode === 'image_only') {
    return { visualQuarterTurns: 2, inputQuarterTurns: 0 };
  }
  if (mode === 'image_and_controls') {
    return { visualQuarterTurns: 2, inputQuarterTurns: 2 };
  }
  return { visualQuarterTurns: 0, inputQuarterTurns: 0 };
}

/** Preserve the same remote focus point when the visual layer turns 180°. */
export function reprojectRustDeskDesktopFlipPan(
  previousVisualQuarterTurns: number,
  nextVisualQuarterTurns: number,
  panX: number,
  panY: number
): RustDeskDesktopFlipPan {
  const previous: number = ((Math.round(previousVisualQuarterTurns) % 4) + 4) % 4;
  const next: number = ((Math.round(nextVisualQuarterTurns) % 4) + 4) % 4;
  if ((next - previous + 4) % 4 === 2) {
    return { panX: -panX, panY: -panY };
  }
  return { panX, panY };
}
