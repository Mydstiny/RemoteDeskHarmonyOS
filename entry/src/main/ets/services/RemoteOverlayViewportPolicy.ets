/**
 * Pure placement contract for the session rail and its menus.
 *
 * The caller supplies measured viewport dimensions and real window avoid-area
 * insets. This policy deliberately has no device-specific safe-area guesses;
 * `handleSize`, rail sizes and menu sizes are measured/render tokens, while
 * system/cutout/keyboard/navigation avoidance comes from the caller.
 */

export type OverlayDeviceClass = 'pc' | 'pad' | 'phone';
export type OverlaySide = 'left' | 'right';
export type OverlayOrientation = 'portrait' | 'landscape';
export type OverlayMenuDirection = 'inward-left' | 'inward-right' | 'down' | 'bottom-sheet';
export type OverlayFallback = 'none' | 'collapse' | 'bottom-sheet' | 'hidden';
export type OverlayRecovery = 'none' | 'open-bottom-sheet' | 'retry-after-resize';

export interface OverlayRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface OverlayViewport {
  width: number;
  height: number;
  systemTop: number;
  systemBottom: number;
  systemLeft: number;
  systemRight: number;
  cutoutRects: Array<OverlayRect>;
  keyboardRect: OverlayRect | null;
  orientation: OverlayOrientation;
  deviceClass: OverlayDeviceClass;
  occupiedRects: Array<OverlayRect>;
  generation: number;
}

export interface OverlayPlacementRequest {
  ownerId: string;
  preferredSide: OverlaySide;
  yRatio: number;
  handleSize: number;
  railWidth: number;
  railHeight: number;
  menuWidth: number;
  menuHeight: number;
  expanded: boolean;
}

export interface OverlayPlacement {
  ownerId: string;
  generation: number;
  side: OverlaySide;
  railRect: OverlayRect;
  handleRect: OverlayRect;
  /** Full expanded rail bounds, kept separate from the collapsed handle hit rect. */
  expandedRect: OverlayRect;
  menuRect: OverlayRect;
  menuDirection: OverlayMenuDirection;
  fallback: OverlayFallback;
  /** Explicit recovery affordance when no rail/handle can be safely placed. */
  recovery: OverlayRecovery;
}

export interface OverlayDragPreference {
  side: OverlaySide;
  yRatio: number;
}

export interface OverlayAuxiliaryRequest {
  ownerId: string;
  preferredSide: OverlaySide;
  preferredX: number;
  preferredY: number;
  width: number;
  height: number;
}

export function emptyOverlayPlacement(ownerId: string = '', generation: number = 0): OverlayPlacement {
  return {
    ownerId,
    generation,
    side: 'right',
    railRect: { x: 0, y: 0, width: 0, height: 0 },
    handleRect: { x: 0, y: 0, width: 0, height: 0 },
    expandedRect: { x: 0, y: 0, width: 0, height: 0 },
    menuRect: { x: 0, y: 0, width: 0, height: 0 },
    menuDirection: 'inward-left',
    fallback: 'collapse',
    recovery: 'retry-after-resize'
  };
}

export function normalizeOverlayYRatio(value: number): number {
  if (!Number.isFinite(value)) { return 0.5; }
  return Math.max(0, Math.min(1, value));
}

export function overlayDefaultSide(_deviceClass: OverlayDeviceClass): OverlaySide {
  return 'right';
}

export function overlayPositionPreferenceKey(deviceClass: OverlayDeviceClass,
  orientation: OverlayOrientation, field: 'side' | 'yRatio'): string {
  return 'remoteSessionRail:' + deviceClass + ':' + orientation + ':' + field;
}

/**
 * Convert a measured rail drag to persisted preferences. The caller supplies
 * the actual placement and avoid-area viewport, so the policy never clamps to
 * guessed status/navigation/keyboard constants.
 */
