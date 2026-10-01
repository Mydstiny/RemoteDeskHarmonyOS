/** Pure color and motion math for the Pro badge (kept apart from ArkUI for tests and previews). */
// A badge shows half a cycle across its width; the phase moves it.
const FLOW_CYCLE: string[] = ['#B9F3EA', '#CDC9FF', '#F4C8E5', '#F9E3B8'];
const FLOW_SPAN: number = 0.5;

export const PRO_BADGE_DEFAULT_PRIMARY: string = '#B9F3EA';
export const PRO_BADGE_DEFAULT_SECONDARY: string = '#CDC9FF';
export const PRO_BADGE_MAX_COLORS: number = 4;

/** A named set of colors the badge cycles through. */
export interface ProBadgePalette { id: string; label: string; colors: string[]; }

export const PRO_BADGE_PALETTES: ProBadgePalette[] = [
  { id: 'aurora', label: '极光', colors: ['#B9F3EA', '#CDC9FF', '#F4C8E5', '#F9E3B8'] },
  { id: 'sunset', label: '落日', colors: ['#FFB38A', '#FF7A9C', '#C58BFF', '#FFD58A'] },
  { id: 'glacier', label: '冰川', colors: ['#A8E6FF', '#7FB8FF', '#C9D8FF', '#E6FBFF'] },
  { id: 'neon', label: '霓虹', colors: ['#00F5D4', '#7B61FF', '#FF4FD8', '#00BBF9'] },
  { id: 'gold', label: '曜金', colors: ['#F7E7B4', '#D9B25F', '#FFF1C9', '#B8893A'] },
  { id: 'sakura', label: '樱粉', colors: ['#FFD1E3', '#FFB3C7', '#F6E1FF', '#FFE7D6'] },
  { id: 'forest', label: '森野', colors: ['#B7F7C1', '#5FD4A0', '#D8F5A2', '#7CC6B4'] },
  { id: 'crimson', label: '赤焰', colors: ['#FF5A5F', '#FF9F43', '#E8173C', '#FFC2A8'] }
];

