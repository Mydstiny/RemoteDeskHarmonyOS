export type HostAddSheetHeightMode = 'fit' | 'large';

/**
 * Phone bottom sheets follow the active wizard step's intrinsic height.
 * Pad/PC retain the established large centered surface for long VNC/SSH
 * forms, where the extra space is intentional.
 */
export function resolveHostAddSheetHeightMode(protocol: string,
  breakpoint: string): HostAddSheetHeightMode {
  const longFlow: boolean = protocol === 'vnc' || protocol === 'ssh';
  if (longFlow && breakpoint !== 'sm') {
    return 'large';
  }
  return 'fit';
}
