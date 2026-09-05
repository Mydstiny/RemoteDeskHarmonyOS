/** Device-local Moonlight PC fallback. Each visual and input axis is independent. */
export type MoonlightDesktopFlipMode = string;
export type MoonlightDesktopFlipAxis =
  'visual_y' | 'visual_x' | 'control_y' | 'control_x';

export interface MoonlightDesktopFlipState {
  visualFlipY: boolean;
  visualFlipX: boolean;
  controlFlipY: boolean;
  controlFlipX: boolean;
}

export interface MoonlightDesktopFlipPan {
  panX: number;
  panY: number;
}

export interface MoonlightDesktopFlipPoint {
  x: number;
  y: number;
}

export interface MoonlightDesktopRelativeInput {
  wireX: number;
  wireY: number;
  visualX: number;
  visualY: number;
}

const VISUAL_FLIP_Y: number = 1;
const VISUAL_FLIP_X: number = 2;
const CONTROL_FLIP_Y: number = 4;
const CONTROL_FLIP_X: number = 8;
const ALL_FLIP_FLAGS: number = 15;

function stateFromMask(mask: number): MoonlightDesktopFlipState {
  return {
    visualFlipY: (mask & VISUAL_FLIP_Y) !== 0,
    visualFlipX: (mask & VISUAL_FLIP_X) !== 0,
    controlFlipY: (mask & CONTROL_FLIP_Y) !== 0,
    controlFlipX: (mask & CONTROL_FLIP_X) !== 0
  };
}

function modeFromState(state: MoonlightDesktopFlipState): MoonlightDesktopFlipMode {
  let mask: number = 0;
  if (state.visualFlipY) { mask |= VISUAL_FLIP_Y; }
  if (state.visualFlipX) { mask |= VISUAL_FLIP_X; }
  if (state.controlFlipY) { mask |= CONTROL_FLIP_Y; }
  if (state.controlFlipX) { mask |= CONTROL_FLIP_X; }
  return mask === 0 ? 'reset' : 'axes_' + mask.toString();
}

export function normalizeMoonlightDesktopFlipMode(
  value: Object | null | undefined
): MoonlightDesktopFlipMode {
  if (typeof value !== 'string' || value === 'reset') { return 'reset'; }
  if (!value.startsWith('axes_')) { return 'reset'; }
  const mask: number = Number(value.substring(5));
  return Number.isInteger(mask) && mask >= 0 && mask <= ALL_FLIP_FLAGS ?
    (mask === 0 ? 'reset' : 'axes_' + mask.toString()) : 'reset';
}

export function moonlightDesktopFlipState(
  value: string | undefined
): MoonlightDesktopFlipState {
  const mode: MoonlightDesktopFlipMode = normalizeMoonlightDesktopFlipMode(value);
  return stateFromMask(mode === 'reset' ? 0 : Number(mode.substring(5)));
}

export function toggleMoonlightDesktopFlipAxis(
  value: string | undefined,
  axis: MoonlightDesktopFlipAxis
): MoonlightDesktopFlipMode {
  const state: MoonlightDesktopFlipState = moonlightDesktopFlipState(value);
  if (axis === 'visual_y') { state.visualFlipY = !state.visualFlipY; }
  else if (axis === 'visual_x') { state.visualFlipX = !state.visualFlipX; }
  else if (axis === 'control_y') { state.controlFlipY = !state.controlFlipY; }
  else { state.controlFlipX = !state.controlFlipX; }
  return modeFromState(state);
}

export function effectiveMoonlightDesktopFlipMode(
  value: string | undefined,
  isDesktopDevice: boolean,
  sessionWindowId: string
): MoonlightDesktopFlipMode {
  return isDesktopDevice || sessionWindowId.trim().length > 0 ?
    normalizeMoonlightDesktopFlipMode(value) : 'reset';
}

export function reprojectMoonlightDesktopFlipPan(
  previousMode: string | undefined,
  nextMode: string | undefined,
  panX: number,
  panY: number
): MoonlightDesktopFlipPan {
  const previous: MoonlightDesktopFlipState = moonlightDesktopFlipState(previousMode);
  const next: MoonlightDesktopFlipState = moonlightDesktopFlipState(nextMode);
  return {
    panX: previous.visualFlipX === next.visualFlipX ? panX : -panX,
    panY: previous.visualFlipY === next.visualFlipY ? panY : -panY
  };
}

export function mirrorMoonlightDesktopInput(
  x: number,
  y: number,
  left: number,
  top: number,
  width: number,
  height: number,
  flipX: boolean,
  flipY: boolean
): MoonlightDesktopFlipPoint {
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(left) ||
    !Number.isFinite(top) || !Number.isFinite(width) || !Number.isFinite(height) ||
    width <= 0 || height <= 0) { return { x: x, y: y }; }
  return {
    x: flipX ? left + width - (x - left) : x,
    y: flipY ? top + height - (y - top) : y
  };
}

export function projectMoonlightDesktopRelativeInput(
  deltaX: number,
  deltaY: number,
  gain: number,
  controlFlipX: boolean,
  controlFlipY: boolean,
  visualFlipX: boolean,
  visualFlipY: boolean
): MoonlightDesktopRelativeInput {
  const wireX: number = deltaX * gain * (controlFlipX ? -1 : 1);
  const wireY: number = deltaY * gain * (controlFlipY ? -1 : 1);
  return {
    wireX: wireX,
    wireY: wireY,
    visualX: wireX * (visualFlipX ? -1 : 1),
    visualY: wireY * (visualFlipY ? -1 : 1)
  };
}
