/**
 * SSH terminal skins (Pro 个性化方案): one set of terminal colors, font and matching
 * chrome colors for the terminal page. Pure functions and constants only, so the
 * resolution rules can be tested without ArkUI.
 */

export type SshSkinFontId = 'system' | 'noto-sans-mono' | 'jetbrains-mono' | 'fira-code' |
  'source-code-pro' | 'ibm-plex-mono' | 'cascadia-code' | 'roboto-mono' | 'inconsolata' | 'victor-mono' |
  'fira-mono' | 'geist-mono' | 'space-mono' | 'red-hat-mono' | 'martian-mono' | 'anonymous-pro' | 'commit-mono';

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
    bundled: true },
  { id: 'cascadia-code', label: 'Cascadia Code', css: '"Cascadia Code", monospace', arkui: 'Cascadia Code', bundled: true },
  { id: 'roboto-mono', label: 'Roboto Mono', css: '"Roboto Mono", monospace', arkui: 'Roboto Mono', bundled: true },
  { id: 'inconsolata', label: 'Inconsolata', css: '"Inconsolata", monospace', arkui: 'Inconsolata', bundled: true },
  { id: 'victor-mono', label: 'Victor Mono', css: '"Victor Mono", monospace', arkui: 'Victor Mono', bundled: true },
  { id: 'fira-mono', label: 'Fira Mono', css: '"Fira Mono", monospace', arkui: 'Fira Mono', bundled: true },
  { id: 'geist-mono', label: 'Geist Mono', css: '"Geist Mono", monospace', arkui: 'Geist Mono', bundled: true },
  { id: 'space-mono', label: 'Space Mono', css: '"Space Mono", monospace', arkui: 'Space Mono', bundled: true },
  { id: 'red-hat-mono', label: 'Red Hat Mono', css: '"Red Hat Mono", monospace', arkui: 'Red Hat Mono', bundled: true },
  { id: 'martian-mono', label: 'Martian Mono', css: '"Martian Mono", monospace', arkui: 'Martian Mono', bundled: true },
  { id: 'anonymous-pro', label: 'Anonymous Pro', css: '"Anonymous Pro", monospace', arkui: 'Anonymous Pro', bundled: true },
  { id: 'commit-mono', label: 'Commit Mono', css: '"Commit Mono", monospace', arkui: 'Commit Mono', bundled: true }
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
/**
 * Text for bars and keys: a near-neutral color lightly tinted by the terminal foreground,
 * falling back to pure white/black when it would not reach 4.5:1 against the surface.
 */
export function sshSkinReadableText(surface: string, tint: string): string {
  const dark: boolean = sshSkinLuminance(surface) < 0.5;
  const tinted: string = sshSkinMix(dark ? '#F2F4F7' : '#1F2328', tint, 0.14);
  return sshSkinContrast(tinted, surface) >= 4.5 ? tinted : (dark ? '#FFFFFF' : '#000000');
}

