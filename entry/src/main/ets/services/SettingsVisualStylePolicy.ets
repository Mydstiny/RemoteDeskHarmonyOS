/**
 * 设置 → 个性化 → 全新视觉. The new settings look is opt-in and off by default; any stored value other than
 * 'modern' (missing, old builds, a bad cloud value) is the classic look, which stays exactly as it was.
 */
export const SETTINGS_VISUAL_STYLE_KEY: string = 'settingsVisualStyle';
export const SETTINGS_VISUAL_STYLE_CLASSIC: string = 'classic';
export const SETTINGS_VISUAL_STYLE_MODERN: string = 'modern';

export function normalizeSettingsVisualStyle(value: string): string {
  return value === SETTINGS_VISUAL_STYLE_MODERN ? SETTINGS_VISUAL_STYLE_MODERN : SETTINGS_VISUAL_STYLE_CLASSIC;
}

export function settingsVisualIsModern(value: string): boolean {
  return value === SETTINGS_VISUAL_STYLE_MODERN;
}
