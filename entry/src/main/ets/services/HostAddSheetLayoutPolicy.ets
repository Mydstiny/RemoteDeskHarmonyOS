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
 * VNC host-add sheets follow the active wizard step's intrinsic height on
 * every device class. Pad/PC retain the established large SSH workspace.
 */
export function resolveHostAddSheetHeightMode(protocol: string,
  breakpoint: string): HostAddSheetHeightMode {
  if (protocol === 'ssh' && breakpoint !== 'sm') {
    return 'large';
  }
  return 'fit';
}

/** Every host-add FAB delegates IME movement and overflow to bindSheet. */
export function resolveHostAddSheetKeyboardAvoidMode(_protocol: string,
  _breakpoint: string): HostAddSheetKeyboardAvoidMode {
  return 'translateAndScroll';
}

/** Every VNC host-add FAB uses one intrinsic content tree on Phone/Pad/PC. */
export function resolveHostAddSheetContentMode(protocol: string,
  _breakpoint: string): HostAddSheetContentMode {
  return protocol === 'vnc' ? 'fitContent' : 'bounded';
}
