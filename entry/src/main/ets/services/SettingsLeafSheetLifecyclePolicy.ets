export interface SettingsLeafSheetClosedState {
  visible: boolean;
  mode: number;
  cancelPendingOpen: boolean;
}

export function settingsLeafSheetClosedState(): SettingsLeafSheetClosedState {
  return { visible: false, mode: 0, cancelPendingOpen: true };
}

export function shouldOpenRestoreConfirmation(hasValidDocument: boolean): boolean {
  return hasValidDocument;
}
