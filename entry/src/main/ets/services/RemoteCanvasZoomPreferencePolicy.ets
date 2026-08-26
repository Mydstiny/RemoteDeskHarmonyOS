/**
 * Version the canvas-zoom default independently from the user's later toggle.
 * Existing installations used a device-dependent default. A stored value is
 * user state and must survive an update; only a genuinely missing value takes
 * the 1.1.1 clean-install default.
 */
export const CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION: number = 2;

export interface CanvasGestureZoomPreference {
  enabled: boolean;
  userConfigured: boolean;
  version: number;
}

export function resolveCanvasGestureZoomPreference(storedEnabled: boolean,
  _storedVersion: number, storedUserConfigured: boolean,
  storedPreferencePresent: boolean = true, missingPreferenceDefault: boolean = false
): CanvasGestureZoomPreference {
  return {
    enabled: storedPreferencePresent ? storedEnabled : missingPreferenceDefault,
    userConfigured: storedPreferencePresent ? storedUserConfigured : false,
    version: CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION
  };
}
