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
export const SETTINGS_SHEET_VNC_CLOUD_SYNC: number = 17;
export const SETTINGS_SHEET_VNC_HOSTS: number = 18;
export const SETTINGS_SHEET_VNC_GATEWAY: number = 19;
export const SETTINGS_SHEET_VNC_INPUT: number = 20;
export const SETTINGS_SHEET_VNC_PERFORMANCE: number = 21;
export const SETTINGS_SHEET_VNC_CLIPBOARD: number = 22;

export const SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS: number = 360;

export function settingsLeafOpenDelayMs(settingsPanelOpen: boolean): number {
  return settingsPanelOpen ? SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS : 0;
}

export function shouldDelaySettingsLeafOpenForPanel(settingsPanelOpen: boolean): boolean {
  return settingsLeafOpenDelayMs(settingsPanelOpen) > 0;
}

export function settingsLeafSheetUsesSystemCloseButton(): boolean {
  return false;
}
