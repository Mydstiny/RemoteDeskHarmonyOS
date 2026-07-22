/**
 * RemoteSessionLiveViewPolicy.ets — remote-session background presentation.
 *
 * A third-party remote-session app cannot create the system LIVE_VIEW
 * notification directly. The notification choice therefore means a normal
 * background notification; only AVSession is used as a media capsule.
 */
import { LiveViewMode } from './LiveViewTypes';

export enum RemoteSessionLiveViewDelivery {
  NONE = 0,
  AVSESSION = 1,
  BACKGROUND_NOTIFICATION = 2
}

export function resolveRemoteSessionLiveViewDelivery(
  enabled: boolean,
  preferredMode: number,
  hasAudio: boolean,
  hasVideo: boolean
): RemoteSessionLiveViewDelivery {
  if (!enabled || preferredMode === LiveViewMode.OFF) {
    return RemoteSessionLiveViewDelivery.NONE;
  }
  if (preferredMode === LiveViewMode.AVSESSION && (hasAudio || hasVideo)) {
    return RemoteSessionLiveViewDelivery.AVSESSION;
  }
  return RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION;
}