export function resolveOverlayDragPreference(viewport: OverlayViewport,
  placement: OverlayPlacement, offsetX: number, offsetY: number): OverlayDragPreference {
  if (viewport.deviceClass === 'pc' || placement.railRect.width <= 0 ||
    placement.railRect.height <= 0 || viewport.width <= 0 || viewport.height <= 0) {
    return { side: placement.side, yRatio: 0.5 };
  }
  const dx: number = Number.isFinite(offsetX) ? offsetX : 0;
  const dy: number = Number.isFinite(offsetY) ? offsetY : 0;
  const candidateX: number = placement.railRect.x + dx +
    placement.railRect.width / 2;
  const side: OverlaySide = candidateX < viewport.width / 2 ? 'left' : 'right';
  const top: number = safeNumber(viewport.systemTop);
  const keyboardBottom: number = viewport.keyboardRect !== null &&
    rectHasArea(viewport.keyboardRect) ? viewport.keyboardRect.y : viewport.height;
  const bottom: number = Math.min(
    Math.max(top, viewport.height - safeNumber(viewport.systemBottom)), keyboardBottom);
  const maxY: number = Math.max(top, bottom - placement.railRect.height);
  const draggedY: number = placement.railRect.y + dy;
  const y: number = Math.max(top, Math.min(maxY, draggedY));
  return { side, yRatio: normalizeOverlayYRatio(viewport.height > 0 ? y / viewport.height : 0.5) };
}

