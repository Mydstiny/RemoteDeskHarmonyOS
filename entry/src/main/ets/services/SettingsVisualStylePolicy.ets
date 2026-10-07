/**
 * 设置 → 个性化 → 全新视觉. On by default (2026-10-07): only a stored 'classic' (the user turned it off) keeps the
 * classic look, which stays exactly as it was; anything else (missing, a bad cloud value) is the new look.
 */
export const SETTINGS_VISUAL_STYLE_KEY: string = 'settingsVisualStyle';
export const SETTINGS_VISUAL_STYLE_CLASSIC: string = 'classic';
export const SETTINGS_VISUAL_STYLE_MODERN: string = 'modern';

export function normalizeSettingsVisualStyle(value: string): string {
  return value === SETTINGS_VISUAL_STYLE_CLASSIC ? SETTINGS_VISUAL_STYLE_CLASSIC : SETTINGS_VISUAL_STYLE_MODERN;
}

export function settingsVisualIsModern(value: string): boolean {
  return value !== SETTINGS_VISUAL_STYLE_CLASSIC;
}
