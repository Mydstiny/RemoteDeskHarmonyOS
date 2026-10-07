/**
 * RustDesk options that now change while connected (2026-10-07): privacy mode (Misc.toggle_privacy_mode — peers from
 * 1.2.4 on ignore the login option), remote audio and the codec (a live OptionMessage), and a Windows peer's virtual
 * displays. The peer answers privacy-mode requests with a BackNotification; these are the words the user reads.
 */

/** BackNotification.PrivacyModeState → what happened, in plain words ('' : nothing to say). */
export function rustDeskPrivacyStateMessage(state: number): string {
  switch (state) {
    case 2: return '隐私模式已被远端的其他连接开启';
    case 3: return '远端不支持隐私模式（多显示器、系统版本或许可证不支持）';
    case 4: return '隐私模式已开启，远端屏幕已变黑';
    case 5: return '远端没有允许隐私模式（需要在被控端的权限里允许）';
    case 6: return '远端缺少隐私模式组件，未能开启';
    case 7: return '隐私模式开启失败';
    case 8: return '隐私模式已关闭';
    case 9: return '远端已关闭隐私模式';
    case 10: return '隐私模式关闭失败';
    case 11: return '隐私模式已关闭';
    default: return '';
  }
}

/** The privacy mode is on at the peer after this answer (true), off (false), or unchanged (null). */
export function rustDeskPrivacyStateOn(state: number): boolean | null {
  if (state === 2 || state === 4) { return true; }
  if (state === 3 || state === 5 || state === 6 || state === 7 || state === 8 || state === 9 || state === 11) {
    return false;
  }
  return null;
}

export function rustDeskCodecName(codec: number): string {
  switch (codec) {
    case 1: return 'VP8';
    case 2: return 'VP9';
    case 3: return 'AV1';
    case 4: return 'H264';
    case 5: return 'H265';
    default: return '自动';
  }
}

/** Remote audio can be switched on live only when the session started with audio (its local player exists). */
export function rustDeskLiveAudioPossible(on: boolean, startedWithAudio: boolean): boolean {
  return !on || startedWithAudio;
}
