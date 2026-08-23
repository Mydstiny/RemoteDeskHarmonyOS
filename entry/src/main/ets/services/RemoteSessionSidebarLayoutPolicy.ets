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
  return Math.min(requested, Math.max(180, viewport - occupied));
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
