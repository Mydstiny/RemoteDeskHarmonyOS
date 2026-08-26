export interface FloatingPanelRect {
  x: number;
  y: number;
}

export interface FloatingPanelViewport {
  width: number;
  height: number;
  topMargin: number;
  bottomMargin: number;
  sideMargin: number;
}

function finitePositive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/**
 * Resolve the unified modifier/shortcut panel width from the real session
 * viewport. Phone sessions use the same roomy 320vp target as Moonlight
 * instead of inheriting a stale pre-rotation `sm` breakpoint.
 */
export function remoteModifierPanelWidth(breakpoint: string, viewportWidth: number,
  roomyPhoneLayout: boolean = false): number {
  let preferred: number = 260;
  if (roomyPhoneLayout || breakpoint === 'xl') {
    preferred = 320;
  } else if (breakpoint === 'lg') {
    preferred = 300;
  } else if (breakpoint === 'md') {
    preferred = 280;
  }
  return Math.max(1, Math.min(preferred,
    finitePositive(viewportWidth, preferred + 16) - 16));
}

/** Height that can actually contain a panel after safe-area and IME margins. */
export function floatingPanelAvailableHeight(viewport: FloatingPanelViewport): number {
  const height: number = finitePositive(viewport.height, 640);
  const top: number = Math.max(0, viewport.topMargin);
  const bottom: number = Math.max(0, viewport.bottomMargin);
  return Math.max(1, height - top - bottom);
}

export function floatingPanelOrientationSuffix(width: number, height: number): string {
  return finitePositive(width, 1) >= finitePositive(height, 1) ? 'Landscape' : 'Portrait';
}

export function clampFloatingPanel(x: number, y: number, panelWidth: number, panelHeight: number,
  viewport: FloatingPanelViewport): FloatingPanelRect {
  const width: number = finitePositive(viewport.width, 360);
  const height: number = finitePositive(viewport.height, 640);
  const side: number = Math.max(0, viewport.sideMargin);
  const top: number = Math.max(0, viewport.topMargin);
  const bottom: number = Math.max(0, viewport.bottomMargin);
  const measuredWidth: number = finitePositive(panelWidth, 260);
  const measuredHeight: number = finitePositive(panelHeight, 136);
  const maxX: number = Math.max(side, width - side - measuredWidth);
  const maxY: number = Math.max(top, height - bottom - measuredHeight);
  return {
    x: Math.max(side, Math.min(Number.isFinite(x) ? x : side, maxX)),
    y: Math.max(top, Math.min(Number.isFinite(y) ? y : top, maxY))
  };
}

export function anchorFloatingPanelToHandle(handleSide: string, handleY: number,
  panelWidth: number, panelHeight: number, viewport: FloatingPanelViewport): FloatingPanelRect {
  const width: number = finitePositive(viewport.width, 360);
  const side: number = Math.max(0, viewport.sideMargin);
  const x: number = handleSide === 'left' ? side : width - side - finitePositive(panelWidth, 260);
  return clampFloatingPanel(x, handleY - 20, panelWidth, panelHeight, viewport);
}

function fullyVisible(x: number, y: number, panelWidth: number, panelHeight: number,
  viewport: FloatingPanelViewport): boolean {
  return x >= viewport.sideMargin &&
    y >= viewport.topMargin &&
    x + panelWidth <= viewport.width - viewport.sideMargin &&
    y + panelHeight <= viewport.height - viewport.bottomMargin;
}

function overlapArea(firstX: number, firstY: number, firstWidth: number, firstHeight: number,
  secondX: number, secondY: number, secondWidth: number, secondHeight: number): number {
  const width: number = Math.max(0,
    Math.min(firstX + firstWidth, secondX + secondWidth) - Math.max(firstX, secondX));
  const height: number = Math.max(0,
    Math.min(firstY + firstHeight, secondY + secondHeight) - Math.max(firstY, secondY));
  return width * height;
}

export function placeFloatingCompanion(primaryX: number, primaryY: number,
  primaryWidth: number, primaryHeight: number, companionWidth: number, companionHeight: number,
  viewport: FloatingPanelViewport, gap: number = 12): FloatingPanelRect {
  const candidates: FloatingPanelRect[] = [
    { x: primaryX + primaryWidth + gap, y: primaryY },
    { x: primaryX - companionWidth - gap, y: primaryY },
    { x: primaryX, y: primaryY + primaryHeight + gap },
    { x: primaryX, y: primaryY - companionHeight - gap }
  ];
  for (let i = 0; i < candidates.length; i++) {
    if (fullyVisible(candidates[i].x, candidates[i].y, companionWidth, companionHeight, viewport)) {
      return candidates[i];
    }
  }
  const maxX: number = Math.max(viewport.sideMargin,
    viewport.width - viewport.sideMargin - companionWidth);
  const maxY: number = Math.max(viewport.topMargin,
    viewport.height - viewport.bottomMargin - companionHeight);
  const fallbackCandidates: FloatingPanelRect[] = [
    clampFloatingPanel(candidates[0].x, candidates[0].y, companionWidth, companionHeight, viewport),
    clampFloatingPanel(candidates[1].x, candidates[1].y, companionWidth, companionHeight, viewport),
    clampFloatingPanel(candidates[2].x, candidates[2].y, companionWidth, companionHeight, viewport),
    clampFloatingPanel(candidates[3].x, candidates[3].y, companionWidth, companionHeight, viewport),
    { x: viewport.sideMargin, y: viewport.topMargin },
    { x: maxX, y: viewport.topMargin },
    { x: viewport.sideMargin, y: maxY },
    { x: maxX, y: maxY }
  ];
  let best: FloatingPanelRect = fallbackCandidates[0];
  let bestOverlap: number = overlapArea(primaryX, primaryY, primaryWidth, primaryHeight,
    best.x, best.y, companionWidth, companionHeight);
  for (let i = 1; i < fallbackCandidates.length; i++) {
    const candidate: FloatingPanelRect = fallbackCandidates[i];
    const candidateOverlap: number = overlapArea(primaryX, primaryY, primaryWidth, primaryHeight,
      candidate.x, candidate.y, companionWidth, companionHeight);
    if (candidateOverlap < bestOverlap) {
      best = candidate;
      bestOverlap = candidateOverlap;
    }
  }
  return best;
}
