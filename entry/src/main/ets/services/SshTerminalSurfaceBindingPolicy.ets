/**
 * Surface IDs are platform handles, not stable ArkUI view identities.
 * A rebuilt XComponent can reuse the same ID for a different visible binding,
 * so an owner change must reinitialize the native renderer as well.
 */
export const SSH_TERMINAL_PTY_RESIZE_COALESCE_MS: number = 72;

export function makeSshTerminalSurfaceBindingKey(hostId: string, surfaceGeneration: number,
  bindingGeneration: number, sessionId: number): string {
  const normalizedHostId: string = hostId.trim();
  if (normalizedHostId.length === 0 || !Number.isFinite(surfaceGeneration) ||
    !Number.isFinite(bindingGeneration) || !Number.isFinite(sessionId) || sessionId <= 0) {
    return '';
  }
  return normalizedHostId + ':' + Math.floor(surfaceGeneration).toString() + ':' +
    Math.floor(bindingGeneration).toString() + ':' + Math.floor(sessionId).toString();
}

/**
 * ArkUI needs a key that changes for both a new host binding and an explicit
 * surface recovery. Keeping this construction in one policy prevents the
 * native and WebView paths from accidentally observing different revisions.
 */
export function makeSshTerminalSurfaceRenderKey(hostId: string, bindingKey: string,
  renderRevision: number, nativeRenderer: boolean): string {
  const normalizedHostId: string = hostId.trim();
  const normalizedBindingKey: string = bindingKey.trim();
  return normalizedHostId + ':' + normalizedBindingKey + ':' +
    (Number.isFinite(renderRevision) ? Math.floor(renderRevision).toString() : '0') + ':' +
    (nativeRenderer ? 'native' : 'xterm');
}

/**
 * A platform surface ID is not enough to identify the visible renderer. ArkUI
 * can reuse the same ID after replacing the XComponent, so each explicit
 * render revision must also advance the registry owner lease.
 */
export function makeSshTerminalSurfaceOwnerId(surfaceIdentity: string,
  renderRevision: number): string {
  const normalizedIdentity: string = surfaceIdentity.trim();
  if (normalizedIdentity.length === 0) { return ''; }
  const revision: string = Number.isFinite(renderRevision)
    ? Math.floor(renderRevision).toString() : '0';
  return normalizedIdentity + ':render:' + revision;
}

export function shouldRebindSshTerminalSurface(existingSurfaceId: string, nextSurfaceId: string,
  existingOwnerId: string, nextOwnerId: string): boolean {
  const currentSurfaceId: string = existingSurfaceId.trim();
  const requestedSurfaceId: string = nextSurfaceId.trim();
  const currentOwnerId: string = existingOwnerId.trim();
  const requestedOwnerId: string = nextOwnerId.trim();
  return currentSurfaceId.length === 0 || currentSurfaceId !== requestedSurfaceId ||
    (requestedOwnerId.length > 0 && currentOwnerId !== requestedOwnerId);
}
