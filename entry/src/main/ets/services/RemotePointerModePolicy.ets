export function shouldRenderTouchPointerIndicator(indicatorVisible: boolean, keyboardMouseMode: boolean): boolean {
  return indicatorVisible && !keyboardMouseMode;
}

export function shouldUseSystemMousePointer(keyboardMouseMode: boolean): boolean {
  return keyboardMouseMode;
}

/** Phone/Pad virtual touchpads draw their own cursor and own this window's pointer. */
export function shouldHideSystemPointerForVirtualTouchpad(connected: boolean,
  touchpadMode: boolean, isDesktopDevice: boolean): boolean {
  return connected && touchpadMode && !isDesktopDevice;
}
