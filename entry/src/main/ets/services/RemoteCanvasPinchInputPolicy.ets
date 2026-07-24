/**
 * A recognized ArkUI pinch may consume only the touch stream that produced it.
 * Mouse, pen and touchpad events must continue through their normal input path.
 */
export function shouldConsumeCanvasPinchTouch(inputConsumed: boolean,
  isFingerSource: boolean): boolean {
  return inputConsumed && isFingerSource;
}
