/**
 * Host-list connection entry arbitration.
 * A sheet or route may outlive the click that opened it, so both host ID and
 * generation are required before an async result is allowed to mutate state.
 */
export function nextConnectionAttemptGeneration(current: number): number {
  return current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function shouldBeginConnectionAttempt(activeHostId: string): boolean {
  return activeHostId.trim().length === 0;
}

export function shouldApplyConnectionAttempt(activeGeneration: number, resultGeneration: number,
  activeHostId: string, resultHostId: string): boolean {
  return activeGeneration === resultGeneration && activeHostId.length > 0 &&
    activeHostId === resultHostId;
}
