/**
 * Decisions for handing a "save and connect" request from the add-host Sheet
 * to the connection preflight Sheet.
 *
 * The native Sheet dismissal callback is the lifecycle boundary.  Keep this
 * policy free of ArkUI state so rapid-click and page-lifecycle regressions can
 * be tested without constructing a page component.
 */
export function shouldAcceptHostAddSave(addSheetClosing: boolean, pendingHostId: string): boolean {
  return !addSheetClosing && pendingHostId.trim().length === 0;
}

export function pendingHostIdForHostAddSave(connectNow: boolean, hostId: string): string {
  return connectNow && hostId.trim().length > 0 ? hostId : '';
}

export function shouldStartHostAddConnectionAfterDisappear(
  pageActive: boolean,
  addSheetClosing: boolean,
  pendingHostId: string
): boolean {
  return pageActive && !addSheetClosing && pendingHostId.trim().length > 0;
}
