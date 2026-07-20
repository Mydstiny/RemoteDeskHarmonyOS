export type SshTerminalOrientation = 'system' | 'portrait' | 'landscape';

export function defaultSshTerminalOrientation(isDesktopDevice: boolean): SshTerminalOrientation {
  return isDesktopDevice ? 'system' : 'portrait';
}

export function toggleSshTerminalOrientation(current: SshTerminalOrientation): SshTerminalOrientation {
  return current === 'landscape' ? 'portrait' : 'landscape';
}
