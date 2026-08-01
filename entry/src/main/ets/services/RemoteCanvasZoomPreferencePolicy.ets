/**
 * Version the canvas-zoom default independently from the user's later toggle.
 * Existing installations used a device-dependent default, so the rollout
 * intentionally turns the feature off once and then preserves explicit input.
 */
export const CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION: number = 2;

export interface CanvasGestureZoomPreference {
  enabled: boolean;
  userConfigured: boolean;
  version: number;
}

export function resolveCanvasGestureZoomPreference(storedEnabled: boolean,
  storedVersion: number, storedUserConfigured: boolean): CanvasGestureZoomPreference {
  if (!Number.isFinite(storedVersion) || storedVersion < CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION) {
    return {
      enabled: false,
      userConfigured: false,
      version: CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION
    };
  }
  return {
    enabled: storedEnabled,
    userConfigured: storedUserConfigured,
    version: CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION
  };
}
