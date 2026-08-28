export type RemoteOrientationPolicy = 'auto-rotate' | 'landscape' | 'preserve-window';

export type RustDeskTargetDevice = 'computer' | 'phone';

export function normalizeRustDeskTargetDevice(value: string): RustDeskTargetDevice {
  return value === 'phone' ? 'phone' : 'computer';
}

/** RustDesk Pro platform names are server-provided and may vary by version. */
export function isRustDeskMobilePlatform(platform: string): boolean {
  const normalized: string = platform.trim().toLowerCase();
  return normalized.indexOf('android') >= 0 || normalized.indexOf('ios') >= 0 ||
    normalized.indexOf('iphone') >= 0 || normalized.indexOf('ipad') >= 0 ||
    normalized.indexOf('harmony') >= 0 || normalized.indexOf('mobile') >= 0 ||
    normalized.indexOf('phone') >= 0 || normalized.indexOf('tablet') >= 0;
}

/** Authenticated peer category wins; local target type is a handshake fallback. */
export function isRustDeskPhoneSessionForPeer(targetDevice: string,
  peerPlatform: string): boolean {
  const normalized: string = peerPlatform.trim().toLowerCase();
  if (normalized === 'android' || normalized === 'ios') {
    return true;
  }
  if (normalized === 'windows' || normalized === 'macos' || normalized === 'linux') {
    return false;
  }
  return normalizeRustDeskTargetDevice(targetDevice) === 'phone';
}

/**
 * Adaptive orientation is an explicit per-host opt-in. Pro records with a
 * known desktop platform are rejected here even if an old local value says
 * otherwise, so a platform refresh cannot re-enable rotation accidentally.
 */
export function canUseRustDeskAdaptiveOrientation(protocol: string, targetDevice: string,
  enabled: boolean, sourceType: string = '', proManaged: boolean = false,
  proPlatform: string = ''): boolean {
  if (protocol !== 'rustdesk' || !enabled || normalizeRustDeskTargetDevice(targetDevice) !== 'phone') {
    return false;
  }
  if (sourceType === 'rustdesk_pro' && proManaged && proPlatform.trim() !== '' &&
    !isRustDeskMobilePlatform(proPlatform)) {
    return false;
  }
  return true;
}

/**
 * RustDesk mobile sessions use the controller's current window direction while
 * a session is active or being prepared. RDP/VNC and desktop-class layouts
 * retain their existing orientation policy. PIP must also retain the system
 * orientation because its renderer is detached from the foreground canvas.
 */
export function rustDeskOrientationPolicy(protocol: string, isDesktopDevice: boolean,
  connected: boolean, renderPreservedInPip: boolean,
  adaptiveOrientationEnabled: boolean = false, sessionPending: boolean = false): RemoteOrientationPolicy {
  if (protocol === 'rustdesk' && !isDesktopDevice && (connected || sessionPending) &&
    !renderPreservedInPip) {
    return adaptiveOrientationEnabled ? 'auto-rotate' : 'landscape';
  }
  return 'preserve-window';
}
