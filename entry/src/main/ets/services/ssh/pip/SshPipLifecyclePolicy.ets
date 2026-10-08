/** After the app returns to the front or a PiP cycle ends, wait this long before arming the next PiP. */
export const SSH_PIP_REARM_DELAY_MS: number = 400;

/** Maximum time an explicit page exit waits for the PiP stop callback. */
export const SSH_PIP_EXIT_GRACE_MS: number = 800;

/** Independent SSH windows never own the phone PiP controller. */
export function shouldCoordinateSshPipExit(
  sessionWindowId: string,
  pipPreparedOrPreparing: boolean
): boolean {
  return sessionWindowId.trim().length === 0 && pipPreparedOrPreparing;
}

/** Prevent a late PiP callback from navigating a reused or closing page. */
export function matchesSshPipExitFence(
  expectedPageGeneration: number,
  currentPageGeneration: number,
  explicitSessionClose: boolean,
  terminalClosing: boolean
): boolean {
  return Number.isInteger(expectedPageGeneration) && expectedPageGeneration > 0 &&
    expectedPageGeneration === currentPageGeneration &&
    explicitSessionClose && !terminalClosing;
}
