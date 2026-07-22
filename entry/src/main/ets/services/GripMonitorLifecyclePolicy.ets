export function shouldRestartGripMonitor(
  pageActive: boolean,
  monitorRegistered: boolean,
  permissionGranted: boolean
): boolean {
  return pageActive && permissionGranted && !monitorRegistered;
}

export function shouldRebindGripMonitorOnPageShow(
  pageActive: boolean,
  permissionGranted: boolean,
  monitorRegistered: boolean
): boolean {
  return pageActive && permissionGranted && monitorRegistered;
}

export function shouldIgnoreActivityMotionForHoldingHand(
  detectGestureGranted: boolean,
  _activityMotionGranted: boolean
): boolean {
  return detectGestureGranted;
}

export function shouldFallbackToOperatingHandOnSubscribeFailure(errorCode: number): boolean {
  return errorCode === 801 || errorCode === 31500002;
}

export function shouldMarkGripMonitorStaleAfterWatchdog(
  pageActive: boolean,
  monitorRegistered: boolean,
  callbackCount: number
): boolean {
  return pageActive && monitorRegistered && callbackCount <= 0;
}

export function holdingHandStatusFromOperatingHandStatus(
  operatingHandStatus: number,
  currentHoldingHandStatus: number
): number {
  if (operatingHandStatus === 1) {
    return 1;
  }
  if (operatingHandStatus === 2) {
    return 2;
  }
  return currentHoldingHandStatus;
}

export function shouldUseGripFabAlignment(isDesktopDevice: boolean, _breakpoint: string): boolean {
  return !isDesktopDevice;
}

export function shouldUseGripMonitor(isDesktopDevice: boolean): boolean {
  return !isDesktopDevice;
}

export function shouldRunForegroundSensor(
  pageActive: boolean,
  appInBackground: boolean,
  featureEnabled: boolean
): boolean {
  return pageActive && !appInBackground && featureEnabled;
}

/**
 * The holding-hand permission is an optional enhancement, not a prerequisite
 * for rendering the host list. Request it once after the first frame is
 * allowed to render, and never schedule a duplicate dialog while a request is
 * already running.
 */
export function shouldAutoRequestGripPermission(
  pageActive: boolean,
  appInBackground: boolean,
  isDesktopDevice: boolean,
  featureEnabled: boolean,
  permissionGranted: boolean,
  requestAttempted: boolean,
  requestInFlight: boolean
): boolean {
  return pageActive && !appInBackground && !isDesktopDevice && featureEnabled &&
    !permissionGranted && !requestAttempted && !requestInFlight;
}
