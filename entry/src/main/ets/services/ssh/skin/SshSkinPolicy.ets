/**
 * SSH terminal skins (Pro 个性化方案): one set of terminal colors, font and matching
 * chrome colors for the terminal page. Pure functions and constants only, so the
 * resolution rules can be tested without ArkUI.
 */

export type SshSkinFontId = 'system' | 'noto-sans-mono' | 'jetbrains-mono' | 'fira-code' |
  'source-code-pro' | 'ibm-plex-mono';

export interface SshSkinFont {
  id: SshSkinFontId;
  label: string;
  /** CSS font-family list handed to xterm; always ends with the system monospace fallback. */
  css: string;
  /** ArkUI font family for previews in settings (bundled fonts are registered under these names). */
  arkui: string;
  bundled: boolean;
}

export interface SshSkinTerminalColors {
  background: string;
  foreground: string;
  cursor: string;
  selection: string;
  /** 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright ones. */
  palette: string[];
}

export interface SshSkinChromeColors {
  bar: string;
  barText: string;
  barTextDim: string;
  chip: string;
  keyBar: string;
  key: string;
  keyText: string;
  accent: string;
  divider: string;
  sheet: string;
}

export interface SshSkin {
  id: string;
  name: string;
  builtIn: boolean;
  dark: boolean;
  fontId: SshSkinFontId;
  terminal: SshSkinTerminalColors;
  chrome: SshSkinChromeColors;
}

export const SSH_SKIN_DEFAULT_ID: string = 'default-dark';
export const SSH_SKIN_CUSTOM_MAX: number = 20;
export const SSH_SKIN_NAME_MAX: number = 20;

export const SSH_SKIN_FONTS: SshSkinFont[] = [
  { id: 'system', label: '系统等宽', css: 'monospace', arkui: 'monospace', bundled: false },
  { id: 'noto-sans-mono', label: 'Noto Sans Mono', css: '"Noto Sans Mono", monospace', arkui: 'Noto Sans Mono',
    bundled: false },
  { id: 'jetbrains-mono', label: 'JetBrains Mono', css: '"JetBrains Mono", monospace', arkui: 'JetBrains Mono',
    bundled: true },
  { id: 'fira-code', label: 'Fira Code', css: '"Fira Code", monospace', arkui: 'Fira Code', bundled: true },
  { id: 'source-code-pro', label: 'Source Code Pro', css: '"Source Code Pro", monospace', arkui: 'Source Code Pro',
    bundled: true },
  { id: 'ibm-plex-mono', label: 'IBM Plex Mono', css: '"IBM Plex Mono", monospace', arkui: 'IBM Plex Mono',
    bundled: true }
];

const HEX: RegExp = /^#[0-9A-Fa-f]{6}$/;

export function sshSkinColorValid(value: Object | null | undefined): boolean {
  return typeof value === 'string' && HEX.test(value as string);
}

export function sshSkinFont(id: string): SshSkinFont {
  const found: SshSkinFont | undefined = SSH_SKIN_FONTS.find((font: SshSkinFont): boolean => font.id === id);
  return found !== undefined ? found : SSH_SKIN_FONTS[0];
}

function channel(hex: string, index: number): number { return parseInt(hex.substring(1 + index * 2, 3 + index * 2), 16); }

function toHex(value: number): string {
  const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
  return (clamped < 16 ? '0' : '') + clamped.toString(16).toUpperCase();
}

/** Linear mix of two #RRGGBB colors; amount 0 keeps `from`, 1 gives `to`. */
export function sshSkinMix(from: string, to: string, amount: number): string {
  let result: string = '#';
  for (let index: number = 0; index < 3; index++) {
    result += toHex(channel(from, index) + (channel(to, index) - channel(from, index)) * amount);
  }
  return result;
}

/** #AARRGGBB with the given opacity (ArkUI color format). */
export function sshSkinAlpha(hex: string, opacity: number): string {
  return '#' + toHex(opacity * 255) + hex.substring(1).toUpperCase();
}

