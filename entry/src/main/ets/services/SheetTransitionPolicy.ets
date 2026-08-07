export const SHEET_DISMISS_GUARD_MS: number = 320;

// SFTP lives on the SSH route while the add-host sheet lives on the host-list
// route. A mobile back navigation can briefly keep both native sheet hosts
// alive, so retain only the handoff timestamp in process memory.
let lastSshSftpSheetDismissAtMs: number = 0;

export function sheetOpenDelayMsAfterDismiss(nowMs: number, lastDismissMs: number): number {
  if (lastDismissMs <= 0 || nowMs <= 0) {
    return 0;
  }
  const elapsed: number = nowMs - lastDismissMs;
  if (elapsed >= SHEET_DISMISS_GUARD_MS) {
    return 0;
  }
  if (elapsed <= 0) {
    return SHEET_DISMISS_GUARD_MS;
  }
  return SHEET_DISMISS_GUARD_MS - elapsed;
}

export function shouldDelaySheetOpen(nowMs: number, lastDismissMs: number): boolean {
  return sheetOpenDelayMsAfterDismiss(nowMs, lastDismissMs) > 0;
}

export function noteSshSftpSheetDismissed(nowMs: number): void {
  if (nowMs > 0) {
    lastSshSftpSheetDismissAtMs = nowMs;
  }
}

export function sshSftpSheetOpenDelayMs(nowMs: number): number {
  return sheetOpenDelayMsAfterDismiss(nowMs, lastSshSftpSheetDismissAtMs);
}

/** A parent Sheet must stay mounted while its nested picker is visible or exiting. */
export function sftpPeerPickerExitPending(visible: boolean, closing: boolean): boolean {
  return visible || closing;
}

export interface SftpPeerPickerMountState {
  openRequested: boolean;
  parentVisible: boolean;
  rootSheetVisible: boolean;
  rootSheetRequired: boolean;
  rootClosing: boolean;
  closeRootAfterPicker: boolean;
  pickerVisible: boolean;
  pickerClosing: boolean;
}

/** A nested picker may mount only after its parent Sheet is a live surface. */
export function shouldMountSftpPeerPicker(state: SftpPeerPickerMountState): boolean {
  return state.openRequested && state.parentVisible &&
    (!state.rootSheetRequired || state.rootSheetVisible) &&
    !state.rootClosing && !state.closeRootAfterPicker &&
    !state.pickerVisible && !state.pickerClosing;
}
