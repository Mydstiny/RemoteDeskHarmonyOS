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

/**
 * Moonlight/Sunshine embeds the authoritative remote cursor in the video
 * frame. Hide HarmonyOS' local pointer only while the physical pointer owns
 * the live stream surface; sheets, rails, background and teardown restore it.
 */
export function shouldHideSystemPointerForEmbeddedRemoteCursor(
  connected: boolean, keyboardMouseMode: boolean, surfaceHovered: boolean,
  interactionBlocked: boolean
): boolean {
  return connected && keyboardMouseMode && surfaceHovered && !interactionBlocked;
}
