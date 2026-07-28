export type RemoteOrientationPolicy = 'auto-rotate' | 'preserve-window';

/**
 * RustDesk mobile sessions follow the controller's current window direction.
 * RDP/VNC and desktop-class layouts retain their existing orientation policy.
 * PIP must also retain the system orientation because its renderer is detached
 * from the foreground canvas.
 */
export function rustDeskOrientationPolicy(protocol: string, isDesktopDevice: boolean,
  connected: boolean, renderPreservedInPip: boolean): RemoteOrientationPolicy {
  if (protocol === 'rustdesk' && !isDesktopDevice && connected && !renderPreservedInPip) {
    return 'auto-rotate';
  }
  return 'preserve-window';
}
