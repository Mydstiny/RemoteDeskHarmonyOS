/**
 * Layout rules shared by the RustDesk/VNC relay directory.
 *
 * The phone FAB is anchored 120 vp above the viewport bottom and is 56 vp
 * tall. Keep one additional 24 vp tap-safe gap after the final list card.
 */
export const RUSTDESK_RELAY_PHONE_BOTTOM_CLEARANCE: number = 200;
export const RUSTDESK_RELAY_OTHER_BOTTOM_CLEARANCE: number = 120;

export function rustDeskRelayDirectoryBottomClearance(breakpoint: string): number {
  return breakpoint === 'sm' ? RUSTDESK_RELAY_PHONE_BOTTOM_CLEARANCE :
    RUSTDESK_RELAY_OTHER_BOTTOM_CLEARANCE;
}

/**
 * Match the host-add Sheet keyboard contract: only the VNC flow resizes the
 * Sheet on non-phone windows; every other add flow translates and scrolls.
 */
export function rustDeskRelaySheetUsesResizeOnly(sheetContent: number,
  breakpoint: string): boolean {
  return sheetContent === 10 && breakpoint !== 'sm';
}
