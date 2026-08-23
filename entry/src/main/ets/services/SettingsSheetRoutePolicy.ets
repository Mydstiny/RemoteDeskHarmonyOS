export const SETTINGS_SHEET_NONE: number = 0;
export const SETTINGS_SHEET_ACCOUNT: number = 1;
export const SETTINGS_SHEET_ACCENT_COLOR: number = 2;
export const SETTINGS_SHEET_WALLPAPER: number = 3;
export const SETTINGS_SHEET_HALO_COLOR: number = 4;
export const SETTINGS_SHEET_TERMINAL_FG_COLOR: number = 5;
export const SETTINGS_SHEET_TERMINAL_FONT_SIZE: number = 6;
export const SETTINGS_SHEET_POPUP: number = 7;
export const SETTINGS_SHEET_RDP_CREDENTIALS: number = 8;
export const SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR: number = 9;
export const SETTINGS_SHEET_KEY_VAULT: number = 10;
export const SETTINGS_SHEET_FEEDBACK: number = 11;
export const SETTINGS_SHEET_VNC_CONNECTION: number = 12;
export const SETTINGS_SHEET_VNC_TIMEOUT: number = 13;
export const SETTINGS_SHEET_VNC_DISPLAY: number = 14;
export const SETTINGS_SHEET_VNC_SECURITY: number = 15;
export const SETTINGS_SHEET_VNC_TRUST: number = 16;
export const SETTINGS_SHEET_VNC_HOSTS: number = 18;
export const SETTINGS_SHEET_VNC_GATEWAY: number = 19;
export const SETTINGS_SHEET_VNC_INPUT: number = 20;
export const SETTINGS_SHEET_VNC_PERFORMANCE: number = 21;
export const SETTINGS_SHEET_VNC_CLIPBOARD: number = 22;
export const SETTINGS_SHEET_TERMINAL_LINE_SPACING: number = 23;
export const SETTINGS_SHEET_MOONLIGHT_VIDEO: number = 24;
export const SETTINGS_SHEET_MOONLIGHT_AUDIO: number = 25;
export const SETTINGS_SHEET_MOONLIGHT_INPUT: number = 26;
export const SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY: number = 27;
export const SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS: number = 28;
export const SETTINGS_SHEET_MOONLIGHT_TRUST: number = 29;
export const SETTINGS_SHEET_MOONLIGHT_DATA: number = 30;
export const SETTINGS_SHEET_DIAGNOSTIC_LOG: number = 31;
export const SETTINGS_SHEET_VIRTUAL_KEYBOARD: number = 32;

export const SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS: number = 360;

export interface MoonlightSettingsRouteSpec {
  mode: number;
  section: string;
  title: string;
  height: number;
  owner: string;
}

export function moonlightSettingsRouteSpecs(): MoonlightSettingsRouteSpec[] {
  return [
    { mode: SETTINGS_SHEET_MOONLIGHT_VIDEO, section: 'video', title: '画面', height: 820, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_AUDIO, section: 'audio', title: '音频', height: 620, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_INPUT, section: 'input', title: '控制与手柄', height: 680, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY, section: 'networkSecurity', title: '网络与安全', height: 820, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS, section: 'diagnostics', title: '诊断', height: 560, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_TRUST, section: 'trust', title: '配对与信任', height: 520, owner: 'moonlight' },
    { mode: SETTINGS_SHEET_MOONLIGHT_DATA, section: 'data', title: '数据管理', height: 720, owner: 'moonlight' }
  ];
}

export function moonlightSettingsRouteSpec(mode: number): MoonlightSettingsRouteSpec | null {
  const specs: MoonlightSettingsRouteSpec[] = moonlightSettingsRouteSpecs();
  for (let i = 0; i < specs.length; i++) {
    if (specs[i].mode === mode) { return specs[i]; }
  }
  return null;
}

/** Moonlight leaves share one bindSheet owner and use their route density as height. */
export function moonlightSettingsLeafSheetHeight(mode: number): number {
  const spec: MoonlightSettingsRouteSpec | null = moonlightSettingsRouteSpec(mode);
  return spec === null || spec.owner !== 'moonlight' ? 0 : spec.height;
}

/**
 * Content-matched heights for VNC leaf settings hosted by the settings page.
 *
 * The shared VNC scaffold keeps its header/footer fixed and its body scrollable,
 * so compact leaves should not inherit the same near-full-screen height as the
 * display editor. A non-VNC mode returns 0 and keeps the caller's existing
 * FIT_CONTENT behavior.
 */
export function vncSettingsLeafSheetHeight(mode: number): number {
  if (mode === SETTINGS_SHEET_VNC_DISPLAY) { return 700; }
  if (mode === SETTINGS_SHEET_VNC_INPUT) { return 560; }
  if (mode === SETTINGS_SHEET_VNC_TIMEOUT || mode === SETTINGS_SHEET_VNC_PERFORMANCE) { return 470; }
  if (mode === SETTINGS_SHEET_VNC_CONNECTION) { return 420; }
  if (mode === SETTINGS_SHEET_VNC_SECURITY) { return 340; }
  if (mode === SETTINGS_SHEET_VNC_CLIPBOARD) { return 320; }
  if (mode === SETTINGS_SHEET_VNC_TRUST) { return 280; }
  if (mode === SETTINGS_SHEET_VNC_HOSTS || mode === SETTINGS_SHEET_VNC_GATEWAY) { return 260; }
  return 0;
}

export function diagnosticLogSettingsLeafSheetHeight(mode: number): number {
  return mode === SETTINGS_SHEET_DIAGNOSTIC_LOG ? 740 : 0;
}

export function virtualKeyboardSettingsLeafSheetHeight(mode: number): number {
  return mode === SETTINGS_SHEET_VIRTUAL_KEYBOARD ? 860 : 0;
}

export function settingsLeafOpenDelayMs(settingsPanelOpen: boolean): number {
  return settingsPanelOpen ? SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS : 0;
}

export function shouldDelaySettingsLeafOpenForPanel(settingsPanelOpen: boolean): boolean {
  return settingsLeafOpenDelayMs(settingsPanelOpen) > 0;
}

export function settingsLeafSheetUsesSystemCloseButton(): boolean {
  return false;
}
