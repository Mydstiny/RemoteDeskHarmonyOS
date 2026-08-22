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
  parentSurfaceReady: boolean;
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
    (!state.rootSheetRequired || (state.rootSheetVisible && state.parentSurfaceReady)) &&
    !state.rootClosing && !state.closeRootAfterPicker &&
    !state.pickerVisible && !state.pickerClosing;
}

export interface SftpPeerSelectionCommitState {
  pendingHostId: string;
  pendingSelectionEpoch: number;
  activeSelectionEpoch: number;
  parentVisible: boolean;
  rootClosing: boolean;
  pickerVisible: boolean;
  pickerClosing: boolean;
}

/** A peer selection becomes visible only after the independent child Sheet exits. */
export function shouldCommitSftpPeerSelection(state: SftpPeerSelectionCommitState): boolean {
  return state.pendingHostId.trim().length > 0 && state.pendingSelectionEpoch > 0 &&
    state.pendingSelectionEpoch === state.activeSelectionEpoch && state.parentVisible &&
    !state.rootClosing && !state.pickerVisible && !state.pickerClosing;
}

export interface SftpRootSheetDismissState {
  mountMatches: boolean;
  rootSurfaceReady: boolean;
  programmaticClose: boolean;
  transferBusy: boolean;
}

/**
 * A native root Sheet may be dismissed only after its current surface is live,
 * unless the page already initiated that exact close. Transfer activity only
 * blocks interactive dismissal; it must not block an explicit close request.
 */
export function shouldAllowSftpRootSheetDismiss(state: SftpRootSheetDismissState): boolean {
  if (!state.mountMatches) {
    return false;
  }
  if (state.programmaticClose) {
    return true;
  }
  return state.rootSurfaceReady && !state.transferBusy;
}

/** Phone keeps its legacy sheet; Pad/PC expand only when both axes can hold two panes. */
export function shouldUseSftpExpandedWorkspace(isPad: boolean, isDesktop: boolean,
  width: number, height: number): boolean {
  return (isPad || isDesktop) && width >= 980 && height >= 580;
}

/** Keep footer actions reachable on short wide windows; layoutWeight still expands on roomy windows. */
export function sftpExpandedWorkspaceMinHeight(_transferBusy: boolean,
  _hasRecoveredTasks: boolean): number {
  return 150;
}

/**
 * A mounted Sheet gets exactly one native dismiss action. Binding changes and
 * interactive gestures can both lead to onWillDismiss; the caller tracks the
 * in-flight action and passes that state here.
 */
export function shouldDriveSftpNativeDismissAction(mountMatches: boolean,
  nativeDismissInFlight: boolean): boolean {
  return mountMatches && !nativeDismissInFlight;
}
