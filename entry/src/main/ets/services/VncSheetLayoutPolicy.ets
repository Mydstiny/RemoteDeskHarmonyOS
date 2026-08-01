export const VNC_SHEET_MAX_WIDTH: number = 620;
export const VNC_SHEET_MIN_BODY_HEIGHT: number = 160;
export const VNC_SHEET_HEADER_ESTIMATE: number = 88;
export const VNC_SHEET_FOOTER_ESTIMATE: number = 84;
export const VNC_SHEET_COMPACT_HEADER_ESTIMATE: number = 52;
export const VNC_SHEET_COMPACT_FOOTER_ESTIMATE: number = 64;
export const VNC_SHEET_DENSITY_REGULAR: number = 0;
export const VNC_SHEET_DENSITY_COMPACT: number = 1;
export const VNC_SHEET_DENSITY_ACTION_ONLY: number = 2;

export interface VncSheetLayoutSnapshot {
  availableHeight: number;
  bodyHeight: number;
  footerReachable: boolean;
  density: number;
  effectiveHeaderHeight: number;
  effectiveFooterHeight: number;
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
  const regularHeaderHeight: number = finiteNonNegative(headerHeight);
  const regularFooterHeight: number = finiteNonNegative(footerHeight);
  let effectiveHeaderHeight: number = regularHeaderHeight;
  let effectiveFooterHeight: number = regularFooterHeight;
  let density: number = VNC_SHEET_DENSITY_REGULAR;
  if (availableHeight < regularHeaderHeight + regularFooterHeight) {
    density = VNC_SHEET_DENSITY_COMPACT;
    effectiveHeaderHeight = Math.min(regularHeaderHeight, VNC_SHEET_COMPACT_HEADER_ESTIMATE);
    effectiveFooterHeight = Math.min(regularFooterHeight, VNC_SHEET_COMPACT_FOOTER_ESTIMATE);
    if (availableHeight < effectiveHeaderHeight + effectiveFooterHeight) {
      density = VNC_SHEET_DENSITY_ACTION_ONLY;
      effectiveHeaderHeight = 0;
    }
  }
  const fixedHeight: number = effectiveHeaderHeight + effectiveFooterHeight;
  const bodyHeight: number = Math.max(0, availableHeight - fixedHeight);
  return {
    availableHeight,
    bodyHeight,
    footerReachable: availableHeight >= fixedHeight,
    density,
    effectiveHeaderHeight,
    effectiveFooterHeight
  };
}

export function hasUsableVncSheetBody(snapshot: VncSheetLayoutSnapshot,
  minimumBodyHeight: number = VNC_SHEET_MIN_BODY_HEIGHT): boolean {
  return snapshot.footerReachable && snapshot.bodyHeight >= finiteNonNegative(minimumBodyHeight);
}
