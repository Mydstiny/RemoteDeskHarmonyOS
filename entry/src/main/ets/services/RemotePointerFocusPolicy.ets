/**
 * Focus recovery decisions for the remote pointer path.
 *
 * A normal pointer transaction is not evidence that the hidden keyboard
 * proxy lost focus. Re-requesting an already-held ArkUI focus lease can
 * create a blur/refocus loop on API 23.
 */
export interface RemotePointerFocusRecoveryState {
  proxyExpected: boolean;
  recoveryNeeded: boolean;
  requestScheduled: boolean;
  requestPending: boolean;
}

/**
 * Keep tiny sensor jitter from turning a physical click into a remote drag.
 * The threshold is measured in the local ArkUI coordinate space so it does
 * not change with the negotiated remote resolution or display scale.
 */
export const RUSTDESK_MACOS_PHYSICAL_MOUSE_DRAG_THRESHOLD_VP: number = 4;

export function shouldStageRustDeskMacPhysicalMouseClick(
  protocol: string,
  keyboardLayout: string,
  physicalMouseSource: boolean,
  button: number
): boolean {
  return protocol === 'rustdesk' && keyboardLayout === 'macos' &&
    physicalMouseSource && button === 0;
}

export function shouldStartRustDeskMacPhysicalMouseDrag(
  pressLocalX: number,
  pressLocalY: number,
  currentLocalX: number,
  currentLocalY: number,
  thresholdVp: number = RUSTDESK_MACOS_PHYSICAL_MOUSE_DRAG_THRESHOLD_VP
): boolean {
  if (!Number.isFinite(pressLocalX) || !Number.isFinite(pressLocalY) ||
    !Number.isFinite(currentLocalX) || !Number.isFinite(currentLocalY) ||
    !Number.isFinite(thresholdVp) || thresholdVp < 0) {
    return false;
  }
  const deltaX: number = currentLocalX - pressLocalX;
  const deltaY: number = currentLocalY - pressLocalY;
  return deltaX * deltaX + deltaY * deltaY >= thresholdVp * thresholdVp;
}

export function shouldRecoverRemotePointerFocus(
  state: RemotePointerFocusRecoveryState
): boolean {
  return state.proxyExpected &&
    (state.recoveryNeeded || state.requestScheduled || state.requestPending);
}
