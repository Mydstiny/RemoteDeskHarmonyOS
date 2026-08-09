import {
  VncCertificatePreflightDecision,
  VncCertificatePreflightState,
  vncCertificateDecisionAllowed
} from './VncCertificatePreflightPolicy';

/** Actions exposed by the VNC certificate Sheet. */
export enum VncCertificateSheetAction {
  CANCEL = 'CANCEL',
  RETRY = 'RETRY',
  SHOW_DETAILS = 'SHOW_DETAILS',
  HIDE_DETAILS = 'HIDE_DETAILS',
  CONTINUE_PLAINTEXT = 'CONTINUE_PLAINTEXT',
  CONTINUE_ONCE = 'CONTINUE_ONCE',
  TRUST = 'TRUST',
  UPDATE_TRUST = 'UPDATE_TRUST'
}

export interface VncCertificateSheetAttempt {
  sheetGeneration: number;
  probeGeneration: number;
  connectionAttemptGeneration: number;
}

function isPositiveGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

/** Sheet generations are independent from probe generations and never use zero. */
export function nextVncCertificateSheetGeneration(current: number): number {
  return !isPositiveGeneration(current) || current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function shouldApplyVncCertificateSheetResult(
  active: VncCertificateSheetAttempt,
  result: VncCertificateSheetAttempt
): boolean {
  return isPositiveGeneration(active.sheetGeneration) &&
    isPositiveGeneration(active.probeGeneration) &&
    isPositiveGeneration(active.connectionAttemptGeneration) &&
    isPositiveGeneration(result.sheetGeneration) &&
    isPositiveGeneration(result.probeGeneration) &&
    isPositiveGeneration(result.connectionAttemptGeneration) &&
    active.sheetGeneration === result.sheetGeneration &&
    active.probeGeneration === result.probeGeneration &&
    active.connectionAttemptGeneration === result.connectionAttemptGeneration;
}

export function shouldShowVncCertificateSheet(
  state: VncCertificatePreflightState,
  sheetVisible: boolean,
  closing: boolean
): boolean {
  if (closing || sheetVisible) { return false; }
  return state === VncCertificatePreflightState.PROBING ||
    state === VncCertificatePreflightState.PLAINTEXT_WARNING ||
    state === VncCertificatePreflightState.TRUST_FIRST_TIME ||
    state === VncCertificatePreflightState.CERTIFICATE_CHANGED ||
    state === VncCertificatePreflightState.ERROR;
}

export function shouldKeepVncCertificateSheetOpen(
  state: VncCertificatePreflightState,
  closing: boolean
): boolean {
  if (closing) { return true; }
  return state !== VncCertificatePreflightState.IDLE &&
    state !== VncCertificatePreflightState.TRUSTED_MATCH &&
    state !== VncCertificatePreflightState.CLOSING;
}

export function vncCertificateSheetActionAllowed(
  state: VncCertificatePreflightState,
  action: VncCertificateSheetAction
): boolean {
  if (state === VncCertificatePreflightState.CLOSING ||
    state === VncCertificatePreflightState.IDLE ||
    state === VncCertificatePreflightState.TRUSTED_MATCH) {
    return false;
  }
  if (action === VncCertificateSheetAction.CANCEL) { return true; }
  if (state === VncCertificatePreflightState.PROBING) { return false; }
  if (state === VncCertificatePreflightState.ERROR) {
    return action === VncCertificateSheetAction.RETRY;
  }
  if (action === VncCertificateSheetAction.SHOW_DETAILS ||
    action === VncCertificateSheetAction.HIDE_DETAILS) {
    return true;
  }
  if (action === VncCertificateSheetAction.CONTINUE_PLAINTEXT) {
    return vncCertificateDecisionAllowed(
      state, VncCertificatePreflightDecision.CONTINUE_PLAINTEXT);
  }
  if (action === VncCertificateSheetAction.CONTINUE_ONCE) {
    return vncCertificateDecisionAllowed(
      state, VncCertificatePreflightDecision.CONTINUE_ONCE);
  }
  if (action === VncCertificateSheetAction.TRUST) {
    return vncCertificateDecisionAllowed(state, VncCertificatePreflightDecision.TRUST);
  }
  if (action === VncCertificateSheetAction.UPDATE_TRUST) {
    return vncCertificateDecisionAllowed(state, VncCertificatePreflightDecision.UPDATE_TRUST);
  }
  return false;
}

export function vncCertificateDecisionForSheetAction(
  state: VncCertificatePreflightState,
  action: VncCertificateSheetAction
): VncCertificatePreflightDecision | null {
  if (!vncCertificateSheetActionAllowed(state, action)) { return null; }
  if (action === VncCertificateSheetAction.CANCEL) {
    return VncCertificatePreflightDecision.CANCEL;
  }
  if (action === VncCertificateSheetAction.CONTINUE_PLAINTEXT) {
    return VncCertificatePreflightDecision.CONTINUE_PLAINTEXT;
  }
  if (action === VncCertificateSheetAction.CONTINUE_ONCE) {
    return VncCertificatePreflightDecision.CONTINUE_ONCE;
  }
  if (action === VncCertificateSheetAction.TRUST) {
    return VncCertificatePreflightDecision.TRUST;
  }
  if (action === VncCertificateSheetAction.UPDATE_TRUST) {
    return VncCertificatePreflightDecision.UPDATE_TRUST;
  }
  return null;
}

/** Never route to credentials until the native Sheet has fully disappeared. */
export function shouldRouteVncAfterCertificateSheetDisappear(
  sheetVisible: boolean,
  closing: boolean,
  pendingRoute: boolean
): boolean {
  return pendingRoute && !sheetVisible && !closing;
}

/** A trusted result must close an already-visible Sheet before routing. */
export function shouldCloseVncCertificateSheetBeforeRoute(
  sheetVisible: boolean,
  closing: boolean,
  pendingRoute: boolean
): boolean {
  return pendingRoute && sheetVisible && !closing;
}

export function shouldClearVncCertificateSensitiveHandoffs(
  pageClosing: boolean,
  connectionCancelled: boolean,
  securityBarrierTriggered: boolean
): boolean {
  return pageClosing || connectionCancelled || securityBarrierTriggered;
}
