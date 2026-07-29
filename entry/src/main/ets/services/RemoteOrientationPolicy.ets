export type RemoteOrientationPolicy = 'auto-rotate' | 'preserve-window';

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
 * RustDesk mobile sessions follow the controller's current window direction.
 * RDP/VNC and desktop-class layouts retain their existing orientation policy.
 * PIP must also retain the system orientation because its renderer is detached
 * from the foreground canvas.
 */
export function rustDeskOrientationPolicy(protocol: string, isDesktopDevice: boolean,
  connected: boolean, renderPreservedInPip: boolean,
  adaptiveOrientationEnabled: boolean = false): RemoteOrientationPolicy {
  if (protocol === 'rustdesk' && !isDesktopDevice && connected && !renderPreservedInPip &&
    adaptiveOrientationEnabled) {
    return 'auto-rotate';
  }
  return 'preserve-window';
}