export function validBadgeHex(value: string): boolean { return /^#[0-9A-Fa-f]{6}$/.test(value); }

/** Keeps 2–4 valid #RRGGBB colors; anything else falls back to the default aurora set. */
export function cleanBadgeColors(colors: string[]): string[] {
  const result: string[] = [];
  if (Array.isArray(colors)) {
    colors.forEach((color: string): void => {
      if (typeof color === 'string' && validBadgeHex(color) && result.length < PRO_BADGE_MAX_COLORS) {
        result.push(color.toUpperCase());
      }
    });
  }
  return result.length >= 2 ? result : FLOW_CYCLE.slice();
}

export function badgePalette(id: string): ProBadgePalette | null {
  const found: ProBadgePalette | undefined = PRO_BADGE_PALETTES.find((item: ProBadgePalette): boolean => item.id === id);
  return found === undefined ? null : found;
}

function hexChannel(hex: string, index: number): number { return parseInt(hex.substring(1 + index * 2, 3 + index * 2), 16); }

export function mixHex(from: string, to: string, amount: number): string {
  let result: string = '#';
  for (let index: number = 0; index < 3; index++) {
    const value: number = Math.round(hexChannel(from, index) + (hexChannel(to, index) - hexChannel(from, index)) * amount);
    const text: string = Math.max(0, Math.min(255, value)).toString(16).toUpperCase();
    result += text.length < 2 ? '0' + text : text;
  }
  return result;
}

/** ArkUI colors are #AARRGGBB: puts the alpha in front instead of appending it. */
export function withAlpha(hex: string, alpha: string): string {
  return validBadgeHex(hex) && /^[0-9A-Fa-f]{2}$/.test(alpha) ? '#' + alpha.toUpperCase() + hex.substring(1).toUpperCase() : hex;
}

/** Relative luminance (0–1) of a #RRGGBB color. */
export function badgeLuminance(hex: string): number {
  if (!validBadgeHex(hex)) { return 1; }
  const linear = (value: number): number => {
    const c: number = value / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linear(hexChannel(hex, 0)) + 0.7152 * linear(hexChannel(hex, 1)) + 0.0722 * linear(hexChannel(hex, 2));
}

/** Dark ink on light fills, white on dark fills, judged by the average luminance of the colors. */
export function badgeInkFor(colors: string[]): string {
  const list: string[] = cleanBadgeColors(colors);
  let total: number = 0;
  list.forEach((color: string): void => { total += badgeLuminance(color); });
  return total / list.length >= 0.32 ? '#29223F' : '#FFFFFF';
}

/** Color at a position (any real number; one unit = one full cycle) of a looping color list. */
export function cycleColor(position: number, cycle: string[] = FLOW_CYCLE): string {
  const u: number = ((position % 1) + 1) % 1 * cycle.length;
  const index: number = Math.floor(u);
  return mixHex(cycle[index % cycle.length], cycle[(index + 1) % cycle.length], u - index);
}

/**
 * Gradient stops for one frame: the cycle position at each edge plus every cycle color that
 * falls inside, so consecutive phases differ only slightly and the loop has no seam.
 */
export function proBadgeCycleStops(phase: number, colors: string[]): Array<[ResourceColor, number]> {
  const cycle: string[] = cleanBadgeColors(colors);
  const stops: Array<[ResourceColor, number]> = [[cycleColor(phase, cycle), 0]];
  const start: number = phase * cycle.length;
  const end: number = (phase + FLOW_SPAN) * cycle.length;
  for (let k: number = Math.floor(start) + 1; k < end; k++) {
    const x: number = (k - start) / (end - start);
    if (x > 0 && x < 1) { stops.push([cycle[k % cycle.length], x]); }
  }
  stops.push([cycleColor(phase + FLOW_SPAN, cycle), 1]);
  return stops;
}

/** Two-color entry point kept for older callers; the default pair uses the four-color aurora cycle. */
export function proBadgeFlowStops(phase: number, primary: string = PRO_BADGE_DEFAULT_PRIMARY,
  secondary: string = PRO_BADGE_DEFAULT_SECONDARY): Array<[ResourceColor, number]> {
  const cycle: string[] = primary === PRO_BADGE_DEFAULT_PRIMARY && secondary === PRO_BADGE_DEFAULT_SECONDARY
    ? FLOW_CYCLE : [primary, secondary, mixHex(secondary, primary, 0.45), mixHex(primary, secondary, 0.45)];
  return proBadgeCycleStops(phase, cycle);
}

/** A calm, fixed gradient across the colors. */
export function proBadgeStaticStops(colors: string[]): Array<[ResourceColor, number]> {
  const list: string[] = cleanBadgeColors(colors);
  return list.map((color: string, index: number): [ResourceColor, number] => [color, index / (list.length - 1)]);
}

/** Eased 0→1→0 breathing curve (cosine), so the pulse never snaps at the loop seam. */
export function proBadgePulse(phase: number): number {
  return 0.5 - 0.5 * Math.cos(((phase % 1) + 1) % 1 * Math.PI * 2);
}

function easeInOut(t: number): number { return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2; }

/**
 * Shimmer: a soft white band crosses the badge during the first 45% of the cycle with ease-in-out, then rests,
 * which reads as a deliberate glint rather than a constant scroll.
 */
export function proBadgeShimmerStops(phase: number, colors: string[]): Array<[ResourceColor, number]> {
  const list: string[] = cleanBadgeColors(colors);
  const base: Array<[ResourceColor, number]> = proBadgeStaticStops(list);
  const p: number = ((phase % 1) + 1) % 1;
  if (p >= 0.45) { return base; }
  const center: number = -0.25 + easeInOut(p / 0.45) * 1.5;
  const half: number = 0.14;
  const result: Array<[ResourceColor, number]> = [];
  const add = (color: string, x: number): void => {
    if (x >= 0 && x <= 1) { result.push([color, x]); }
  };
  add(list[0], 0);
  add(withAlpha(cycleColor(center - half, list), 'FF'), center - half);
  add('#FFFFFFFF', center);
  add(withAlpha(cycleColor(center + half, list), 'FF'), center + half);
  add(list[list.length - 1], 1);
  if (result.length < 2) { return base; }
  if ((result[0][1] as number) > 0) { result.unshift([list[0], 0]); }
  if ((result[result.length - 1][1] as number) < 1) { result.push([list[list.length - 1], 1]); }
  return result;
}

/** One ray of the 星爆 pattern inside the badge, in units of the badge's half-diagonal from its center. */
export interface ProBadgeWarpRay {
  /** Direction in degrees (0 = right, 90 = down). */
  angle: number;
  /** Distance from the center to the middle of the ray. */
  radius: number;
  /** Ray length. */
  length: number;
  opacity: number;
  /** Ray thickness factor (0.6–1.2) so the burst has depth. */
  weight: number;
}

/** Fixed, irregular layout of the rays so the burst looks like the badge plate rather than a clock face. */
const WARP_RAY_COUNT: number = 40;

function rayJitter(index: number, salt: number): number {
  const x: number = Math.sin(index * 12.9898 + salt * 78.233) * 43758.5453;
  return x - Math.floor(x);
}

/**
 * 星爆: rays radiate from the badge center like a jump to light speed. With `animated` each ray flies outward, grows
 * and fades on its own staggered cycle; without it the rays sit at a fixed spread (the static plate). Always returns
 * the same number of rays so the layout never reshuffles; the loop seam is invisible because a ray's opacity is 0
 * at both ends of its cycle.
 */
export function proBadgeWarpRays(phase: number, animated: boolean): ProBadgeWarpRay[] {
  const result: ProBadgeWarpRay[] = [];
  for (let index: number = 0; index < WARP_RAY_COUNT; index++) {
    const angle: number = index * 360 / WARP_RAY_COUNT + (rayJitter(index, 1) - 0.5) * 9;
    const offset: number = rayJitter(index, 2);
    const weight: number = 0.6 + rayJitter(index, 3) * 0.6;
    if (!animated) {
      const reach: number = 0.35 + offset * 0.55;
      result.push({ angle, radius: reach, length: 0.25 + offset * 0.45, opacity: 0.35 + weight * 0.45, weight });
      continue;
    }
    const speed: number = 1 + Math.floor(rayJitter(index, 4) * 2);
    const t: number = (((phase * speed + offset) % 1) + 1) % 1;
    const eased: number = t * (0.6 + 0.4 * t);
    result.push({
      angle,
      radius: 0.1 + eased * 1.0,
      length: 0.16 + eased * 0.5,
      opacity: Math.min(1, Math.pow(Math.sin(t * Math.PI), 0.6) * (0.6 + weight * 0.33)),
      weight
    });
  }
  return result;
}
