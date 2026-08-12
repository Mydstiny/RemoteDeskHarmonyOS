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

export type HostAddPostSaveDestination =
  'none' | 'moonlight_catalog' | 'moonlight_host_detail';

/**
 * Stable-ID handoff for post-save destinations that must wait for the shared
 * add-host Sheet to finish its native dismissal animation.
 *
 * The payload intentionally carries no host snapshot, route object, callback,
 * secret, or protocol state. The destination page must reload the committed
 * local record by ID after this handoff is accepted.
 */
export class HostAddPostSaveHandoff {
  destination: HostAddPostSaveDestination = 'none';
  hostId: string = '';
  ownerToken: number = 0;
  generation: number = 0;
}

export function emptyHostAddPostSaveHandoff(): HostAddPostSaveHandoff {
  return new HostAddPostSaveHandoff();
}

export function hostAddPostSaveHandoffIsPending(
  handoff: HostAddPostSaveHandoff
): boolean {
  return handoff.destination !== 'none' && handoff.hostId.trim().length > 0 &&
    Number.isSafeInteger(handoff.ownerToken) && handoff.ownerToken > 0 &&
    Number.isSafeInteger(handoff.generation) && handoff.generation > 0;
}

export function shouldAcceptHostAddPostSaveHandoff(
  pageActive: boolean,
  addSheetClosing: boolean,
  pending: HostAddPostSaveHandoff,
  currentOwnerToken: number,
  requestOwnerToken: number,
  hostId: string
): boolean {
  return pageActive && !addSheetClosing &&
    !hostAddPostSaveHandoffIsPending(pending) && hostId.trim().length > 0 &&
    Number.isSafeInteger(currentOwnerToken) && currentOwnerToken > 0 &&
    requestOwnerToken === currentOwnerToken;
}

export function shouldCloseHostAddAfterCommittedSave(
  pageActive: boolean,
  addSheetClosing: boolean,
  currentOwnerToken: number,
  requestOwnerToken: number
): boolean {
  return pageActive && !addSheetClosing &&
    Number.isSafeInteger(currentOwnerToken) && currentOwnerToken > 0 &&
    requestOwnerToken === currentOwnerToken;
}

export function createHostAddPostSaveHandoff(
  destination: HostAddPostSaveDestination,
  hostId: string,
  ownerToken: number,
  generation: number
): HostAddPostSaveHandoff {
  const handoff = new HostAddPostSaveHandoff();
  if (destination === 'none' || hostId.trim().length === 0 ||
      !Number.isSafeInteger(ownerToken) || ownerToken <= 0 ||
      !Number.isSafeInteger(generation) || generation <= 0) {
    return handoff;
  }
  handoff.destination = destination;
  handoff.hostId = hostId.trim();
  handoff.ownerToken = ownerToken;
  handoff.generation = generation;
  return handoff;
}

export function shouldStartHostAddPostSaveAfterDisappear(
  pageActive: boolean,
  addSheetClosing: boolean,
  currentOwnerToken: number,
  currentGeneration: number,
  handoff: HostAddPostSaveHandoff,
  expectedDestination: HostAddPostSaveDestination
): boolean {
  return pageActive && !addSheetClosing && expectedDestination !== 'none' &&
    hostAddPostSaveHandoffIsPending(handoff) &&
    handoff.destination === expectedDestination &&
    handoff.ownerToken === currentOwnerToken &&
    handoff.generation === currentGeneration;
}
