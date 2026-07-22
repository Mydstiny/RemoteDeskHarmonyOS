/**
 * RemoteDesktopBackgroundLifecyclePolicy.ets - Ability background flag decisions (T-256)
 */

export enum RemoteDesktopBackgroundAction {
  none = 0,
  detach = 1,
  restore = 2,
  alreadyPreserved = 3
}

export function decideRemoteDesktopBackgroundAction(
  isBackground: boolean,
  connected: boolean,
  sessionId: number,
  restorePending: boolean,
  cleanupStarted: boolean
): RemoteDesktopBackgroundAction {
  if (isBackground) {
    if (connected && sessionId > 0) {
      return RemoteDesktopBackgroundAction.detach;
    }
    if (restorePending && sessionId > 0 && cleanupStarted) {
      return RemoteDesktopBackgroundAction.alreadyPreserved;
    }
    return RemoteDesktopBackgroundAction.none;
  }

  if (restorePending && sessionId > 0) {
    return RemoteDesktopBackgroundAction.restore;
  }
  return RemoteDesktopBackgroundAction.none;
}

/**
 * Page teardown can be observed just before UIAbility.onWillBackground().
 * Keep a connected page alive briefly so the ability lifecycle can classify
 * Home/background navigation before the page performs an explicit disconnect.
 */
export function shouldDeferRemoteDesktopDisappear(
  isBackground: boolean,
  connected: boolean,
  sessionId: number,
  restorePending: boolean,
  cleanupStarted: boolean
): boolean {
  return !isBackground && connected && sessionId > 0 && !restorePending && !cleanupStarted;
}
