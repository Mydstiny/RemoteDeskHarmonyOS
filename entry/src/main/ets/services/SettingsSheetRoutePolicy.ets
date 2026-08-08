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

export const SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS: number = 360;

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

export function settingsLeafOpenDelayMs(settingsPanelOpen: boolean): number {
  return settingsPanelOpen ? SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS : 0;
}

export function shouldDelaySettingsLeafOpenForPanel(settingsPanelOpen: boolean): boolean {
  return settingsLeafOpenDelayMs(settingsPanelOpen) > 0;
}

export function settingsLeafSheetUsesSystemCloseButton(): boolean {
  return false;
}
