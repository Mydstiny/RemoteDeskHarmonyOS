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

export function shouldReloadSshXtermTab(previousCoreKey: string, nextCoreKey: string,
  previousRevision: number, nextRevision: number): boolean {
  return previousCoreKey.trim() !== nextCoreKey.trim() ||
    sshXtermTabRenderRevision(previousRevision) !== sshXtermTabRenderRevision(nextRevision);
}
