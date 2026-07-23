import { LiveViewMode } from './LiveViewTypes';

/**
 * PIP lifecycle actions are deliberately separated from the background
 * callback. A controller must be prepared while the main window is shown;
 * once the window is hidden the system owns the auto-start transition.
 */
export enum RemoteSessionPipLifecycleAction {
  DISABLE = 0,
  PREPARE = 1,
  WAIT_FOR_AUTO_START = 2
}

export interface RemoteSessionPipContentSize {
  width: number;
  height: number;
}

/**
 * PIP content dimensions describe the remote video, not the local XComponent
 * surface. The latter can be a rotated physical display size on phones.
 */
export function resolveRemoteSessionPipContentSize(
  sourceWidth: number,
  sourceHeight: number,
  remoteWidth: number,
  remoteHeight: number
): RemoteSessionPipContentSize {
  const hasSource: boolean = sourceWidth > 0 && sourceHeight > 0;
  const width: number = hasSource ? sourceWidth : (remoteWidth > 0 ? remoteWidth : 1920);
  const height: number = hasSource ? sourceHeight : (remoteHeight > 0 ? remoteHeight : 1080);
  return {
    width: Math.max(2, Math.round(width)),
    height: Math.max(2, Math.round(height))
  };
}

export function resolveRemoteSessionPipLifecycle(
  liveViewEnabled: boolean,
  liveViewMode: number,
  hasVideo: boolean,
  sessionActive: boolean,
  appBackgrounded: boolean,
  mainWindowShown: boolean
): RemoteSessionPipLifecycleAction {
  if (!sessionActive || !liveViewEnabled || liveViewMode !== LiveViewMode.AVSESSION || !hasVideo) {
    return RemoteSessionPipLifecycleAction.DISABLE;
  }
  if (!appBackgrounded && mainWindowShown) {
    return RemoteSessionPipLifecycleAction.PREPARE;
  }
  return RemoteSessionPipLifecycleAction.WAIT_FOR_AUTO_START;
}
