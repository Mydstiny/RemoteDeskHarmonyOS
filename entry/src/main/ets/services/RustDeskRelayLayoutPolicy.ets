/**
 * Layout rules shared by the RustDesk/VNC relay directory.
 *
 * The phone FAB is anchored 120 vp above the viewport bottom and is 56 vp
 * tall. Keep one additional 24 vp tap-safe gap after the final list card.
 */
export const RUSTDESK_RELAY_PHONE_BOTTOM_CLEARANCE: number = 200;
export const RUSTDESK_RELAY_OTHER_BOTTOM_CLEARANCE: number = 120;
export const RUSTDESK_RELAY_COMPACT_SHEET_MIN_HEIGHT: number = 480;
export const RUSTDESK_RELAY_COMPACT_SHEET_MAX_HEIGHT: number = 620;

export function rustDeskRelayDirectoryBottomClearance(breakpoint: string): number {
  return breakpoint === 'sm' ? RUSTDESK_RELAY_PHONE_BOTTOM_CLEARANCE :
    RUSTDESK_RELAY_OTHER_BOTTOM_CLEARANCE;
}

/**
 * The compact RustDesk editor fits its collapsed content. Advanced endpoint
 * fields and the VNC gateway editor need a large, resize-only sheet.
 */
export function rustDeskRelaySheetUsesLargeLayout(sheetContent: number,
  showRelayAdvanced: boolean): boolean {
  return sheetContent === 10 || (sheetContent === 1 && showRelayAdvanced);
}

/**
 * Give the collapsed relay editor enough vertical room for its primary fields
 * without returning to a nearly full-screen sheet. Short/freeform windows are
 * capped to their usable height; Pad/PC windows stop growing at 620 vp.
 */
export function rustDeskRelayCompactEditorHeight(breakpoint: string,
  viewportHeight: number): number {
  let availableHeight: number = viewportHeight;
  if (!Number.isFinite(availableHeight) || availableHeight <= 0) {
    availableHeight = breakpoint === 'sm' ? 800 : 900;
  }
  const outerClearance: number = breakpoint === 'sm' ? 24 : 48;
  const usableHeight: number = Math.max(1, availableHeight - outerClearance);
  const preferredHeight: number = Math.round(availableHeight * (breakpoint === 'sm' ? 0.72 : 0.68));
  return Math.max(1, Math.min(usableHeight, RUSTDESK_RELAY_COMPACT_SHEET_MAX_HEIGHT,
    Math.max(RUSTDESK_RELAY_COMPACT_SHEET_MIN_HEIGHT, preferredHeight)));
}
