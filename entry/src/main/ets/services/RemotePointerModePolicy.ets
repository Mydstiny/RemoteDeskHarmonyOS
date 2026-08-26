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
  interactionBlocked: boolean, localControlsHovered: boolean = false,
  stableRemoteSurfaceOwner: boolean = false
): boolean {
  return connected && keyboardMouseMode &&
    (surfaceHovered || stableRemoteSurfaceOwner) &&
    !interactionBlocked && !localControlsHovered;
}

/**
 * Sunshine's macOS input backend can leave the host cursor hidden after
 * keyboard input even while absolute pointer packets continue to arrive.
 * Wake it on the first subsequent motion, and also allow a click to recover
 * an already invisible cursor. Rate limiting keeps the common-c wake wiggle
 * out of ordinary high-frequency pointer traffic.
 */
export function shouldWakeEmbeddedMacRemoteCursor(
  macKeyboardTarget: boolean, wakePending: boolean, pointerPress: boolean,
  nowMs: number, lastWakeAttemptAtMs: number, minimumIntervalMs: number
): boolean {
  if (!macKeyboardTarget || (!wakePending && !pointerPress) ||
      !Number.isFinite(nowMs) || !Number.isFinite(lastWakeAttemptAtMs) ||
      !Number.isFinite(minimumIntervalMs) || minimumIntervalMs < 0) {
    return false;
  }
  return lastWakeAttemptAtMs <= 0 || nowMs - lastWakeAttemptAtMs >= minimumIntervalMs;
}
