/**
 * Theme.ets v5 — 全局主题色系统 + HarmonyOS Sans 粗体 + Pantone 色系预设
 */
import {
  HALO_COLOR_DARK_KEY,
  HALO_COLOR_LEGACY_KEY,
  HALO_COLOR_LIGHT_KEY,
  resolveStoredHaloColorForTheme
} from '../services/HaloColorPolicy';

// ==================== 主题色预设 ====================
export interface ColorPreset {
  name: string;
  hex: string;
  pantone: string;
}
export const COLOR_PRESETS: ColorPreset[] = [
  // ===== 原始饱和色系 (12色) =====
  { name: 'HarmonyOS Blue', hex: '#007DFF', pantone: 'PMS 285 C' },
  { name: 'Scarlet', hex: '#FF3B30', pantone: 'PMS 185 C' },
  { name: 'Emerald', hex: '#34C759', pantone: 'PMS 354 C' },
  { name: 'Amethyst', hex: '#AF52DE', pantone: 'PMS 265 C' },
  { name: 'Tangerine', hex: '#FF9500', pantone: 'PMS 144 C' },
  { name: 'Midnight', hex: '#1C1C3A', pantone: 'PMS 276 C' },
  { name: 'Teal', hex: '#5AC8FA', pantone: 'PMS 298 C' },
  { name: 'Rose Gold', hex: '#E8A5B0', pantone: 'PMS 495 C' },
  { name: 'Graphite', hex: '#6E6E73', pantone: 'PMS 424 C' },
  { name: 'Sunflower', hex: '#FFD60A', pantone: 'PMS 012 C' },
  { name: 'Coral', hex: '#FF6B6B', pantone: 'PMS 178 C' },
  { name: 'Mint', hex: '#00C7BE', pantone: 'PMS 326 C' },
  // ===== 原始低饱和度色系 (8色) =====
  { name: 'Sage Green', hex: '#9CAF88', pantone: 'PMS 577 C' },
  { name: 'Dusty Rose', hex: '#C4A4A4', pantone: 'PMS 5005 C' },
  { name: 'Sky Blue', hex: '#A8C8E8', pantone: 'PMS 543 C' },
  { name: 'Lavender', hex: '#B8B0D0', pantone: 'PMS 528 C' },
  { name: 'Warm Sand', hex: '#D4C5B9', pantone: 'PMS 4745 C' },
  { name: 'Soft Peach', hex: '#F0D0C0', pantone: 'PMS 489 C' },
  { name: 'Pale Lilac', hex: '#D8C8E8', pantone: 'PMS 2635 C' },
  { name: 'Sea Foam', hex: '#B0D8C8', pantone: 'PMS 564 C' },
  // ===== 白色 + 浅色系 =====
  { name: 'Pure White', hex: '#FFFFFF', pantone: 'White' },
  { name: 'Soft Gray', hex: '#F0F0F0', pantone: 'PMS Cool Gray 1' },
  { name: 'Warm White', hex: '#FAFAF5', pantone: 'Warm White' },
  { name: 'Cream', hex: '#FFF8F0', pantone: 'Cream' },
  { name: 'Ice Blue', hex: '#F0F5FA', pantone: 'Ice Blue' },
  { name: 'Lavender Mist', hex: '#F5F0F8', pantone: 'Lavender Mist' },
  { name: 'Mint White', hex: '#F0F8F5', pantone: 'Mint White' },
  { name: 'Peach Cream', hex: '#FFF5F0', pantone: 'Peach Cream' },
  // ===== 降饱和度版本 (12+8 色, ~50% 降饱和) =====
  { name: 'Blue (Muted)', hex: '#6699CC', pantone: 'PMS 285 C 50%' },
  { name: 'Scarlet (Muted)', hex: '#CC7A75', pantone: 'PMS 185 C 50%' },
  { name: 'Emerald (Muted)', hex: '#7AAA80', pantone: 'PMS 354 C 50%' },
  { name: 'Amethyst (Muted)', hex: '#9E82BE', pantone: 'PMS 265 C 50%' },
  { name: 'Tangerine (Muted)', hex: '#CC994D', pantone: 'PMS 144 C 50%' },
  { name: 'Midnight (Muted)', hex: '#4A4A5E', pantone: 'PMS 276 C 50%' },
  { name: 'Teal (Muted)', hex: '#8EC4E6', pantone: 'PMS 298 C 50%' },
  { name: 'Rose Gold (Muted)', hex: '#CFB6BC', pantone: 'PMS 495 C 50%' },
  { name: 'Graphite (Muted)', hex: '#96969A', pantone: 'PMS 424 C 50%' },
  { name: 'Sunflower (Muted)', hex: '#CCC05E', pantone: 'PMS 012 C 50%' },
  { name: 'Coral (Muted)', hex: '#CC8E8E', pantone: 'PMS 178 C 50%' },
  { name: 'Mint (Muted)', hex: '#5EADA8', pantone: 'PMS 326 C 50%' },
  { name: 'Sage (Muted)', hex: '#AAB59E', pantone: 'PMS 577 C 50%' },
  { name: 'Dusty (Muted)', hex: '#BFB0B0', pantone: 'PMS 5005 C 50%' },
  { name: 'Sky (Muted)', hex: '#B0C2D6', pantone: 'PMS 543 C 50%' },
  { name: 'Lavender (Muted)', hex: '#BAB4C6', pantone: 'PMS 528 C 50%' },
  { name: 'Sand (Muted)', hex: '#C8C0BA', pantone: 'PMS 4745 C 50%' },
  { name: 'Peach (Muted)', hex: '#D8C8C0', pantone: 'PMS 489 C 50%' },
  { name: 'Lilac (Muted)', hex: '#CFC9D8', pantone: 'PMS 2635 C 50%' },
  { name: 'Foam (Muted)', hex: '#B4CDC4', pantone: 'PMS 564 C 50%' },
];

