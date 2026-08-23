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

export function shouldPresentAutomaticGuide(alreadyShownEver: boolean,
  alwaysVisible: boolean, shownThisSession: boolean): boolean {
  if (shownThisSession) { return false; }
  return alwaysVisible || !alreadyShownEver;
}
