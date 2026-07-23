/**
 * Small, side-effect-free publication gate shared by services that keep
 * in-memory mirrors of the RDB.  A cloud callback is allowed to wake a
 * service, but it must not cause a visible redraw when its resulting
 * snapshot is byte-for-byte unchanged.
 */
export function shouldPublishSnapshot(
  hasPublishedSnapshot: boolean, previousSignature: string, nextSignature: string
): boolean {
  return !hasPublishedSnapshot || previousSignature !== nextSignature;
}