// ==================== Palette 接口 ====================
export interface Palette {
  bg: string; card: string; sheetBg: string; cardBorder: string; surface: string; divider: string;
  text: string; text2: string; text3: string;
  searchBg: string; searchBorder: string;
  floatBg: string; floatBorder: string;
  primary: string; success: string; danger: string; editColor: string;
  fabGlow: string; fabShadow: string;
  tabGradientMask: string; tabGradientMaskDark: string;
  tabLightColor: string;
  lockOverlay: string; lockCardBg: string;
  terminalBg: string; terminalBar: string; terminalGreen: string; terminalFg: string;
}

// ==================== 壁纸亮度检测 ====================
/** 计算 hex 颜色的相对亮度 (0~255) */
export function colorLuminance(hex: string): number {
  const r: number = parseInt(hex.substring(1, 3), 16);
  const g: number = parseInt(hex.substring(3, 5), 16);
  const b: number = parseInt(hex.substring(5, 7), 16);
  return 0.299 * r + 0.587 * g + 0.114 * b;
}
/** 壁纸是否为深色 (亮度 < 128) */
export function isWallpaperDark(): boolean {
  const c: string = AppStorage.get<string>('wallpaperColor') ?? '#1A1A2E';
  return colorLuminance(c) < 128;
}

// ==================== 获取当前主题色 ====================
export function getAccentColor(): string {
  return AppStorage.get<string>('accentColor') ?? '#007DFF';
}
export function getTerminalFgColor(): string {
  return AppStorage.get<string>('terminalFgColor') ?? '#33FF33';
}
export function getTerminalFontSize(): number {
  return AppStorage.get<number>('terminalFontSize') ?? 14;
}
export function getAccentAlpha(alpha: number): string {
  const hex: string = getAccentColor();
  const r: number = parseInt(hex.substring(1, 3), 16);
  const g: number = parseInt(hex.substring(3, 5), 16);
  const b: number = parseInt(hex.substring(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

export function getHaloColorForTheme(theme: string): string {
  const lightHalo: string = AppStorage.get<string>(HALO_COLOR_LIGHT_KEY) ?? '';
  const darkHalo: string = AppStorage.get<string>(HALO_COLOR_DARK_KEY) ?? '';
  const legacyHalo: string = AppStorage.get<string>(HALO_COLOR_LEGACY_KEY) ?? '';
  return resolveStoredHaloColorForTheme(theme, lightHalo, darkHalo, legacyHalo);
}

// ==================== 深色/浅色调色板 ====================
export function buildDark(accent: string): Palette {
  const halo: string = getHaloColorForTheme('dark');
  return {
    bg:'#000000', card:'rgba(255,255,255,0.08)', sheetBg:'#1C1C1F', cardBorder:'rgba(255,255,255,0.10)',
    surface:'rgba(255,255,255,0.12)', divider:'rgba(255,255,255,0.10)',
    // text_primary: #E6E6E6 非纯白, 避免 21:1 极端对比度 (深色背景上 ≈ 16:1 舒适)
    text:'#E6E6E6', text2:'rgba(230,230,230,0.75)', text3:'rgba(230,230,230,0.50)',
    // searchBg 提亮至 0.10 保证可交互控件 ≥ 2.2:1 对比度
    searchBg:'rgba(255,255,255,0.10)', searchBorder:'rgba(255,255,255,0.14)',
    floatBg:'rgba(10,10,14,0.94)', floatBorder:'rgba(255,255,255,0.12)',
    // danger 提亮为 #FF8A80 (dark/color.json 对应值), 避免 #FF6B6B 在深色上刺眼
    primary:accent, success:'#66DD7A', danger:'#FF8A80', editColor:'#FFB366',
    fabGlow: accent + '59', fabShadow:'rgba(0,0,0,0.40)',
    tabGradientMask:'#00FFFFFF', tabGradientMaskDark:'#AA000000',
    tabLightColor:halo,
    lockOverlay:'rgba(0,0,0,0.72)', lockCardBg:'rgba(20,20,24,0.96)',
    // SSH 终端专用色
    terminalBg:'#0D0D0D', terminalBar:'#1A1A1E', terminalGreen:'#33FF33',
    terminalFg: getTerminalFgColor()
  };
}
/** 纯浅色模式 (不检查壁纸) */
export function buildLight(accent: string): Palette {
  const halo: string = getHaloColorForTheme('light');
  return {
    bg:'#FFFFFF', card:'#FFFFFF', sheetBg:'#FFFFFF', cardBorder:'rgba(0,0,0,0.06)',
    surface:'#F2F3F5', divider:'rgba(0,0,0,0.06)',
    text:'#1C1C1C', text2:'rgba(0,0,0,0.55)', text3:'rgba(0,0,0,0.30)',
    searchBg:'#F2F3F5', searchBorder:'rgba(0,0,0,0.08)',
    floatBg:'rgba(255,255,255,0.94)', floatBorder:'rgba(0,0,0,0.08)',
    primary:accent, success:'#51CF66', danger:'#FF5C5C', editColor:'#FF9500',
    fabGlow: accent + '40', fabShadow:'rgba(0,0,0,0.12)',
    tabGradientMask:'#00FFFFFF', tabGradientMaskDark:'#99FFFFFF',
    tabLightColor:halo,
    lockOverlay:'rgba(0,0,0,0.20)', lockCardBg:'rgba(255,255,255,0.97)',
    // SSH 终端专用色 (浅色模式下终端仍用深色背景)
    terminalBg:'#0D0D0D', terminalBar:'#1A1A1E', terminalGreen:'#33FF33',
    terminalFg: getTerminalFgColor()
  };
}

/** 自适应浅色模式 (根据壁纸亮度自动切换文字色) — 仅在有壁纸的页面使用 */
export function buildAdaptive(accent: string): Palette {
  const darkBg: boolean = isWallpaperDark();
  if (!darkBg) { return buildLight(accent); }
  return buildDark(accent);
}

export const DARK: Palette = buildDark('#007DFF');
export const LIGHT: Palette = buildLight('#007DFF');

/** 从 AppStorage 获取当前光晕色 */
export function getHaloColor(): string {
  const theme: string = AppStorage.get<string>('currentTheme') ?? 'light';
  return getHaloColorForTheme(theme);
}

export function currentPalette(): Palette {
  const accent: string = getAccentColor();
  return AppStorage.get<string>('currentTheme') === 'light' ? buildLight(accent) : buildDark(accent);
}

// ==================== 尺寸系统 (加大加粗) ====================
export interface SpacingMap { xs: number; sm: number; md: number; lg: number; xl: number; xxl: number }
export interface RadiusMap { xs: number; sm: number; md: number; lg: number; xl: number; xxl: number; full: number }
export interface FontMap { caption: number; body: number; bodyLarge: number; subtitle: number; title: number; headline: number; display: number }
export interface LayoutMap { navHeight: number; statusBarH: number; bottomSafe: number; cardMinH: number }

export class AppTheme {
  static readonly fontFamily: string = 'HarmonyOS Sans';
  static readonly spacing: SpacingMap = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 32 };
  static readonly radius: RadiusMap = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 24, full: 100 };
  // 字体加大 + 粗体
  static readonly fontSize: FontMap = { caption: 12, body: 15, bodyLarge: 17, subtitle: 19, title: 24, headline: 30, display: 34 };
  static readonly layout: LayoutMap = { navHeight: 56, statusBarH: 44, bottomSafe: 72, cardMinH: 160 };
  // 按钮高度 token
  static readonly btnSm: number = 36;
  static readonly btnMd: number = 44;
  static readonly btnLg: number = 56;
  // Loading spinner 尺寸 token
  static readonly spinnerSm: number = 20;
  static readonly spinnerMd: number = 32;
  static readonly spinnerLg: number = 40;
}

export class AppMotion {
  static readonly fast: number = 100;
  static readonly normal: number = 300;
  static readonly slow: number = 500;
  static staggerDelay(index: number): number { return index * 30 + 100; }
}

export class AppConfig {
  static getColor(): string { return getAccentColor(); }
  static getColorWithAlpha(alpha: number): string { return getAccentAlpha(alpha); }
  static readonly fontFamily: string = 'HarmonyOS Sans';
}
