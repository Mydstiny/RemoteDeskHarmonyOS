/** Fixed-attempt drain policy; independent of wall-clock adjustments. */
export const RDP_PREFLIGHT_DRAIN_POLL_INTERVAL_MS: number = 20;

export function rdpPreflightDrainMaximumPolls(
  timeoutMs: number,
  pollIntervalMs: number = RDP_PREFLIGHT_DRAIN_POLL_INTERVAL_MS
): number {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 ||
    !Number.isSafeInteger(pollIntervalMs) || pollIntervalMs <= 0) {
    return 0;
  }
  // One immediate observation plus a bounded number of delayed observations.
  return Math.ceil(timeoutMs / pollIntervalMs) + 1;
}
