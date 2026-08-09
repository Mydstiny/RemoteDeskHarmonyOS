/**
 * VNC renderer startup must be tied to the current ArkUI Surface.  The native
 * renderer can still initialize an off-screen Pbuffer when no window exists;
 * that is not a valid VNC presentation target, so the caller must wait for a
 * real, currently bound SurfaceId instead.
 */
export function isVncRendererSurfaceReady(surfaceReady: boolean, surfaceId: string): boolean {
  return surfaceReady && surfaceId.trim().length > 0;
}

export function shouldDeferVncRendererUntilSurface(
  isVnc: boolean,
  surfaceReady: boolean,
  surfaceId: string,
  restoreInProgress: boolean,
  cleanupStarted: boolean
): boolean {
  if (!isVnc || restoreInProgress || cleanupStarted) {
    return false;
  }
  return !isVncRendererSurfaceReady(surfaceReady, surfaceId);
}
