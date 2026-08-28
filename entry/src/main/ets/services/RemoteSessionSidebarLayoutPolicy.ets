/** Pure responsive geometry for the in-session mobile/Pad side rail. */

function finitePositive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

export interface RemoteSessionSidebarSystemInsets {
  top: number;
  bottom: number;
}

export interface RemoteSessionSidebarViewport {
  width: number;
  height: number;
}

/**
 * Prefer the window-manager viewport for overlays. XComponent area callbacks
 * can retain portrait width/height after a phone enters forced landscape even
 * though ArkUI has already laid out the window in landscape.
 */
export function remoteSessionSidebarViewport(surfaceWidth: number,
  surfaceHeight: number, windowWidth: number, windowHeight: number,
  forceLandscape: boolean): RemoteSessionSidebarViewport {
  const hasWindowViewport: boolean = Number.isFinite(windowWidth) && windowWidth > 0 &&
    Number.isFinite(windowHeight) && windowHeight > 0;
  let width: number = hasWindowViewport ? windowWidth : finitePositive(surfaceWidth, 360);
  let height: number = hasWindowViewport ? windowHeight : finitePositive(surfaceHeight, 640);
  // A real WindowManager viewport is authoritative, including legal portrait
  // and split-screen windows. Only normalize the XComponent fallback whose
  // axes are known to remain stale after the phone rotation transaction.
  if (!hasWindowViewport && forceLandscape && width < height) {
    const portraitWidth: number = width;
    width = height;
    height = portraitWidth;
  }
  return { width, height };
}

/**
 * Reject orientation-transition avoid-area snapshots that would leave less
 * than one reachable collapsed handle.  HarmonyOS can briefly report the old
 * portrait edge as a near-full-height top inset after entering landscape.
 */
export function remoteSessionSidebarSystemInsets(viewportHeight: number,
  systemTop: number, systemBottom: number,
  minimumReachableHeight: number = 44): RemoteSessionSidebarSystemInsets {
  const height: number = finitePositive(viewportHeight, 640);
  const minimum: number = Math.min(height,
    finitePositive(minimumReachableHeight, 44));
  const top: number = Math.max(0, Number.isFinite(systemTop) ? systemTop : 0);
  const bottom: number = Math.max(0, Number.isFinite(systemBottom) ? systemBottom : 0);
  if (top > height - minimum || bottom > height - minimum ||
    height - top - bottom < minimum) {
    return { top: 0, bottom: 0 };
  }
  return { top, bottom };
}

export function remoteSessionSidebarMenuWidth(viewportWidth: number,
  requestedWidth: number, railWidth: number, itemGap: number): number {
  const viewport: number = finitePositive(viewportWidth, 360);
  const requested: number = finitePositive(requestedWidth, 300);
  const occupied: number = Math.max(44, finitePositive(railWidth, 52)) +
    Math.max(0, Number.isFinite(itemGap) ? itemGap : 0) + 12;
  return Math.min(requested, Math.max(1, viewport - occupied));
}

export function remoteSessionFloatingCardWidth(viewportWidth: number,
  requestedWidth: number, horizontalMargin: number = 12): number {
  const viewport: number = finitePositive(viewportWidth, 360);
  const requested: number = finitePositive(requestedWidth, 360);
  const margin: number = Math.max(0, Number.isFinite(horizontalMargin) ? horizontalMargin : 12);
  return Math.min(requested, Math.max(1, viewport - margin * 2));
}

export function remoteSessionFloatingCardHeight(viewportHeight: number,
  requestedHeight: number, topInset: number = 12, bottomInset: number = 12): number {
  const viewport: number = finitePositive(viewportHeight, 640);
  const requested: number = finitePositive(requestedHeight, 520);
  const top: number = Math.max(0, Number.isFinite(topInset) ? topInset : 12);
  const bottom: number = Math.max(0, Number.isFinite(bottomInset) ? bottomInset : 12);
  return Math.min(requested, Math.max(1, viewport - top - bottom));
}

export function remoteSessionSidebarCanvasHeight(viewportHeight: number): number {
  return Math.max(1, finitePositive(viewportHeight, 640) - 16);
}

export function remoteSessionSidebarVisibleRailHeight(viewportHeight: number,
  contentHeight: number): number {
  return Math.min(remoteSessionSidebarCanvasHeight(viewportHeight),
    finitePositive(contentHeight, 320));
}

export function remoteSessionSidebarMenuMaxHeight(viewportHeight: number,
  topOffset: number): number {
  const available: number = remoteSessionSidebarCanvasHeight(viewportHeight) -
    Math.max(0, Number.isFinite(topOffset) ? topOffset : 0);
  return Math.max(1, available);
}

export function remoteSessionSidebarAnchoredMenuTop(viewportHeight: number,
  anchorTop: number, anchorHeight: number, menuHeight: number,
  edgeMargin: number = 8): number {
  const canvasHeight: number = remoteSessionSidebarCanvasHeight(viewportHeight);
  const margin: number = Math.max(0, Number.isFinite(edgeMargin) ? edgeMargin : 8);
  const safeAnchorTop: number = Number.isFinite(anchorTop) ? anchorTop : margin;
  const safeAnchorHeight: number = finitePositive(anchorHeight, 44);
  const availableHeight: number = Math.max(1, canvasHeight - margin * 2);
  const safeMenuHeight: number = Math.min(finitePositive(menuHeight, 132), availableHeight);
  const centeredTop: number = safeAnchorTop + safeAnchorHeight / 2 - safeMenuHeight / 2;
  return Math.max(margin, Math.min(centeredTop, canvasHeight - margin - safeMenuHeight));
}
