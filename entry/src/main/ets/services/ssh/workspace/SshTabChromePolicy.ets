export interface SshTabChromeLayout {
  compact: boolean;
  inlineAllowed: boolean;
  tabWidthVp: number;
  pinnedTabWidthVp: number;
  edgeActionsWidthVp: number;
  scrollViewportWidthVp: number;
}

export const SSH_TAB_CHROME_HORIZONTAL_PADDING_VP: number = 12;
export const SSH_TAB_INLINE_MIN_VIEWPORT_VP: number = 980;
export const SSH_TAB_STRIP_HEIGHT_VP: number = 56;
export const SSH_WORKSPACE_CONTROL_HIT_SIZE_VP: number = 48;

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
    tabWidthVp: compact ? 124 : 154,
    pinnedTabWidthVp: compact ? 104 : 118,
    edgeActionsWidthVp,
    scrollViewportWidthVp: Math.max(0, width - edgeActionsWidthVp)
  };
}

export function sshTabWidthVp(compact: boolean, pinned: boolean): number {
  if (pinned) { return compact ? 104 : 118; }
  return compact ? 124 : 154;
}

/** A page-level action menu owns new-session whenever it is available. */
export function sshTabStripShowsStandaloneNewSessionAction(
  headerActionPopupEnabled: boolean): boolean {
  return !headerActionPopupEnabled;
}

/** Compact chrome is an M2 feature and must disappear with its rollout flag. */
export function sshCompactChromeEnabled(workbenchEnabled: boolean,
  viewportWidthVp: number, breakpoint: string): boolean {
  return workbenchEnabled && resolveSshTabChromeLayout(viewportWidthVp, breakpoint).compact;
}
