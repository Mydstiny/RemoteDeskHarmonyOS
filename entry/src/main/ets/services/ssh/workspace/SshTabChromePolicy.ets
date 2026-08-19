export interface SshTabChromeLayout {
  compact: boolean;
  inlineAllowed: boolean;
  tabWidthVp: number;
  pinnedTabWidthVp: number;
  edgeActionsWidthVp: number;
  scrollViewportWidthVp: number;
}

export const SSH_TAB_EDGE_ACTION_COUNT: number = 4;
export const SSH_TAB_EDGE_ACTION_SIZE_VP: number = 34;
export const SSH_TAB_EDGE_ACTION_GAP_VP: number = 6;
export const SSH_TAB_CHROME_HORIZONTAL_PADDING_VP: number = 12;
export const SSH_TAB_INLINE_MIN_VIEWPORT_VP: number = 980;

export function resolveSshTabChromeLayout(viewportWidthVp: number,
  breakpoint: string): SshTabChromeLayout {
  const width: number = Number.isFinite(viewportWidthVp) ? Math.max(0, viewportWidthVp) : 0;
  const compact: boolean = breakpoint.trim() === 'sm' ||
    (width > 0 && width < SSH_TAB_INLINE_MIN_VIEWPORT_VP);
  const edgeActionsWidthVp: number = SSH_TAB_EDGE_ACTION_COUNT * SSH_TAB_EDGE_ACTION_SIZE_VP +
    (SSH_TAB_EDGE_ACTION_COUNT - 1) * SSH_TAB_EDGE_ACTION_GAP_VP +
    SSH_TAB_CHROME_HORIZONTAL_PADDING_VP;
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

/** Compact chrome is an M2 feature and must disappear with its rollout flag. */
export function sshCompactChromeEnabled(workbenchEnabled: boolean,
  viewportWidthVp: number, breakpoint: string): boolean {
  return workbenchEnabled && resolveSshTabChromeLayout(viewportWidthVp, breakpoint).compact;
}
