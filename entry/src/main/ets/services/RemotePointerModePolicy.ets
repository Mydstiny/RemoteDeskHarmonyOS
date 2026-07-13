export function shouldRenderTouchPointerIndicator(indicatorVisible: boolean, keyboardMouseMode: boolean): boolean {
  return indicatorVisible && !keyboardMouseMode;
}

export function shouldUseSystemMousePointer(keyboardMouseMode: boolean): boolean {
  return keyboardMouseMode;
}
