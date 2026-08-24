/** Stable identity rules for the retained xterm surface of one SSH tab. */

export function makeSshXtermTabCoreKey(hostId: string): string {
  const normalizedHostId: string = hostId.trim();
  return normalizedHostId.length === 0 ? '' : normalizedHostId + ':xterm';
}

/**
 * A session generation is the only reason a retained tab document should be
 * rebuilt. Switching active tabs must leave this value unchanged.
 */
export function sshXtermTabRenderRevision(sessionGeneration: number): number {
  if (!Number.isFinite(sessionGeneration)) { return 0; }
  return Math.max(0, Math.floor(sessionGeneration));
}

/**
 * A desktop workspace may retain one WebView per tab. Phone/Pad keeps only the
 * visible document mounted; native sessions and bounded transcripts remain
 * retained, but hidden ArkWeb surfaces cannot exhaust or stall touch devices.
 */
export function shouldMountSshXtermTab(isDesktopDevice: boolean,
  visible: boolean): boolean {
  return isDesktopDevice || visible;
}

export function shouldReloadSshXtermTab(previousCoreKey: string, nextCoreKey: string,
  previousRevision: number, nextRevision: number): boolean {
  return previousCoreKey.trim() !== nextCoreKey.trim() ||
    sshXtermTabRenderRevision(previousRevision) !== sshXtermTabRenderRevision(nextRevision);
}

/**
 * A phone/Pad unmounts the hidden ArkWeb surface to keep resource use bounded.
 * Its replacement document is empty even when the native SSH generation is
 * unchanged, so an explicit remount fence must restore the bounded transcript.
 * Desktop retains the original document and only restores on a real revision
 * handoff.
 */
export function shouldRestoreSshXtermTabTranscript(
  previousReadyRevision: number | undefined,
  nextRevision: number,
  touchDocumentRemounted: boolean
): boolean {
  if (touchDocumentRemounted) { return true; }
  return previousReadyRevision !== undefined &&
    sshXtermTabRenderRevision(previousReadyRevision) !==
      sshXtermTabRenderRevision(nextRevision);
}

/** Reject a selection result returned by a replaced/reloaded xterm document. */
export function matchesSshXtermCopyFence(expectedLifecycleToken: number,
  expectedSurfaceIdentity: string, expectedCopyRequest: number,
  currentLifecycleToken: number, currentSurfaceIdentity: string,
  currentCopyRequest: number, resultEligible: boolean): boolean {
  if (!Number.isFinite(expectedLifecycleToken) ||
    Math.floor(expectedLifecycleToken) !== expectedLifecycleToken || expectedLifecycleToken <= 0 ||
    !Number.isFinite(expectedCopyRequest) ||
    Math.floor(expectedCopyRequest) !== expectedCopyRequest || expectedCopyRequest < 0 ||
    !Number.isFinite(currentLifecycleToken) ||
    Math.floor(currentLifecycleToken) !== currentLifecycleToken || currentLifecycleToken <= 0 ||
    !Number.isFinite(currentCopyRequest) ||
    Math.floor(currentCopyRequest) !== currentCopyRequest || currentCopyRequest < 0) {
    return false;
  }
  const expectedSurface: string = expectedSurfaceIdentity.trim();
  return resultEligible && expectedSurface.length > 0 &&
    expectedLifecycleToken === currentLifecycleToken &&
    expectedSurface === currentSurfaceIdentity.trim() &&
    expectedCopyRequest === currentCopyRequest;
}
