export const VNC_SHEET_MAX_WIDTH: number = 620;
export const VNC_SHEET_MIN_BODY_HEIGHT: number = 160;
export const VNC_SHEET_HEADER_ESTIMATE: number = 88;
export const VNC_SHEET_FOOTER_ESTIMATE: number = 84;

export interface VncSheetLayoutSnapshot {
  availableHeight: number;
  bodyHeight: number;
  footerReachable: boolean;
}

function finiteNonNegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

/**
 * Models the VNC-only Sheet contract: header and footer remain outside the
 * scrollable body, while the keyboard reduces only the available viewport.
 */
export function resolveVncSheetLayout(viewportHeight: number, keyboardHeight: number,
  safeBottom: number, headerHeight: number = VNC_SHEET_HEADER_ESTIMATE,
  footerHeight: number = VNC_SHEET_FOOTER_ESTIMATE): VncSheetLayoutSnapshot {
  const availableHeight: number = Math.max(0,
    finiteNonNegative(viewportHeight) - finiteNonNegative(keyboardHeight) - finiteNonNegative(safeBottom));
  const fixedHeight: number = finiteNonNegative(headerHeight) + finiteNonNegative(footerHeight);
  const bodyHeight: number = Math.max(0, availableHeight - fixedHeight);
  return {
    availableHeight,
    bodyHeight,
    footerReachable: availableHeight >= fixedHeight
  };
}

export function hasUsableVncSheetBody(snapshot: VncSheetLayoutSnapshot,
  minimumBodyHeight: number = VNC_SHEET_MIN_BODY_HEIGHT): boolean {
  return snapshot.footerReachable && snapshot.bodyHeight >= finiteNonNegative(minimumBodyHeight);
}
