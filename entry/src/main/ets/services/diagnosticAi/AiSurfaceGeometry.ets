/**
 * Sizes of the AI's surfaces (the island panel, the voice card, the transcript under the voice droplet), shared by
 * both AI styles and every window: phone portrait and landscape (a session), foldables, tablets (also in split
 * screen) and PC windows of any size. All widths are in vp; `w` and `h` are the window's (the AI layer's) size.
 */
export type AiSurfaceDevice = 'phone' | 'pad' | 'pc';

/** Space kept free beside a surface in the narrowest windows. */
const AI_WINDOW_MARGIN: number = 12;

export function aiPhoneLandscape(device: AiSurfaceDevice, w: number, h: number): boolean {
  return device === 'phone' && w > h;
}

/**
 * The phone's scale: from its short side (portrait width), so a phone turned sideways keeps the sizes it has upright.
 * Larger devices keep the reference sizes.
 */
export function aiSurfaceScale(device: AiSurfaceDevice, w: number, h: number): number {
  if (device !== 'phone') { return 1; }
  return Math.min(1.15, Math.max(0.85, Math.min(w, h) / 375));
}

/** Never wider than the window allows (tablet split screen, a small PC window). */
function fit(width: number, w: number): number {
  return Math.max(0, Math.min(width, w - AI_WINDOW_MARGIN * 2));
}

/** The island panel (text mode). */
export function aiPanelWidth(device: AiSurfaceDevice, w: number, h: number): number {
  if (device === 'phone') {
    // Upright: Siri's 12.5 vp margins (scaled), exactly as before — on a narrow phone too (they are never under 10 vp).
    return aiPhoneLandscape(device, w, h) ? fit(Math.min(w - 48, 560), w) : Math.max(0, w - 25 * aiSurfaceScale(device, w, h));
  }
  if (device === 'pad') { return fit(Math.min(Math.max(w - 48, 460), 640), w); }
  return fit(Math.min(Math.max(w - 64, 520), 620), w);
}

/** Voice mode's answer card. */
export function aiVoiceCardWidth(device: AiSurfaceDevice, w: number, h: number): number {
  if (device === 'phone') {
    return aiPhoneLandscape(device, w, h) ? fit(Math.min(w - 48, 560), w) : Math.max(0, w - 25 * aiSurfaceScale(device, w, h));
  }
  return fit(Math.min(Math.max(w - 64, 420), 560), w);
}

/** What is heard, under the listening droplet: as wide as the card, centered. */
export function aiTranscriptWidth(device: AiSurfaceDevice, w: number, h: number): number {
  return Math.min(w - 48, aiVoiceCardWidth(device, w, h));
}

/** The share of the window an open panel may take (it always ends above the keyboard too). */
export function aiPanelHeightShare(device: AiSurfaceDevice, w: number, h: number): number {
  if (aiPhoneLandscape(device, w, h)) { return 0.86; }
  return device === 'phone' ? 0.72 : device === 'pad' ? 0.76 : 0.82;
}

/** The share of the window voice mode's card may take. */
export function aiVoiceCardHeightShare(device: AiSurfaceDevice, w: number, h: number): number {
  return aiPhoneLandscape(device, w, h) ? 0.8 : 0.58;
}

/** Corner radius of the open panel and the voice card: the phone's panel hugs the camera, larger ones are calmer. */
export function aiPanelRadius(device: AiSurfaceDevice, w: number, h: number): number {
  const k: number = aiSurfaceScale(device, w, h);
  return device === 'phone' && !aiPhoneLandscape(device, w, h) ? 46 * k : 38 * k;
}

/**
 * The island's own floating orb after the window changed size (rotation, split screen, a PC window resized): it keeps
 * its side and its relative height, inside the new window. `dragX` is measured from the window's centre, `dragY` from
 * the island's top offset; returns [dragX, dragY].
 */
export function aiReclampOrb(dragX: number, dragY: number, oldW: number, oldH: number, w: number, h: number,
  top: number, orb: number): number[] {
  const half: number = Math.max(0, w / 2 - orb / 2 - 6);
  const oldHalf: number = Math.max(1, oldW / 2 - orb / 2 - 6);
  const x: number = Math.max(-half, Math.min(half, dragX / oldHalf * half));
  const oldSpan: number = Math.max(1, oldH - top - orb - 24);
  const span: number = Math.max(0, h - top - orb - 24);
  const y: number = Math.max(0, Math.min(span, dragY / oldSpan * span));
  return [x, y];
}