function safeNumber(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

function rectHasArea(rect: OverlayRect): boolean {
  return rect.width > 0 && rect.height > 0;
}

function rectIntersects(a: OverlayRect, b: OverlayRect): boolean {
  if (!rectHasArea(a) || !rectHasArea(b)) { return false; }
  return a.x < b.x + b.width && a.x + a.width > b.x &&
    a.y < b.y + b.height && a.y + a.height > b.y;
}

function rectInside(rect: OverlayRect, left: number, top: number,
  right: number, bottom: number): boolean {
  return rect.x >= left && rect.y >= top && rect.x + rect.width <= right &&
    rect.y + rect.height <= bottom;
}

function hasObstacle(rect: OverlayRect, obstacles: Array<OverlayRect>): boolean {
  for (let index = 0; index < obstacles.length; index++) {
    if (rectIntersects(rect, obstacles[index])) { return true; }
  }
  return false;
}

function addUnique(values: Array<number>, value: number): void {
  const rounded: number = Math.round(value);
  if (values.indexOf(rounded) < 0) { values.push(rounded); }
}

function buildObstacles(viewport: OverlayViewport): Array<OverlayRect> {
  const obstacles: Array<OverlayRect> = [];
  for (let index = 0; index < viewport.cutoutRects.length; index++) {
    if (rectHasArea(viewport.cutoutRects[index])) { obstacles.push(viewport.cutoutRects[index]); }
  }
  if (viewport.keyboardRect !== null && rectHasArea(viewport.keyboardRect)) {
    obstacles.push(viewport.keyboardRect);
  }
  for (let index = 0; index < viewport.occupiedRects.length; index++) {
    if (rectHasArea(viewport.occupiedRects[index])) { obstacles.push(viewport.occupiedRects[index]); }
  }
  return obstacles;
}

function candidateYPositions(baseY: number, railHeight: number, top: number,
  bottom: number, obstacles: Array<OverlayRect>): Array<number> {
  const maxY: number = Math.max(top, bottom - railHeight);
  const values: Array<number> = [];
  addUnique(values, Math.max(top, Math.min(maxY, baseY)));
  addUnique(values, top);
  addUnique(values, maxY);
  for (let index = 0; index < obstacles.length; index++) {
    const obstacle: OverlayRect = obstacles[index];
    addUnique(values, obstacle.y - railHeight);
    addUnique(values, obstacle.y + obstacle.height);
  }
  return values;
}

function findRail(viewport: OverlayViewport, request: OverlayPlacementRequest,
  side: OverlaySide, left: number, top: number, right: number, bottom: number,
  obstacles: Array<OverlayRect>): OverlayRect | null {
  const width: number = Math.max(request.handleSize, safeNumber(request.railWidth));
  const height: number = Math.max(request.handleSize, safeNumber(request.railHeight));
  const x: number = side === 'left' ? left : right - width;
  const availableHeight: number = Math.max(0, bottom - top - height);
  const baseY: number = top + normalizeOverlayYRatio(request.yRatio) * availableHeight;
  const candidates: Array<number> = candidateYPositions(baseY, height, top, bottom, obstacles);
  for (let index = 0; index < candidates.length; index++) {
    const rail: OverlayRect = { x, y: candidates[index], width, height };
    if (rectInside(rail, left, top, right, bottom) && !hasObstacle(rail, obstacles)) {
      return rail;
    }
  }
  return null;
}

function findPcRail(viewport: OverlayViewport, request: OverlayPlacementRequest,
  left: number, top: number, right: number, bottom: number,
  obstacles: Array<OverlayRect>): OverlayRect | null {
  const width: number = Math.max(request.handleSize, safeNumber(request.railWidth));
  const height: number = Math.max(request.handleSize, safeNumber(request.railHeight));
  const x: number = left + Math.max(0, (right - left - width) / 2);
  const availableHeight: number = Math.max(0, bottom - top - height);
  const baseY: number = top + normalizeOverlayYRatio(request.yRatio) * availableHeight;
  const candidates: Array<number> = candidateYPositions(baseY, height, top, bottom, obstacles);
  for (let index = 0; index < candidates.length; index++) {
    const rail: OverlayRect = { x, y: candidates[index], width, height };
    if (rectInside(rail, left, top, right, bottom) && !hasObstacle(rail, obstacles)) {
      return rail;
    }
  }
  return null;
}

function handleForRail(rail: OverlayRect, side: OverlaySide, handleSize: number): OverlayRect {
  const size: number = Math.max(44, safeNumber(handleSize));
  return {
    x: side === 'left' ? rail.x : rail.x + Math.max(0, rail.width - size),
    y: rail.y + Math.max(0, Math.min(rail.height - size, (rail.height - size) / 2)),
    width: size,
    height: size
  };
}

function bottomSheetRect(viewport: OverlayViewport, left: number, top: number,
  right: number, bottom: number, request: OverlayPlacementRequest): OverlayRect | null {
  const width: number = Math.min(Math.max(0, request.menuWidth), Math.max(0, right - left));
  const height: number = Math.min(Math.max(0, request.menuHeight), Math.max(0, bottom - top));
  if (width <= 0 || height <= 0) { return null; }
  const sheetViewport: OverlayViewport = {
    width: viewport.width,
    height: viewport.height,
    systemTop: viewport.systemTop,
    systemBottom: viewport.systemBottom,
    systemLeft: viewport.systemLeft,
    systemRight: viewport.systemRight,
    cutoutRects: viewport.cutoutRects,
    keyboardRect: null,
    orientation: viewport.orientation,
    deviceClass: viewport.deviceClass,
    occupiedRects: viewport.occupiedRects,
    generation: viewport.generation
  };
  const obstacles: Array<OverlayRect> = buildObstacles(sheetViewport);
  const maxX: number = Math.max(left, right - width);
  const candidates: Array<number> = [];
  addUnique(candidates, left + Math.max(0, (right - left - width) / 2));
  addUnique(candidates, left);
  addUnique(candidates, maxX);
  for (let index = 0; index < obstacles.length; index++) {
    addUnique(candidates, obstacles[index].x - width);
    addUnique(candidates, obstacles[index].x + obstacles[index].width);
  }
  for (let index = 0; index < candidates.length; index++) {
    const rect: OverlayRect = {
      x: candidates[index],
      y: bottom - height,
      width,
      height
    };
    if (rectInside(rect, left, top, right, bottom) && !hasObstacle(rect, obstacles)) {
      return rect;
    }
  }
  return null;
}

function menuForMobile(rail: OverlayRect, side: OverlaySide, viewport: OverlayViewport,
  left: number, top: number, right: number, bottom: number,
  request: OverlayPlacementRequest, obstacles: Array<OverlayRect>): OverlayRect | null {
  const width: number = safeNumber(request.menuWidth);
  const height: number = safeNumber(request.menuHeight);
  const x: number = side === 'left' ? rail.x + rail.width : rail.x - width;
  const menu: OverlayRect = { x, y: rail.y, width, height };
  if (rectInside(menu, left, top, right, bottom) && !hasObstacle(menu, obstacles)) {
    return menu;
  }
  return null;
}

function menuForPc(rail: OverlayRect, viewport: OverlayViewport, left: number, top: number,
  right: number, bottom: number, request: OverlayPlacementRequest,
  obstacles: Array<OverlayRect>): OverlayRect | null {
  const width: number = safeNumber(request.menuWidth);
  const height: number = safeNumber(request.menuHeight);
  const menu: OverlayRect = {
    x: Math.max(left, Math.min(right - width, rail.x + (rail.width - width) / 2)),
    y: rail.y + rail.height,
    width,
    height
  };
  if (rectInside(menu, left, top, right, bottom) && !hasObstacle(menu, obstacles)) {
    return menu;
  }
  return null;
}

export function resolveOverlayPlacement(viewport: OverlayViewport,
  request: OverlayPlacementRequest): OverlayPlacement {
  const result: OverlayPlacement = emptyOverlayPlacement(request.ownerId, viewport.generation);
  const width: number = Math.max(0, safeNumber(viewport.width));
  const height: number = Math.max(0, safeNumber(viewport.height));
  const left: number = Math.min(width, safeNumber(viewport.systemLeft));
  const top: number = Math.min(height, safeNumber(viewport.systemTop));
  const right: number = Math.max(left, width - safeNumber(viewport.systemRight));
  let bottom: number = Math.max(top, height - safeNumber(viewport.systemBottom));
  if (viewport.keyboardRect !== null && rectHasArea(viewport.keyboardRect)) {
    bottom = Math.min(bottom, Math.max(top, viewport.keyboardRect.y));
  }
  const obstacles: Array<OverlayRect> = buildObstacles(viewport);

  if (viewport.deviceClass === 'pc') {
    const pcRequest: OverlayPlacementRequest = {
      ownerId: request.ownerId,
      preferredSide: 'right',
      // Desktop keeps the rail in the safe top slot. The caller still owns
      // the measured system inset; this is not a hard-coded screen y value.
      yRatio: 0,
      handleSize: request.handleSize,
      railWidth: request.railWidth,
      railHeight: request.railHeight,
      menuWidth: request.menuWidth,
      menuHeight: request.menuHeight,
      expanded: request.expanded
    };
    const rail = findPcRail(viewport, pcRequest, left, top, right, bottom, obstacles);
    const fallbackRail: OverlayRect = rail ?? {
      x: Math.max(left, Math.min(right - Math.max(request.handleSize, request.railWidth),
        (left + right - Math.max(request.handleSize, request.railWidth)) / 2)),
      y: top,
      width: Math.max(request.handleSize, request.railWidth),
      height: Math.max(request.handleSize, request.railHeight)
    };
    result.side = 'right';
    if (rail === null) {
      const sheet: OverlayRect | null = request.expanded ?
        bottomSheetRect(viewport, left, top, right, bottom, request) : null;
      if (sheet !== null) {
        result.menuRect = sheet;
        result.menuDirection = 'bottom-sheet';
        result.fallback = 'bottom-sheet';
        result.recovery = 'open-bottom-sheet';
      } else {
        result.fallback = 'hidden';
        result.recovery = 'retry-after-resize';
      }
      return result;
    }
    result.railRect = fallbackRail;
    result.expandedRect = fallbackRail;
    result.handleRect = handleForRail(fallbackRail, 'right', request.handleSize);
    if (!request.expanded) { return result; }
    const menu: OverlayRect | null = menuForPc(fallbackRail, viewport, left, top, right, bottom,
      request, obstacles);
    if (menu !== null) {
      result.menuRect = menu;
      result.menuDirection = 'down';
      result.fallback = 'none';
      result.recovery = 'none';
      return result;
    }
    const sheet: OverlayRect | null = bottomSheetRect(viewport, left, top, right, bottom, request);
    if (sheet !== null) {
      result.menuRect = sheet;
      result.menuDirection = 'bottom-sheet';
      result.fallback = 'bottom-sheet';
      result.recovery = 'open-bottom-sheet';
      return result;
    }
    result.fallback = 'collapse';
    return result;
  }

  const preferred: OverlaySide = request.preferredSide === 'left' ? 'left' : 'right';
  const alternative: OverlaySide = preferred === 'left' ? 'right' : 'left';
  let rail: OverlayRect | null = findRail(viewport, request, preferred, left, top, right, bottom, obstacles);
  let side: OverlaySide = preferred;
  if (rail === null) {
    rail = findRail(viewport, request, alternative, left, top, right, bottom, obstacles);
    side = alternative;
  }
  if (rail === null) {
    const sheet: OverlayRect | null = request.expanded ?
      bottomSheetRect(viewport, left, top, right, bottom, request) : null;
    if (sheet !== null) {
      result.menuRect = sheet;
      result.menuDirection = 'bottom-sheet';
      result.fallback = 'bottom-sheet';
      result.recovery = 'open-bottom-sheet';
    } else {
      result.fallback = 'hidden';
      result.recovery = 'retry-after-resize';
    }
    return result;
  }
  const fallbackRail: OverlayRect = rail;
  result.side = side;
  result.railRect = fallbackRail;
  result.expandedRect = fallbackRail;
  result.handleRect = handleForRail(fallbackRail, side, request.handleSize);
  if (!request.expanded) {
    result.recovery = 'none';
    return result;
  }
  const menu: OverlayRect | null = menuForMobile(fallbackRail, side, viewport, left, top, right, bottom,
    request, obstacles);
  if (menu !== null) {
    result.menuRect = menu;
    result.menuDirection = side === 'left' ? 'inward-right' : 'inward-left';
    result.fallback = 'none';
    result.recovery = 'none';
    return result;
  }
  const sheet: OverlayRect | null = bottomSheetRect(viewport, left, top, right, bottom, request);
  if (sheet !== null) {
    result.menuRect = sheet;
    result.menuDirection = 'bottom-sheet';
    result.fallback = 'bottom-sheet';
    result.recovery = 'open-bottom-sheet';
    return result;
  }
  result.fallback = 'collapse';
  result.recovery = 'retry-after-resize';
  result.menuDirection = 'bottom-sheet';
  return result;
}

/**
 * Resolve a measured auxiliary surface (modifier/diagnostics/transfer) using
 * the same real avoid-area and registry obstacle set as the session rail.
 * Returning null is intentional: the caller must hide the surface and expose
 * its explicit recovery action instead of publishing an intersecting guess.
 */
export function resolveOverlayAuxiliaryRect(viewport: OverlayViewport,
  request: OverlayAuxiliaryRequest): OverlayRect | null {
  const width: number = Math.max(0, safeNumber(request.width));
  const height: number = Math.max(0, safeNumber(request.height));
  const viewportWidth: number = Math.max(0, safeNumber(viewport.width));
  const viewportHeight: number = Math.max(0, safeNumber(viewport.height));
  const left: number = Math.min(viewportWidth, safeNumber(viewport.systemLeft));
  const top: number = Math.min(viewportHeight, safeNumber(viewport.systemTop));
  const right: number = Math.max(left, viewportWidth - safeNumber(viewport.systemRight));
  let bottom: number = Math.max(top, viewportHeight - safeNumber(viewport.systemBottom));
  if (viewport.keyboardRect !== null && rectHasArea(viewport.keyboardRect)) {
    bottom = Math.min(bottom, Math.max(top, viewport.keyboardRect.y));
  }
  if (width <= 0 || height <= 0 || width > right - left || height > bottom - top) {
    return null;
  }
  const obstacles: Array<OverlayRect> = buildObstacles(viewport);
  const xValues: Array<number> = [];
  const yValues: Array<number> = [];
  const addCandidate = (values: Array<number>, value: number): void => {
    if (!Number.isFinite(value)) { return; }
    const clamped: number = Math.max(0, Math.round(value));
    if (values.indexOf(clamped) < 0) { values.push(clamped); }
  };
  addCandidate(xValues, request.preferredX);
  addCandidate(xValues, request.preferredSide === 'left' ? left : right - width);
  addCandidate(xValues, request.preferredSide === 'left' ? right - width : left);
  addCandidate(xValues, left + (right - left - width) / 2);
  addCandidate(yValues, request.preferredY);
  addCandidate(yValues, top);
  addCandidate(yValues, bottom - height);
  for (let index = 0; index < obstacles.length; index++) {
    const obstacle: OverlayRect = obstacles[index];
    addCandidate(xValues, obstacle.x - width);
    addCandidate(xValues, obstacle.x + obstacle.width);
    addCandidate(yValues, obstacle.y - height);
    addCandidate(yValues, obstacle.y + obstacle.height);
  }
  for (let xIndex = 0; xIndex < xValues.length; xIndex++) {
    for (let yIndex = 0; yIndex < yValues.length; yIndex++) {
      const rect: OverlayRect = {
        x: xValues[xIndex], y: yValues[yIndex], width, height
      };
      if (rectInside(rect, left, top, right, bottom) && !hasObstacle(rect, obstacles)) {
        return rect;
      }
    }
  }
  return null;
}
