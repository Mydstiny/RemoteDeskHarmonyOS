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
  targetDevice: string
): RustDeskDesktopFlipMode {
  if (protocol !== 'rustdesk' || !isDesktopDevice || targetDevice === 'phone') {
    return 'reset';
  }
  return normalizeRustDeskDesktopFlipMode(value);
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
