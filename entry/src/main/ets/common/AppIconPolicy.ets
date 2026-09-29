export const APP_ICON_MIN_API: number = 26;
export interface AppIconState { name: string; enabled: boolean; }
export interface AppIconProvider {
  supported(): boolean;
  query(): Promise<AppIconState[]>;
  apply(name: string): Promise<void>;
}
export interface AppIconPreset { name: string; label: string; }
// Picker order. '' restores the default icon; other names must match app.json5 alternateIcons.
export const APP_ICON_PRESETS: AppIconPreset[] = [
  { name: '', label: '默认' },
  { name: 'rd_white', label: '白底版' },
  { name: 'rd_transparent', label: '透明底版' },
  { name: 'rd_night', label: '深空' },
  { name: 'rd_sky', label: '晴空' },
  { name: 'rd_aurora', label: '幻彩' },
  { name: 'rd_vivid', label: '炫蓝' },
  { name: 'rd_soft', label: '柔蓝' },
  { name: 'rd_vivid_night', label: '夜色' },
  { name: 'rd_vivid_ocean', label: '海蓝' },
  { name: 'rd_vivid_aurora', label: '霓彩' }
];
export function knownAppIcon(name: string): boolean {
  return APP_ICON_PRESETS.some((preset: AppIconPreset): boolean => preset.name === name);
}
export function appIconLabel(name: string): string {
  const preset = APP_ICON_PRESETS.find((item: AppIconPreset): boolean => item.name === name);
  return preset === undefined ? '其他预设' : preset.label;
}
