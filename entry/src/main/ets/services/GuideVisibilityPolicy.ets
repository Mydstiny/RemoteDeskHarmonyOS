/**
 * Device-local automatic-guide policy.
 *
 * Every distinct guide is shown once by default. The settings override may
 * show it again in later sessions, but never more than once in one live page.
 */
export const GUIDE_ALWAYS_VISIBLE_STORAGE_KEY: string = 'guideAlwaysVisibleV1';
export const SSH_CONTEXTUAL_GUIDE_STORAGE_KEY: string =
  'sshSessionContextualGuideShownV1';
export const MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY: string =
  'moonlightSessionContextualGuideShownV1';

export type RemoteTouchpadGuideProtocol = 'rdp' | 'rustdesk' | 'vnc';

export function remoteTouchpadGuideStorageKey(
  protocol: RemoteTouchpadGuideProtocol
): string {
  if (protocol === 'rdp') { return 'rdpVirtualTouchpadKeyboardGuideShownV1'; }
  if (protocol === 'rustdesk') { return 'rustdeskVirtualTouchpadKeyboardGuideShownV1'; }
  return 'vncVirtualTouchpadKeyboardGuideShownV1';
}

export function isAutomaticGuideMarkerKey(key: string): boolean {
  return key === SSH_CONTEXTUAL_GUIDE_STORAGE_KEY ||
    key === MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY ||
    key === remoteTouchpadGuideStorageKey('rdp') ||
    key === remoteTouchpadGuideStorageKey('rustdesk') ||
    key === remoteTouchpadGuideStorageKey('vnc');
}

export function automaticGuideRuntimeSessionKey(markerKey: string,
  sessionIdentity: string): string {
  const normalizedIdentity: string = sessionIdentity.trim();
  if (!isAutomaticGuideMarkerKey(markerKey) || normalizedIdentity.length === 0) { return ''; }
  return markerKey + '|' + normalizedIdentity;
}

/** Process-local exact-session registry shared across ArkUI page rebuilds. */
export class AutomaticGuideRuntimeSessionRegistry {
  private markers: string[] = [];
  private maxMarkers: number;

  constructor(maxMarkers: number = 128) {
    this.maxMarkers = Number.isSafeInteger(maxMarkers) && maxMarkers > 0 ? maxMarkers : 128;
  }

  wasShown(markerKey: string, sessionIdentity: string): boolean {
    const runtimeKey: string = automaticGuideRuntimeSessionKey(markerKey, sessionIdentity);
    return runtimeKey.length === 0 || this.markers.indexOf(runtimeKey) >= 0;
  }

  markShown(markerKey: string, sessionIdentity: string): boolean {
    const runtimeKey: string = automaticGuideRuntimeSessionKey(markerKey, sessionIdentity);
    if (runtimeKey.length === 0) { return false; }
    if (this.markers.indexOf(runtimeKey) >= 0) { return true; }
    this.markers.push(runtimeKey);
    if (this.markers.length > this.maxMarkers) { this.markers.shift(); }
    return true;
  }
}

export function shouldPresentAutomaticGuide(alreadyShownEver: boolean,
  alwaysVisible: boolean, shownThisSession: boolean): boolean {
  if (shownThisSession) { return false; }
  return alwaysVisible || !alreadyShownEver;
}
