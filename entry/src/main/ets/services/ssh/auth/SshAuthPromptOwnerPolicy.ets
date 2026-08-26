/**
 * Resolve the native SSH identity whose keyboard-interactive broker belongs
 * to the current page. Detached desktop pre-authentication deliberately does
 * not publish its reserved id through the legacy foreground facade, so its
 * page-owned pending identity must take precedence while connectSshAsync is
 * still unsettled.
 */
export function resolveSshAuthPromptSessionId(
  pendingSessionId: number,
  facadeSessionId: number,
  attachedSessionId: number
): number {
  if (pendingSessionId > 0) { return pendingSessionId; }
  if (facadeSessionId > 0) { return facadeSessionId; }
  return attachedSessionId > 0 ? attachedSessionId : 0;
}

/** Use the generation paired with the selected owner before diagnostics. */
export function resolveSshAuthPromptGeneration(
  sessionId: number,
  pendingSessionId: number,
  pendingGeneration: number,
  attachedSessionId: number,
  attachedGeneration: number,
  diagnosticGeneration: number
): number {
  if (sessionId <= 0) { return 0; }
  if (sessionId === pendingSessionId && pendingGeneration > 0) {
    return pendingGeneration;
  }
  if (sessionId === attachedSessionId && attachedGeneration > 0) {
    return attachedGeneration;
  }
  return diagnosticGeneration > 0 ? diagnosticGeneration : 0;
}
