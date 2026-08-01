/** Renderer snapshot acceptance contract for ArkTS coordinate mapping. */
export function shouldAcceptRendererViewportSnapshot(pendingVersion: number,
  nativeVersion: number): boolean {
  const pending: number = Number.isFinite(pendingVersion) && pendingVersion > 0 ? pendingVersion : 0;
  const native: number = Number.isFinite(nativeVersion) && nativeVersion > 0 ? nativeVersion : 0;
  return native >= pending;
}
