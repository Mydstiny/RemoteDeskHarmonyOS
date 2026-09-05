/** Pure admission policy for the PC-only RustDesk auxiliary canvas. */

export interface RustDeskMultiCanvasDisplayCandidate {
  display: number;
  width: number;
  height: number;
  originalWidth: number;
  originalHeight: number;
  online: boolean;
}

export interface RustDeskMultiCanvasPreviewDecision {
  accepted: boolean;
  display: number;
  reason: string;
}

export const RUSTDESK_MULTI_CANVAS_MAX_DISPLAYS: number = 2;
export const RUSTDESK_MULTI_CANVAS_MAX_PIXELS: number = 2 * 3840 * 2160;

function displayPixels(display: RustDeskMultiCanvasDisplayCandidate): number {
  const width: number = display.width > 0 ? display.width : display.originalWidth;
  const height: number = display.height > 0 ? display.height : display.originalHeight;
  return width > 0 && height > 0 ? width * height : 0;
}

export function selectRustDeskMultiCanvasPreview(
  desktop: boolean,
  enabled: boolean,
  currentDisplay: number,
  preferredDisplay: number,
  displays: RustDeskMultiCanvasDisplayCandidate[],
  maxPixels: number = RUSTDESK_MULTI_CANVAS_MAX_PIXELS
): RustDeskMultiCanvasPreviewDecision {
  if (!desktop || !enabled) {
    return { accepted: false, display: -1, reason: 'feature_disabled' };
  }
  let focused: RustDeskMultiCanvasDisplayCandidate | null = null;
  let preferred: RustDeskMultiCanvasDisplayCandidate | null = null;
  let fallback: RustDeskMultiCanvasDisplayCandidate | null = null;
  for (const display of displays) {
    if (!display.online || displayPixels(display) <= 0) {
      continue;
    }
    if (display.display === currentDisplay) {
      focused = display;
    } else {
      if (fallback === null) {
        fallback = display;
      }
      if (display.display === preferredDisplay) {
        preferred = display;
      }
    }
  }
  if (focused === null) {
    return { accepted: false, display: -1, reason: 'focused_display_unavailable' };
  }
  const preview: RustDeskMultiCanvasDisplayCandidate | null =
    preferred !== null ? preferred : fallback;
  if (preview === null) {
    return { accepted: false, display: -1, reason: 'preview_display_unavailable' };
  }
  if (displayPixels(focused) + displayPixels(preview) > maxPixels) {
    return { accepted: false, display: -1, reason: 'resource_budget_exceeded' };
  }
  return { accepted: true, display: preview.display, reason: '' };
}
