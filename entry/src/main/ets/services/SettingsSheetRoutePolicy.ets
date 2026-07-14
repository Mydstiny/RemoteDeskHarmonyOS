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