export function sshSkinAutoChrome(terminal: SshSkinTerminalColors, accent: string): SshSkinChromeColors {
  const dark: boolean = sshSkinLuminance(terminal.background) < 0.5;
  const lift: string = dark ? '#FFFFFF' : '#000000';
  const bar: string = sshSkinMix(terminal.background, lift, dark ? 0.07 : 0.05);
  const keyBar: string = sshSkinMix(terminal.background, lift, dark ? 0.05 : 0.035);
  const barText: string = sshSkinReadableText(bar, terminal.foreground);
  return {
    bar,
    barText,
    barTextDim: sshSkinAlpha(barText, 0.7),
    chip: sshSkinAlpha(barText, dark ? 0.12 : 0.08),
    keyBar,
    key: sshSkinAlpha(barText, dark ? 0.12 : 0.08),
    keyText: sshSkinReadableText(keyBar, terminal.foreground),
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
        '#546E7A', '#FF5370', '#C3E88D', '#FFCB6B', '#82AAFF', '#C792EA', '#89DDFF', '#FFFFFF'], '#80CBC4'),
    builtIn('tomorrow-night', 'Tomorrow Night', 'roboto-mono', '#1D1F21', '#C5C8C6', '#C5C8C6', '#373B41',
      ['#1D1F21', '#CC6666', '#B5BD68', '#F0C674', '#81A2BE', '#B294BB', '#8ABEB7', '#C5C8C6',
        '#969896', '#CC6666', '#B5BD68', '#F0C674', '#81A2BE', '#B294BB', '#8ABEB7', '#FFFFFF'], '#81A2BE'),
    builtIn('tomorrow', 'Tomorrow', 'roboto-mono', '#FFFFFF', '#4D4D4C', '#4D4D4C', '#D6D6D6',
      ['#000000', '#C82829', '#718C00', '#EAB700', '#4271AE', '#8959A8', '#3E999F', '#FFFFFF',
        '#8E908C', '#C82829', '#718C00', '#EAB700', '#4271AE', '#8959A8', '#3E999F', '#FFFFFF'], '#4271AE'),
    builtIn('ayu-dark', 'Ayu Dark', 'fira-mono', '#0A0E14', '#B3B1AD', '#E6B450', '#273747',
      ['#01060E', '#EA6C73', '#91B362', '#F9AF4F', '#53BDFA', '#FAE994', '#90E1C6', '#C7C7C7',
        '#686868', '#F07178', '#C2D94C', '#FFB454', '#59C2FF', '#FFEE99', '#95E6CB', '#FFFFFF'], '#E6B450'),
    builtIn('ayu-light', 'Ayu Light', 'fira-mono', '#FAFAFA', '#5C6166', '#FF9940', '#D1E4F4',
      ['#000000', '#F07171', '#86B300', '#F2AE49', '#399EE6', '#A37ACC', '#4CBF99', '#FFFFFF',
        '#828C99', '#F07171', '#86B300', '#F2AE49', '#399EE6', '#A37ACC', '#4CBF99', '#FFFFFF'], '#FF9940'),
    builtIn('everforest-dark', 'Everforest', 'victor-mono', '#2D353B', '#D3C6AA', '#D3C6AA', '#475258',
      ['#475258', '#E67E80', '#A7C080', '#DBBC7F', '#7FBBB3', '#D699B6', '#83C092', '#D3C6AA',
        '#475258', '#E67E80', '#A7C080', '#DBBC7F', '#7FBBB3', '#D699B6', '#83C092', '#D3C6AA'], '#A7C080'),
    builtIn('rose-pine', 'Rosé Pine', 'geist-mono', '#191724', '#E0DEF4', '#E0DEF4', '#403D52',
      ['#26233A', '#EB6F92', '#31748F', '#F6C177', '#9CCFD8', '#C4A7E7', '#EBBCBA', '#E0DEF4',
        '#6E6A86', '#EB6F92', '#31748F', '#F6C177', '#9CCFD8', '#C4A7E7', '#EBBCBA', '#E0DEF4'], '#C4A7E7'),
    builtIn('rose-pine-dawn', 'Rosé Pine Dawn', 'geist-mono', '#FAF4ED', '#575279', '#575279', '#DFDAD9',
      ['#F2E9E1', '#B4637A', '#286983', '#EA9D34', '#56949F', '#907AA9', '#D7827E', '#575279',
        '#9893A5', '#B4637A', '#286983', '#EA9D34', '#56949F', '#907AA9', '#D7827E', '#575279'], '#907AA9'),
    builtIn('kanagawa', 'Kanagawa', 'commit-mono', '#1F1F28', '#DCD7BA', '#C8C093', '#2D4F67',
      ['#16161D', '#C34043', '#76946A', '#C0A36E', '#7E9CD8', '#957FB8', '#6A9589', '#C8C093',
        '#727169', '#E82424', '#98BB6C', '#E6C384', '#7FB4CA', '#938AA9', '#7AA89F', '#DCD7BA'], '#7E9CD8'),
    builtIn('night-owl', 'Night Owl', 'cascadia-code', '#011627', '#D6DEEB', '#80A4C2', '#1D3B53',
      ['#011627', '#EF5350', '#22DA6E', '#C5E478', '#82AAFF', '#C792EA', '#21C7A8', '#FFFFFF',
        '#575656', '#EF5350', '#22DA6E', '#FFEB95', '#82AAFF', '#C792EA', '#7FDBCA', '#FFFFFF'], '#82AAFF'),
    builtIn('palenight', 'Palenight', 'cascadia-code', '#292D3E', '#A6ACCD', '#FFCC00', '#3C435E',
      ['#292D3E', '#F07178', '#C3E88D', '#FFCB6B', '#82AAFF', '#C792EA', '#89DDFF', '#D0D0D0',
        '#434758', '#FF8B92', '#DDFFA7', '#FFE585', '#9CC4FF', '#E1ACFF', '#A3F7FF', '#FFFFFF'], '#C792EA'),
    builtIn('gruvbox-light', 'Gruvbox Light', 'ibm-plex-mono', '#FBF1C7', '#3C3836', '#3C3836', '#EBDBB2',
      ['#FBF1C7', '#CC241D', '#98971A', '#D79921', '#458588', '#B16286', '#689D6A', '#7C6F64',
        '#928374', '#9D0006', '#79740E', '#B57614', '#076678', '#8F3F71', '#427B58', '#3C3836'], '#D65D0E'),
    builtIn('catppuccin-latte', 'Catppuccin Latte', 'fira-code', '#EFF1F5', '#4C4F69', '#DC8A78', '#ACB0BE',
      ['#5C5F77', '#D20F39', '#40A02B', '#DF8E1D', '#1E66F5', '#EA76CB', '#179299', '#ACB0BE',
        '#6C6F85', '#D20F39', '#40A02B', '#DF8E1D', '#1E66F5', '#EA76CB', '#179299', '#BCC0CC'], '#8839EF'),
    builtIn('synthwave', 'Synthwave', 'space-mono', '#262335', '#E4E1EB', '#FF7EDB', '#463465',
      ['#262335', '#FE4450', '#72F1B8', '#FEDE5D', '#03EDF9', '#FF7EDB', '#03EDF9', '#FFFFFF',
        '#614D85', '#FE4450', '#72F1B8', '#F97E72', '#03EDF9', '#FF7EDB', '#03EDF9', '#FFFFFF'], '#FF7EDB'),
    builtIn('cobalt2', 'Cobalt2', 'red-hat-mono', '#193549', '#FFFFFF', '#FFC600', '#0050A4',
      ['#000000', '#FF0000', '#38DE21', '#FFE50A', '#1460D2', '#FF005D', '#00BBBB', '#BBBBBB',
        '#555555', '#F40E17', '#3BD01D', '#EDC809', '#5555FF', '#FF55FF', '#6AE3FA', '#FFFFFF'], '#FFC600'),
    builtIn('horizon', 'Horizon', 'martian-mono', '#1C1E26', '#D5D8DA', '#E95678', '#2E303E',
      ['#16161C', '#E95678', '#29D398', '#FAB795', '#26BBD9', '#EE64AC', '#59E1E3', '#D5D8DA',
        '#5B5858', '#EC6A88', '#3FDAA4', '#FBC3A7', '#3FC4DE', '#F075B5', '#6BE4E6', '#FFFFFF'], '#E95678'),
    builtIn('retro-amber', '复古琥珀', 'anonymous-pro', '#1A1206', '#FFB000', '#FFB000', '#4A3300',
      ['#1A1206', '#FF6A00', '#FFB000', '#FFCC4D', '#E09000', '#FF8A3D', '#FFC266', '#FFD699',
        '#5C4214', '#FF8533', '#FFC233', '#FFE08A', '#F0A800', '#FFA366', '#FFD48F', '#FFEBC2'], '#FFB000')
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
