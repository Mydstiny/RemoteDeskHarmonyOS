export type RdpRendererGeometrySynchronizer = (sessionId: number) => boolean;

/**
 * Re-publish FreeRDP's authoritative desktop after any successful renderer
 * pipeline bind. The bind itself initializes renderer dimensions from the
 * local surface, so skipping this barrier can reopen input with stale source
 * geometry after handoff or background restoration.
 */
export function replayRdpRendererGeometryAfterPipelineBinding(bindingSucceeded: boolean,
  sessionId: number, synchronize: RdpRendererGeometrySynchronizer): boolean {
  if (!bindingSucceeded || !Number.isSafeInteger(sessionId) || sessionId <= 0) {
    return false;
  }
  return synchronize(sessionId);
}
