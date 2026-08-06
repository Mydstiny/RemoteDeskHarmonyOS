export const SHEET_DISMISS_GUARD_MS: number = 320;

// SFTP lives on the SSH route while the add-host sheet lives on the host-list
// route. A mobile back navigation can briefly keep both native sheet hosts
// alive, so retain only the handoff timestamp in process memory.
let lastSshSftpSheetDismissAtMs: number = 0;

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

export function noteSshSftpSheetDismissed(nowMs: number): void {
  if (nowMs > 0) {
    lastSshSftpSheetDismissAtMs = nowMs;
  }
}

export function sshSftpSheetOpenDelayMs(nowMs: number): number {
  return sheetOpenDelayMsAfterDismiss(nowMs, lastSshSftpSheetDismissAtMs);
}
