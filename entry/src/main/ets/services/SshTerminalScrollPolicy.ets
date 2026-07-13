/**
 * SshTerminalScrollPolicy.ets — SSH 终端手动滚动与自动回底策略。
 */

export function shouldHonorAutoScrollToBottom(isFollowingBottom: boolean): boolean {
  return isFollowingBottom;
}

export function shouldAutoScrollToBottomAfterViewportChange(
  isFollowingBottom: boolean,
  _previousViewportHeight: number,
  _nextViewportHeight: number
): boolean {
  return shouldHonorAutoScrollToBottom(isFollowingBottom);
}

export function terminalDragScrollLines(startY: number, currentY: number, cellHeight: number): number {
  const safeCellHeight: number = Math.max(1, cellHeight);
  return Math.round((currentY - startY) / safeCellHeight);
}

export function terminalTouchDragScrollLines(startY: number, currentY: number, cellHeight: number): number {
  const safeCellHeight: number = Math.max(1, cellHeight);
  return Math.round((startY - currentY) / safeCellHeight);
}

export function terminalTouchSurfaceOffsetY(
  isDesktopDevice: boolean,
  bottomOffset: number,
  virtualKeyBarHeight: number
): number {
  if (isDesktopDevice) { return 0; }
  return -Math.max(0, bottomOffset + virtualKeyBarHeight);
}

export function terminalRowsBottomOffset(
  isDesktopDevice: boolean,
  _keyboardHeight: number,
  navigationHeight: number
): number {
  if (isDesktopDevice) { return 0; }
  return Math.max(0, navigationHeight);
}

export function terminalVisualBottomOffset(
  isDesktopDevice: boolean,
  keyboardHeight: number,
  navigationHeight: number
): number {
  if (isDesktopDevice) { return 0; }
  return Math.max(Math.max(0, keyboardHeight), Math.max(0, navigationHeight));
}

export function terminalLogicalViewportHeight(
  isDesktopDevice: boolean,
  shellAreaHeight: number,
  cellHeight: number,
  bottomOffset: number,
  virtualKeyBarHeight: number
): number {
  const safeShellHeight: number = Math.max(0, shellAreaHeight);
  const minimumHeight: number = Math.max(1, cellHeight) * 3;
  if (isDesktopDevice) {
    return Math.max(minimumHeight, safeShellHeight);
  }
  const obscuredHeight: number = Math.max(0, bottomOffset) + Math.max(0, virtualKeyBarHeight);
  return Math.max(minimumHeight, safeShellHeight - obscuredHeight);
}

export function terminalSparseContentGridTop(
  bottomAlignSparseContent: boolean,
  topInset: number,
  visibleViewportHeight: number,
  contentHeight: number,
  sparseContentMaxHeight: number,
  hasScrollback: boolean
): number {
  const safeTopInset: number = Math.max(0, topInset);
  if (!bottomAlignSparseContent || hasScrollback) {
    return safeTopInset;
  }
  const safeViewportHeight: number = Math.max(0, visibleViewportHeight);
  const safeContentHeight: number = Math.max(0, contentHeight);
  const safeSparseMaxHeight: number = Math.max(0, sparseContentMaxHeight);
  if (safeContentHeight >= safeViewportHeight || safeContentHeight > safeSparseMaxHeight) {
    return safeTopInset;
  }
  return Math.floor(safeTopInset + safeViewportHeight - safeContentHeight);
}

export function terminalGridTop(
  bottomAlignSparseContent: boolean,
  topInset: number,
  visibleViewportHeight: number,
  gridHeight: number,
  contentHeight: number,
  sparseContentMaxHeight: number,
  hasScrollback: boolean
): number {
  const safeTopInset: number = Math.max(0, topInset);
  const safeVisibleHeight: number = Math.max(0, visibleViewportHeight);
  const safeGridHeight: number = Math.max(0, gridHeight);
  const safeContentHeight: number = Math.max(0, contentHeight);
  const safeSparseMaxHeight: number = Math.max(0, sparseContentMaxHeight);
  if (bottomAlignSparseContent && !hasScrollback &&
    safeContentHeight < safeVisibleHeight && safeContentHeight <= safeSparseMaxHeight) {
    return Math.floor(safeTopInset + safeVisibleHeight - safeContentHeight);
  }
  if (safeGridHeight > safeVisibleHeight) {
    return Math.floor(safeTopInset + safeVisibleHeight - safeGridHeight);
  }
  return safeTopInset;
}
