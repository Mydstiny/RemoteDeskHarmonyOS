/**
 * VNC startup state policy.
 *
 * Native VNC starts its protocol worker asynchronously.  A newly-created
 * engine can briefly report DISCONNECTED before the worker publishes
 * CONNECTING.  Keep that short window non-terminal, while still treating a
 * real disconnect as failure once the connection has started or the grace
 * period has elapsed.
 */
export const VNC_CONNECTION_STARTUP_GRACE_MS: number = 1000;

export function shouldTreatVncConnectionStateAsTerminal(state: number,
  observedConnecting: boolean, elapsedMs: number): boolean {
  if (state === 4) return true;
  if (state !== 0) return false;
  return observedConnecting || elapsedMs >= VNC_CONNECTION_STARTUP_GRACE_MS;
}
