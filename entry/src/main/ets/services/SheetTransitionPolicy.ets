export const SHEET_DISMISS_GUARD_MS: number = 320;

export function sheetOpenDelayMsAfterDismiss(nowMs: number, lastDismissMs: number): number {
  if (lastDismissMs <= 0 || nowMs <= 0) {
    return 0;
  }
  const elapsed: number = nowMs - lastDismissMs;
  if (elapsed >= SHEET_DISMISS_GUARD_MS) {
    return 0;
  }
  if (elapsed <= 0) {
    return SHEET_DISMISS_GUARD_MS;
  }
  return SHEET_DISMISS_GUARD_MS - elapsed;
}

export function shouldDelaySheetOpen(nowMs: number, lastDismissMs: number): boolean {
  return sheetOpenDelayMsAfterDismiss(nowMs, lastDismissMs) > 0;
}
