export type HostAddSheetHeightMode = 'fit' | 'large';
export type HostAddSheetKeyboardAvoidMode = 'resize' | 'translateAndScroll';
export type HostAddSheetContentMode = 'fitContent' | 'bounded';

/** Resolve modern and classic FAB routes before applying layout policy. */
export function resolveActiveHostAddProtocol(modernProtocol: string,
  classicProtocol: string, showsModernPicker: boolean): string {
  if (showsModernPicker) {
    return '';
  }
  return modernProtocol !== '' ? modernProtocol : classicProtocol;
}

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

/**
 * Phone VNC uses the same system-owned IME translation as the other FAB
 * forms. Bounded Pad/PC VNC sheets keep their internal scroll viewport.
 */
export function resolveHostAddSheetKeyboardAvoidMode(protocol: string,
  breakpoint: string): HostAddSheetKeyboardAvoidMode {
  if (protocol === 'vnc' && breakpoint !== 'sm') {
    return 'resize';
  }
  return 'translateAndScroll';
}

/** Only the phone VNC host-add flow opts into the intrinsic scaffold. */
export function resolveHostAddSheetContentMode(protocol: string,
  breakpoint: string): HostAddSheetContentMode {
  return protocol === 'vnc' && breakpoint === 'sm' ? 'fitContent' : 'bounded';
}
