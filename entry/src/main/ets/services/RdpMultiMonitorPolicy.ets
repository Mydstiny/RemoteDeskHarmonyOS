/**
 * RDP 多显示器 (Pro 高级显示, plan 2026-10-09 §4 D0/D1): the monitors this client declares to Windows (2–4 side by side,
 * primary first), the downgrade when the whole desktop would be too large to decode, and the local 「屏幕 1 / 2 / 全部」
 * view, which is a canvas transform that fits one monitor's rectangle (input follows the same transform). Pure; the
 * native adapter applies the same layout rules (freerdp_adapter.cpp, RdpMultimonLayout).
 */
import { CanvasTransform, CanvasViewport, clampCanvasTransform, containScale } from './RemoteCanvasTransformPolicy';

export const RDP_MULTIMON_MAX_COUNT: number = 4;
/** The widest desktop declared (H.264 decoders and textures stay within this). */
export const RDP_MULTIMON_MAX_DESKTOP_WIDTH: number = 8192;
/** About two 4K screens; larger desktops fall back to 1920 × 1080 per monitor. */
export const RDP_MULTIMON_MAX_PIXELS: number = 3840 * 2160 * 2;
export const RDP_MULTIMON_FALLBACK_WIDTH: number = 1920;
export const RDP_MULTIMON_FALLBACK_HEIGHT: number = 1080;
/** No picture this long after connecting with several monitors: offer one screen instead. */
export const RDP_MULTIMON_FIRST_FRAME_TIMEOUT_MS: number = 15000;

export interface RdpMultimonLayout {
  /** 1: a single screen (multi-monitor off or not possible). */
  count: number;
  monitorWidth: number;
  monitorHeight: number;
  desktopWidth: number;
  desktopHeight: number;
  /** The per-monitor size was lowered to fit the limits. */
  downgraded: boolean;
}

export interface RdpMonitorRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** The saved choice: 0 (off) or 2–4 monitors. */
export function normalizeRdpMultimonCount(value: number): number {
  if (!Number.isFinite(value)) { return 0; }
  const count: number = Math.floor(value);
  return count >= 2 ? Math.min(RDP_MULTIMON_MAX_COUNT, count) : 0;
}

function even(value: number): number { return Math.max(2, Math.floor(value / 2) * 2); }

export function rdpMultimonLayout(requestedCount: number, width: number, height: number): RdpMultimonLayout {
  const count: number = normalizeRdpMultimonCount(requestedCount);
  const w: number = Number.isFinite(width) && width >= 200 ? even(width) : RDP_MULTIMON_FALLBACK_WIDTH;
  const h: number = Number.isFinite(height) && height >= 200 ? even(height) : RDP_MULTIMON_FALLBACK_HEIGHT;
  if (count < 2) {
    return { count: 1, monitorWidth: w, monitorHeight: h, desktopWidth: w, desktopHeight: h, downgraded: false };
  }
  const fits = (mw: number, mh: number): boolean =>
    count * mw <= RDP_MULTIMON_MAX_DESKTOP_WIDTH && count * mw * mh <= RDP_MULTIMON_MAX_PIXELS;
  if (fits(w, h)) {
    return { count, monitorWidth: w, monitorHeight: h, desktopWidth: count * w, desktopHeight: h, downgraded: false };
  }
  const fw: number = RDP_MULTIMON_FALLBACK_WIDTH;
  const fh: number = RDP_MULTIMON_FALLBACK_HEIGHT;
  return { count, monitorWidth: fw, monitorHeight: fh, desktopWidth: count * fw, desktopHeight: fh, downgraded: true };
}

/** Monitor rectangles in desktop pixels, left to right; monitor 1 is the primary. */
export function rdpMonitorRects(layout: RdpMultimonLayout): RdpMonitorRect[] {
  const rects: RdpMonitorRect[] = [];
  for (let i = 0; i < layout.count; i++) {
    rects.push({ x: i * layout.monitorWidth, y: 0, width: layout.monitorWidth, height: layout.monitorHeight });
  }
  return rects;
}

/**
 * The canvas transform that shows one monitor as large as the surface allows, centred (null: the whole desktop at
 * its contain size). Rotation is not applied in a multi-monitor session.
 */
export function rdpMonitorFocusTransform(viewport: CanvasViewport, rect: RdpMonitorRect | null): CanvasTransform {
  if (rect === null || rect.width <= 0 || rect.height <= 0) {
    return clampCanvasTransform({ scale: 1, panX: 0, panY: 0, rotation: 0 }, viewport);
  }
  const surfaceWidth: number = Math.max(1, viewport.surfaceWidth);
  const surfaceHeight: number = Math.max(1, viewport.surfaceHeight);
  const physical: number = Math.min(surfaceWidth / rect.width, surfaceHeight / rect.height);
  const fit: number = containScale(viewport);
  return clampCanvasTransform({
    scale: physical / fit,
    panX: (viewport.sourceWidth / 2 - rect.x - rect.width / 2) * physical,
    panY: (viewport.sourceHeight / 2 - rect.y - rect.height / 2) * physical,
    rotation: 0,
    strictContentBounds: false
  }, viewport);
}

/** -1 → 全部, k → 屏幕 k+1. */
export function rdpMonitorLabel(index: number): string {
  return index < 0 ? '全部屏幕' : '屏幕 ' + (index + 1).toString();
}

/** The next view in the toolbar's cycle: 全部 → 屏幕 1 → … → 屏幕 n → 全部. */
export function nextRdpMonitorFocus(current: number, count: number): number {
  if (count < 2) { return -1; }
  return current + 1 >= count ? -1 : current + 1;
}
