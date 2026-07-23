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
 * A controller can be prepared before the first decoded frame exists. This
 * is what lets the system perform the home-gesture auto-start on a cold
 * connection; the actual surface transfer still waits for a real frame.
 */
export function shouldPrepareRemoteSessionPip(
  liveViewEnabled: boolean,
  liveViewMode: number,
  sessionActive: boolean,
  rendererReady: boolean,
  surfaceReady: boolean
): boolean {
  return sessionActive && liveViewEnabled &&
    liveViewMode === LiveViewMode.AVSESSION && rendererReady && surfaceReady;
}

/**
 * Video readiness is protocol-specific. RustDesk owns a decoder pipeline,
 * while RDP presents its FreeRDP GDI frame pump directly into the renderer.
 * Keeping this decision pure prevents the lifecycle page from using a
 * decoder-only shortcut for both protocols.
 */
export function hasRemoteSessionPipVideo(
  protocol: string,
  rendererReady: boolean,
  surfaceReady: boolean,
  decoderReady: boolean,
  rdpFrameReady: boolean
): boolean {
  if (!rendererReady || !surfaceReady) {
    return false;
  }
  if (protocol === 'rdp') {
    return rdpFrameReady;
  }
  return decoderReady;
}

/**
 * GDI readiness is based on an owned pixel buffer, not graphics metadata.
 * Some RDP fallback sessions publish desktop dimensions after the first
 * paint, even though the frame pump can already resubmit that frame to PIP.
 */
export function hasRdpRemoteSessionPipFrame(
  paintCount: number,
  lastRenderBytes: number
): boolean {
  return paintCount > 0 && lastRenderBytes > 0;
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
