/** Pure responsive geometry for the in-session mobile/Pad side rail. */

function finitePositive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
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
  return Math.max(120, finitePositive(viewportHeight, 640) - 16);
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
  return Math.max(120, available);
}
