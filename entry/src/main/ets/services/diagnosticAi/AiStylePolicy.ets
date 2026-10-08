/**
 * AI 风格: the AI's look — Siri (dark smoky glass, the original) or 小艺 (a blue → lavender glass with the 小艺 halo
 * ring, after the HarmonyOS assistant's own voice screen). The shapes, sizes and interaction are the same in both; a
 * style only changes material, ink and motion.
 */
export const AI_STYLE: string = 'aiStyle';
export const AI_STYLE_SIRI: string = 'siri';
export const AI_STYLE_XIAOYI: string = 'xiaoyi';
/** The whole-window wash under an open 小艺 panel (on by default). */
export const AI_STYLE_WASH: string = 'aiStyle.wash';

/**
 * Ink roles. Siri keeps the exact colors the AI used before (so its look does not change at all); 小艺 replaces the
 * opaque greys, which turn muddy on a blue glass, with whites of the same weight.
 */
export type AiInkRole = 'text2' | 'text3' | 'text4' | 'icon' | 'textSoft' | 'surface' | 'surfaceDeep' |
  'surfaceRaised' | 'fillGray' | 'menu' | 'hint';

const SIRI_INK: Record<AiInkRole, string> = {
  'text2': '#8E8E93',
  'text3': '#AEAEB2',
  'text4': '#636366',
  'icon': '#C7C7CC',
  'textSoft': '#E5E5EA',
  'surface': '#2C2C2E',
  'surfaceDeep': '#1C1C1E',
  'surfaceRaised': '#3A3A3C',
  'fillGray': '#2E3A3A3C',
  'menu': '#F01C1C1F',
  'hint': '#E61C1C1E'
};

const XIAOYI_INK: Record<AiInkRole, string> = {
  'text2': '#C7FFFFFF',
  'text3': '#B3FFFFFF',
  'text4': '#99FFFFFF',
  'icon': '#E0FFFFFF',
  'textSoft': '#F2FFFFFF',
  'surface': '#2EFFFFFF',
  'surfaceDeep': '#24FFFFFF',
  'surfaceRaised': '#3DFFFFFF',
  'fillGray': '#33FFFFFF',
  // In-panel cards: translucent white, like the rest of the 小艺 glass (not a dark slab).
  'menu': '#38FFFFFF',
  'hint': '#E62B3A86'
};

export function aiStyleIsXiaoyi(style: string): boolean { return style === AI_STYLE_XIAOYI; }

export function aiInk(style: string, role: AiInkRole): string {
  return aiStyleIsXiaoyi(style) ? XIAOYI_INK[role] : SIRI_INK[role];
}

/** The 小艺 glass, light or dark: the diagonal gradient, and the dark cap over a camera cutout. */
export class AiGlassColors {
  from: string;
  to: string;
  cap: string;
  glow: string;
  rim: string;

  constructor(from: string, to: string, cap: string, glow: string, rim: string) {
    this.from = from;
    this.to = to;
    this.cap = cap;
    this.glow = glow;
    this.rim = rim;
  }
}

export function aiXiaoyiGlass(dark: boolean): AiGlassColors {
  return dark ? new AiGlassColors('#FF1D2E70', '#FF3D2C7A', '#FF05071A', '#404664FF', '#33FFFFFF') :
    new AiGlassColors('#FF4E8CE6', '#FF9A84EE', '#FF141A45', '#616EA5FF', '#52FFFFFF');
}

/** The whole-window wash: the same two colors, faint (22 % light, 32 % dark). */
export function aiXiaoyiWash(dark: boolean): string[] {
  return dark ? ['#521D2E70', '#523D2C7A'] : ['#384E8CE6', '#389A84EE'];
}

/** What choosing a style sets in AI 动效 (each can still be changed on its own afterwards). */
export class AiStylePreset {
  thinking: string;
  orb: string;
  done: string;

  constructor(thinking: string, orb: string, done: string) {
    this.thinking = thinking;
    this.orb = orb;
    this.done = done;
  }
}

export function aiStylePreset(style: string): AiStylePreset {
  return aiStyleIsXiaoyi(style) ? new AiStylePreset('xiaoyi', 'xiaoyiRing', 'xiaoyi') :
    new AiStylePreset('dots', 'voice', 'check');
}
