/**
 * 前台恢复后的画面刷新策略。
 * 退后台期间 renderer 会被销毁, 恢复时 native 重新绑定存在短暂窗口,
 * 因此用有限次数的延迟刷新覆盖首帧到达/绑定时序差异。
 * 目标是 3 秒内恢复画面, 10 秒内兜底自愈, 不做自动重连。
 */
const RESTORE_FRAME_REFRESH_DELAYS_MS: number[] = [
  0,
  120,
  300,
  700,
  1200,
  2000,
  3000,
  5000,
  7000,
  10000
];

export function getRestoreFrameRefreshDelaysMs(): number[] {
  return RESTORE_FRAME_REFRESH_DELAYS_MS.slice();
}

export enum RestoreRefreshAction {
  REQUEST_FRAME = 0,
  REBIND_SURFACE = 1,
  REPORT_STALLED = 2
}

export function restoreRefreshActionForDelay(delayMs: number): RestoreRefreshAction {
  if (delayMs >= 10000) {
    return RestoreRefreshAction.REPORT_STALLED;
  }
  if (delayMs >= 3000) {
    return RestoreRefreshAction.REBIND_SURFACE;
  }
  return RestoreRefreshAction.REQUEST_FRAME;
}

export function shouldRebindSurfaceForRestore(action: RestoreRefreshAction, rendererHandle: number): boolean {
  return action === RestoreRefreshAction.REBIND_SURFACE && rendererHandle <= 0;
}

export function shouldRestoreRenderImmediately(bgRestorePending: boolean, sessionId: number,
  surfaceReady: boolean, cleanupStarted: boolean): boolean {
  return bgRestorePending && sessionId > 0 && surfaceReady && !cleanupStarted;
}

export function shouldPollSurfaceForRestore(bgRestorePending: boolean, sessionId: number,
  surfaceReady: boolean, cleanupStarted: boolean): boolean {
  return bgRestorePending && sessionId > 0 && !surfaceReady && !cleanupStarted;
}
