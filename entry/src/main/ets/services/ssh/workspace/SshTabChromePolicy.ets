export interface SshTabChromeLayout {
  compact: boolean;
  inlineAllowed: boolean;
  tabWidthVp: number;
  pinnedTabWidthVp: number;
  edgeActionsWidthVp: number;
  scrollViewportWidthVp: number;
}

export interface SshTopChromeLayout {
  headerTopInsetVp: number;
  standaloneTabTopInsetVp: number;
  tabStripBelowHeader: boolean;
  totalHeightVp: number;
}

export interface SshHostPickerSheetLayout {
  heightVp: number;
  widthVp: number;
  bottomAnchored: boolean;
}

export const SSH_TAB_CHROME_HORIZONTAL_PADDING_VP: number = 12;
export const SSH_TAB_INLINE_MIN_VIEWPORT_VP: number = 980;
export const SSH_TAB_STRIP_HEIGHT_VP: number = 56;
export const SSH_SESSION_HEADER_BASE_HEIGHT_VP: number = 56;
export const SSH_WORKSPACE_CONTROL_HIT_SIZE_VP: number = 48;
export const SSH_HOST_PICKER_MAX_WIDTH_VP: number = 620;

/** Size the host picker from its rows while keeping it inside the live window. */
export function resolveSshHostPickerSheetLayout(viewportWidthVp: number,
  viewportHeightVp: number, hostCount: number, phone: boolean): SshHostPickerSheetLayout {
  const fallbackWidth: number = phone ? 360 : 800;
  const fallbackHeight: number = phone ? 720 : 640;
  const width: number = Number.isFinite(viewportWidthVp) && viewportWidthVp > 0
    ? viewportWidthVp : fallbackWidth;
  const height: number = Number.isFinite(viewportHeightVp) && viewportHeightVp > 0
    ? viewportHeightVp : fallbackHeight;
  const rows: number = Number.isFinite(hostCount)
    ? Math.max(1, Math.floor(hostCount)) : 1;
  // Title, paddings and one 8vp row gap consume 84vp; each visible host needs
  // a 52vp row plus its 8vp list gap. Longer lists stay scrollable.
  const preferredHeight: number = 84 + rows * 60;
  const edgeMargin: number = phone ? 24 : 48;
  const maximumHeight: number = Math.max(1, height - edgeMargin);
  const minimumHeight: number = Math.min(240, maximumHeight);
  return {
    heightVp: Math.max(minimumHeight, Math.min(preferredHeight, maximumHeight)),
    widthVp: phone ? width : Math.max(1,
      Math.min(SSH_HOST_PICKER_MAX_WIDTH_VP, width - 32)),
    bottomAnchored: phone
  };
}

/** The real header owns the safe inset; a standalone strip follows it. */
export function resolveSshTopChromeLayout(topInsetVp: number,
  standaloneTabsVisible: boolean): SshTopChromeLayout {
  const topInset: number = Number.isFinite(topInsetVp) ? Math.max(0, topInsetVp) : 0;
  return {
    headerTopInsetVp: topInset,
    standaloneTabTopInsetVp: 0,
    tabStripBelowHeader: standaloneTabsVisible,
    totalHeightVp: SSH_SESSION_HEADER_BASE_HEIGHT_VP + topInset +
      (standaloneTabsVisible ? SSH_TAB_STRIP_HEIGHT_VP : 0)
  };
}

export function resolveSshTabChromeLayout(viewportWidthVp: number,
  breakpoint: string): SshTabChromeLayout {
  const width: number = Number.isFinite(viewportWidthVp) ? Math.max(0, viewportWidthVp) : 0;
  const compact: boolean = breakpoint.trim() === 'sm' ||
    (width > 0 && width < SSH_TAB_INLINE_MIN_VIEWPORT_VP);
  // Global actions are consolidated in the page-level menu. Only the strip's
  // horizontal insets remain outside the scrollable tab viewport.
  const edgeActionsWidthVp: number = SSH_TAB_CHROME_HORIZONTAL_PADDING_VP;
  return {
    compact,
    inlineAllowed: !compact,
    tabWidthVp: compact ? 136 : 188,
    pinnedTabWidthVp: compact ? 126 : 164,
    edgeActionsWidthVp,
    scrollViewportWidthVp: Math.max(0, width - edgeActionsWidthVp)
  };
}

export function sshTabWidthVp(compact: boolean, pinned: boolean): number {
  if (pinned) { return compact ? 126 : 164; }
  return compact ? 136 : 188;
}

/** A page-level action menu owns new-session whenever it is available. */
export function sshTabStripShowsStandaloneNewSessionAction(
  headerActionPopupEnabled: boolean): boolean {
  return !headerActionPopupEnabled;
}

/** Every device shape uses one header menu; rollout flags only change menu contents. */
export function sshHeaderUsesSingleActionMenu(_workbenchEnabled: boolean,
  _desktop: boolean, _pad: boolean): boolean {
  return true;
}

/** Compact chrome is an M2 feature and must disappear with its rollout flag. */
export function sshCompactChromeEnabled(workbenchEnabled: boolean,
  viewportWidthVp: number, breakpoint: string): boolean {
  return workbenchEnabled && resolveSshTabChromeLayout(viewportWidthVp, breakpoint).compact;
}