export function sshSkinLuminance(hex: string): number {
  return (0.299 * channel(hex, 0) + 0.587 * channel(hex, 1) + 0.114 * channel(hex, 2)) / 255;
}

function relative(hex: string): number {
  const linear = (value: number): number => {
    const c: number = value / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linear(channel(hex, 0)) + 0.7152 * linear(channel(hex, 1)) + 0.0722 * linear(channel(hex, 2));
}

/** WCAG contrast ratio between two colors (1-21). */
export function sshSkinContrast(a: string, b: string): number {
  const la: number = relative(a);
  const lb: number = relative(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Chrome colors that match a terminal: bars a step away from its background, text from its foreground. */
export function sshSkinAutoChrome(terminal: SshSkinTerminalColors, accent: string): SshSkinChromeColors {
  const dark: boolean = sshSkinLuminance(terminal.background) < 0.5;
  const lift: string = dark ? '#FFFFFF' : '#000000';
  return {
    bar: sshSkinMix(terminal.background, lift, dark ? 0.06 : 0.04),
    barText: terminal.foreground,
    barTextDim: sshSkinAlpha(terminal.foreground, 0.62),
    chip: sshSkinAlpha(terminal.foreground, 0.1),
    keyBar: sshSkinMix(terminal.background, lift, dark ? 0.04 : 0.03),
    key: sshSkinAlpha(terminal.foreground, dark ? 0.1 : 0.08),
    keyText: terminal.foreground,
    accent,
    divider: sshSkinAlpha(terminal.foreground, 0.12),
    sheet: sshSkinMix(terminal.background, lift, dark ? 0.09 : 0.02)
  };
}

function builtIn(id: string, name: string, fontId: SshSkinFontId, background: string, foreground: string,
  cursor: string, selection: string, palette: string[], accent: string): SshSkin {
  const terminal: SshSkinTerminalColors = { background, foreground, cursor, selection, palette };
  return { id, name, builtIn: true, dark: sshSkinLuminance(background) < 0.5, fontId, terminal,
    chrome: sshSkinAutoChrome(terminal, accent) };
}

const SOLARIZED: string[] = ['#073642', '#DC322F', '#859900', '#B58900', '#268BD2', '#D33682', '#2AA198', '#EEE8D5',
  '#002B36', '#CB4B16', '#586E75', '#657B83', '#839496', '#6C71C4', '#93A1A1', '#FDF6E3'];

/** Built-in skins; palettes follow the published open-source schemes of the same names. */
export function sshBuiltInSkins(): SshSkin[] {
  return [
    builtIn(SSH_SKIN_DEFAULT_ID, '默认深色', 'system', '#0D0D0D', '#33FF33', '#33FF33', '#2A4A2A',
      ['#0D0D0D', '#CD3131', '#0DBC79', '#E5E510', '#2472C8', '#BC3FBC', '#11A8CD', '#E5E5E5',
        '#666666', '#F14C4C', '#23D18B', '#F5F543', '#3B8EEA', '#D670D6', '#29B8DB', '#FFFFFF'], '#33FF33'),
    builtIn('dracula', 'Dracula', 'jetbrains-mono', '#282A36', '#F8F8F2', '#F8F8F2', '#44475A',
      ['#21222C', '#FF5555', '#50FA7B', '#F1FA8C', '#BD93F9', '#FF79C6', '#8BE9FD', '#F8F8F2',
        '#6272A4', '#FF6E6E', '#69FF94', '#FFFFA5', '#D6ACFF', '#FF92DF', '#A4FFFF', '#FFFFFF'], '#BD93F9'),
    builtIn('nord', 'Nord', 'jetbrains-mono', '#2E3440', '#D8DEE9', '#D8DEE9', '#434C5E',
      ['#3B4252', '#BF616A', '#A3BE8C', '#EBCB8B', '#81A1C1', '#B48EAD', '#88C0D0', '#E5E9F0',
        '#4C566A', '#BF616A', '#A3BE8C', '#EBCB8B', '#81A1C1', '#B48EAD', '#8FBCBB', '#ECEFF4'], '#88C0D0'),
    builtIn('one-dark', 'One Dark', 'fira-code', '#282C34', '#ABB2BF', '#528BFF', '#3E4451',
      ['#282C34', '#E06C75', '#98C379', '#E5C07B', '#61AFEF', '#C678DD', '#56B6C2', '#ABB2BF',
        '#5C6370', '#E06C75', '#98C379', '#E5C07B', '#61AFEF', '#C678DD', '#56B6C2', '#FFFFFF'], '#61AFEF'),
    builtIn('monokai', 'Monokai', 'source-code-pro', '#272822', '#F8F8F2', '#F8F8F0', '#49483E',
      ['#272822', '#F92672', '#A6E22E', '#F4BF75', '#66D9EF', '#AE81FF', '#A1EFE4', '#F8F8F2',
        '#75715E', '#F92672', '#A6E22E', '#F4BF75', '#66D9EF', '#AE81FF', '#A1EFE4', '#F9F8F5'], '#A6E22E'),
    builtIn('solarized-dark', 'Solarized Dark', 'source-code-pro', '#002B36', '#839496', '#93A1A1', '#073642',
      SOLARIZED, '#268BD2'),
    builtIn('solarized-light', 'Solarized Light', 'source-code-pro', '#FDF6E3', '#657B83', '#586E75', '#EEE8D5',
      SOLARIZED, '#268BD2'),
    builtIn('gruvbox-dark', 'Gruvbox Dark', 'ibm-plex-mono', '#282828', '#EBDBB2', '#EBDBB2', '#504945',
      ['#282828', '#CC241D', '#98971A', '#D79921', '#458588', '#B16286', '#689D6A', '#A89984',
        '#928374', '#FB4934', '#B8BB26', '#FABD2F', '#83A598', '#D3869B', '#8EC07C', '#EBDBB2'], '#FABD2F'),
    builtIn('tokyo-night', 'Tokyo Night', 'jetbrains-mono', '#1A1B26', '#C0CAF5', '#C0CAF5', '#33467C',
      ['#15161E', '#F7768E', '#9ECE6A', '#E0AF68', '#7AA2F7', '#BB9AF7', '#7DCFFF', '#A9B1D6',
        '#414868', '#F7768E', '#9ECE6A', '#E0AF68', '#7AA2F7', '#BB9AF7', '#7DCFFF', '#C0CAF5'], '#7AA2F7'),
    builtIn('catppuccin-mocha', 'Catppuccin Mocha', 'fira-code', '#1E1E2E', '#CDD6F4', '#F5E0DC', '#45475A',
      ['#45475A', '#F38BA8', '#A6E3A1', '#F9E2AF', '#89B4FA', '#F5C2E7', '#94E2D5', '#BAC2DE',
        '#585B70', '#F38BA8', '#A6E3A1', '#F9E2AF', '#89B4FA', '#F5C2E7', '#94E2D5', '#A6ADC8'], '#CBA6F7'),
    builtIn('github-light', 'GitHub Light', 'ibm-plex-mono', '#FFFFFF', '#24292F', '#0969DA', '#DDF4FF',
      ['#24292F', '#CF222E', '#116329', '#4D2D00', '#0969DA', '#8250DF', '#1B7C83', '#6E7781',
        '#57606A', '#A40E26', '#1A7F37', '#633C01', '#218BFF', '#A475F9', '#3192AA', '#8C959F'], '#0969DA'),
    builtIn('material-ocean', 'Material Ocean', 'jetbrains-mono', '#0F111A', '#8F93A2', '#FFCC00', '#1F2233',
      ['#546E7A', '#FF5370', '#C3E88D', '#FFCB6B', '#82AAFF', '#C792EA', '#89DDFF', '#FFFFFF',
        '#546E7A', '#FF5370', '#C3E88D', '#FFCB6B', '#82AAFF', '#C792EA', '#89DDFF', '#FFFFFF'], '#80CBC4')
  ];
}

function validTerminal(value: SshSkinTerminalColors | undefined): boolean {
  return value !== undefined && value !== null && sshSkinColorValid(value.background) &&
    sshSkinColorValid(value.foreground) && sshSkinColorValid(value.cursor) && sshSkinColorValid(value.selection) &&
    Array.isArray(value.palette) && value.palette.length === 16 &&
    value.palette.every((color: string): boolean => sshSkinColorValid(color));
}

const CHROME_COLOR: RegExp = /^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/;

function chromeColor(value: Object | undefined): boolean {
  return typeof value === 'string' && CHROME_COLOR.test(value as string);
}

function validChrome(value: SshSkinChromeColors | undefined): boolean {
  if (value === undefined || value === null) { return false; }
  return chromeColor(value.bar) && chromeColor(value.barText) && chromeColor(value.barTextDim) &&
    chromeColor(value.chip) && chromeColor(value.keyBar) && chromeColor(value.key) && chromeColor(value.keyText) &&
    chromeColor(value.accent) && chromeColor(value.divider) && chromeColor(value.sheet);
}

/** A user skin read from storage: whitelisted fields only; anything malformed is dropped. */
export function sanitizeSshCustomSkin(value: Object | null | undefined): SshSkin | null {
  if (typeof value !== 'object' || value === null) { return null; }
  const skin: SshSkin = value as SshSkin;
  if (typeof skin.id !== 'string' || !/^custom-[A-Za-z0-9-]{1,40}$/.test(skin.id) ||
    typeof skin.name !== 'string' || !validTerminal(skin.terminal) || !validChrome(skin.chrome)) { return null; }
  const name: string = skin.name.trim().replace(/[\r\n\t]+/g, ' ').slice(0, SSH_SKIN_NAME_MAX);
  const font: SshSkinFont = sshSkinFont(typeof skin.fontId === 'string' ? skin.fontId : 'system');
  const terminal: SshSkinTerminalColors = {
    background: skin.terminal.background.toUpperCase(), foreground: skin.terminal.foreground.toUpperCase(),
    cursor: skin.terminal.cursor.toUpperCase(), selection: skin.terminal.selection.toUpperCase(),
    palette: skin.terminal.palette.map((color: string): string => color.toUpperCase())
  };
  const chrome: SshSkinChromeColors = {
    bar: skin.chrome.bar, barText: skin.chrome.barText, barTextDim: skin.chrome.barTextDim, chip: skin.chrome.chip,
    keyBar: skin.chrome.keyBar, key: skin.chrome.key, keyText: skin.chrome.keyText, accent: skin.chrome.accent,
    divider: skin.chrome.divider, sheet: skin.chrome.sheet
  };
  return { id: skin.id, name: name.length > 0 ? name : '自定义皮肤', builtIn: false,
    dark: sshSkinLuminance(terminal.background) < 0.5, fontId: font.id, terminal, chrome };
}

/** A new editable copy of any skin. */
export function sshSkinCopy(source: SshSkin, id: string, name: string): SshSkin {
  return {
    id, name: name.slice(0, SSH_SKIN_NAME_MAX), builtIn: false, dark: source.dark, fontId: source.fontId,
    terminal: { background: source.terminal.background, foreground: source.terminal.foreground,
      cursor: source.terminal.cursor, selection: source.terminal.selection, palette: source.terminal.palette.slice(0) },
    chrome: { bar: source.chrome.bar, barText: source.chrome.barText, barTextDim: source.chrome.barTextDim,
      chip: source.chrome.chip, keyBar: source.chrome.keyBar, key: source.chrome.key, keyText: source.chrome.keyText,
      accent: source.chrome.accent, divider: source.chrome.divider, sheet: source.chrome.sheet }
  };
}

export interface SshSkinSettings {
  /** Selected global skin id; empty means skins are off (free appearance). */
  globalSkinId: string;
  /** Overrides the skin's own font; empty keeps the skin font. */
  fontId: string;
  hostSkins: Record<string, string>;
  custom: SshSkin[];
}

export function emptySshSkinSettings(): SshSkinSettings {
  return { globalSkinId: '', fontId: '', hostSkins: {}, custom: [] };
}

export function sshSkinById(settings: SshSkinSettings, id: string): SshSkin | null {
  const all: SshSkin[] = sshBuiltInSkins().concat(settings.custom);
  const found: SshSkin | undefined = all.find((skin: SshSkin): boolean => skin.id === id);
  return found !== undefined ? found : null;
}

/**
 * The skin a terminal uses, or null for the free appearance. Pro is required; a host
 * assignment beats the global choice; an unknown id falls back rather than failing.
 */
export function resolveSshSkin(settings: SshSkinSettings, hostId: string, pro: boolean): SshSkin | null {
  if (!pro) { return null; }
  const hostSkin: string = hostId.length > 0 ? (settings.hostSkins[hostId] ?? '') : '';
  const skin: SshSkin | null = sshSkinById(settings, hostSkin.length > 0 ? hostSkin : settings.globalSkinId);
  if (skin === null) { return null; }
  if (settings.fontId.length === 0) { return skin; }
  const copy: SshSkin = sshSkinCopy(skin, skin.id, skin.name);
  copy.builtIn = skin.builtIn;
  copy.fontId = sshSkinFont(settings.fontId).id;
  return copy;
}

export function encodeSshSkinSettings(settings: SshSkinSettings): string {
  const hostSkins: Record<string, string> = {};
  Object.keys(settings.hostSkins).slice(0, 256).forEach((hostId: string): void => {
    const id: string = settings.hostSkins[hostId];
    if (hostId.length <= 128 && typeof id === 'string' && id.length <= 64) { hostSkins[hostId] = id; }
  });
  return JSON.stringify({ version: 1, globalSkinId: settings.globalSkinId.slice(0, 64),
    fontId: settings.fontId.slice(0, 32), hostSkins,
    custom: settings.custom.slice(0, SSH_SKIN_CUSTOM_MAX) });
}

export function decodeSshSkinSettings(raw: string): SshSkinSettings {
  const result: SshSkinSettings = emptySshSkinSettings();
  if (raw.trim().length === 0 || raw.length > 128 * 1024) { return result; }
  try {
    const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    if (parsed['version'] !== 1) { return result; }
    if (typeof parsed['globalSkinId'] === 'string') { result.globalSkinId = (parsed['globalSkinId'] as string).slice(0, 64); }
    if (typeof parsed['fontId'] === 'string' && (parsed['fontId'] as string).length > 0) {
      result.fontId = sshSkinFont(parsed['fontId'] as string).id;
    }
    const hosts: Object = parsed['hostSkins'];
    if (typeof hosts === 'object' && hosts !== null && !Array.isArray(hosts)) {
      const record: Record<string, Object> = hosts as Record<string, Object>;
      Object.keys(record).slice(0, 256).forEach((hostId: string): void => {
        if (typeof record[hostId] === 'string' && hostId.length <= 128) { result.hostSkins[hostId] = record[hostId] as string; }
      });
    }
    if (Array.isArray(parsed['custom'])) {
      (parsed['custom'] as Object[]).slice(0, SSH_SKIN_CUSTOM_MAX).forEach((item: Object): void => {
        const skin: SshSkin | null = sanitizeSshCustomSkin(item);
        if (skin !== null && !result.custom.some((other: SshSkin): boolean => other.id === skin.id)) {
          result.custom.push(skin);
        }
      });
    }
  } catch (_error) { return emptySshSkinSettings(); }
  return result;
}
