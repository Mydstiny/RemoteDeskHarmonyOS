export interface SettingsLeafSheetClosedState {
  visible: boolean;
  mode: number;
  cancelPendingOpen: boolean;
}

/**
 * State applied when a visible settings leaf requests dismissal.
 *
 * The mode must remain mounted until bindSheet.onDisappear fires.  ArkUI
 * needs the current builder content to stay alive while it plays the native
 * dismiss transition; switching to SETTINGS_SHEET_NONE in the click handler
 * makes the sheet body disappear before that transition can be rendered.
 */
export function settingsLeafSheetDismissRequestedState(currentMode: number): SettingsLeafSheetClosedState {
  return { visible: false, mode: currentMode, cancelPendingOpen: true };
}

export function settingsLeafSheetClosedState(): SettingsLeafSheetClosedState {
  return { visible: false, mode: 0, cancelPendingOpen: true };
}

export function shouldOpenRestoreConfirmation(hasValidDocument: boolean): boolean {
  return hasValidDocument;
}
