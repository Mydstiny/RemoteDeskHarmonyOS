export interface CanvasGestureOwnership {
  pinchActive: boolean;
  panActive: boolean;
}

export function endCanvasPinchOwnership(state: CanvasGestureOwnership): CanvasGestureOwnership {
  return { pinchActive: false, panActive: state.panActive };
}

export function endCanvasPanOwnership(state: CanvasGestureOwnership): CanvasGestureOwnership {
  return { pinchActive: state.pinchActive, panActive: false };
}

export function shouldReleaseCanvasGestureOwnership(state: CanvasGestureOwnership): boolean {
  return !state.pinchActive && !state.panActive;
}
