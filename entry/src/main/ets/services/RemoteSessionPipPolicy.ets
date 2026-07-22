import { LiveViewMode } from './LiveViewTypes';

/**
 * PIP is the actual remote-frame window.  It is only paired with the media
 * presentation choice and a real video stream; a notification-only choice
 * must never unexpectedly take over the screen with a PIP window.
 */
export function shouldStartRemoteSessionPip(
  liveViewEnabled: boolean,
  liveViewMode: number,
  hasVideo: boolean,
  sessionActive: boolean
): boolean {
  return sessionActive && liveViewEnabled && liveViewMode === LiveViewMode.AVSESSION && hasVideo;
}
