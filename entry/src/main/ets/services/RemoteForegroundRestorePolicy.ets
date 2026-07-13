export function shouldInvalidateSurfaceAfterBackgroundDetach(rendererHandle: number, sessionId: number): boolean {
  return rendererHandle > 0 && sessionId > 0;
}

export function shouldBindSurfaceBeforeForegroundRenderer(surfaceId: string, width: number, height: number): boolean {
  return surfaceId.trim().length > 0 && width > 0 && height > 0;
}

export function shouldPollSurfaceAfterForegroundRestore(bgRestorePending: boolean, sessionId: number,
  surfaceReady: boolean, cleanupStarted: boolean): boolean {
  return bgRestorePending && sessionId > 0 && !surfaceReady && !cleanupStarted;
}
