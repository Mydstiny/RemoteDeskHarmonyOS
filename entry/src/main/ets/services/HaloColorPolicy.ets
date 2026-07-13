export const HALO_COLOR_LEGACY_KEY: string = 'haloColor';
export const HALO_COLOR_LIGHT_KEY: string = 'haloColorLight';
export const HALO_COLOR_DARK_KEY: string = 'haloColorDark';
export const DEFAULT_LIGHT_HALO_COLOR: string = '#FFFFFF';
export const DEFAULT_DARK_HALO_COLOR: string = '#1A1A2E';

export const HALO_PRESETS_LIGHT: string[] = [
  '#FFFFFF','#F0F0F0','#F0F5FA','#FFF8F0','#F5F0F8',
  '#FF99BB','#FFB366','#99DDAA','#66CCDD','#D4A0E0',
  '#A0D4C8','#F0C8A0','#C8C0E0','#A0C8E8','#E0C0C0',
  '#C8D8C0','#9CAF88','#C4A4A4','#A8C8E8','#B0D8C8'
];

export const HALO_PRESETS_DARK: string[] = [
  '#1A1A2E','#16213E','#0F3460','#2C003E','#1B0030',
  '#1A0A2E','#002233','#1B1B2F','#2D1B4E','#0D1B2A',
  '#1B2838','#2C1333','#0F1B2D','#1E0A2E','#0A1628',
  '#1E2A38','#231B2E','#162032','#1C0F2E','#0F1E33'
];

export function normalizeHaloTheme(theme: string): string {
  return theme === 'dark' ? 'dark' : 'light';
}

export function haloColorPreferenceKey(theme: string): string {
  return normalizeHaloTheme(theme) === 'dark' ? HALO_COLOR_DARK_KEY : HALO_COLOR_LIGHT_KEY;
}

export function defaultHaloColorForTheme(theme: string): string {
  return normalizeHaloTheme(theme) === 'dark' ? DEFAULT_DARK_HALO_COLOR : DEFAULT_LIGHT_HALO_COLOR;
}

export function haloPresetsForTheme(theme: string): string[] {
  return normalizeHaloTheme(theme) === 'dark' ? HALO_PRESETS_DARK : HALO_PRESETS_LIGHT;
}

export function haloColorBelongsToTheme(theme: string, color: string): boolean {
  if (color.length === 0) {
    return false;
  }
  return haloPresetsForTheme(theme).indexOf(color) >= 0;
}

export function shouldMigrateLegacyHaloColorToTheme(theme: string, themeColor: string, legacyColor: string): boolean {
  return themeColor.length === 0 && haloColorBelongsToTheme(theme, legacyColor);
}

export function resolveStoredHaloColorForTheme(
  theme: string,
  lightColor: string,
  darkColor: string,
  legacyColor: string
): string {
  const normalizedTheme: string = normalizeHaloTheme(theme);
  const themeColor: string = normalizedTheme === 'dark' ? darkColor : lightColor;
  if (themeColor.length > 0) {
    return themeColor;
  }
  if (haloColorBelongsToTheme(normalizedTheme, legacyColor)) {
    return legacyColor;
  }
  return defaultHaloColorForTheme(normalizedTheme);
}
