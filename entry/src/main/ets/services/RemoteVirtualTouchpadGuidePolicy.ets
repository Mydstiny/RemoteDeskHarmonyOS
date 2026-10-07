export interface RemoteVirtualTouchpadKeyboardGuide {
  title: string;
  message: string;
}

export function shouldShowRemoteVirtualTouchpadKeyboardGuide(protocol: string,
  connected: boolean, controlMode: number, shownThisSession: boolean,
  promptVisible: boolean, viewOnly: boolean, alreadyShownEver: boolean = false,
  alwaysVisible: boolean = false): boolean {
  if (!connected || shownThisSession || promptVisible || controlMode !== 0) { return false; }
  if (alreadyShownEver && !alwaysVisible) { return false; }
  if (protocol !== 'rdp' && protocol !== 'rustdesk' && protocol !== 'vnc') { return false; }
  return protocol !== 'vnc' || !viewOnly;
}

export function shouldRetryRemoteVirtualTouchpadKeyboardGuide(
  connected: boolean, retryCount: number): boolean {
  return connected && Number.isSafeInteger(retryCount) && retryCount >= 0 && retryCount < 2;
}

/** How touch input works now: written once here, shown in the first-run guide and in the one-time change notice. */
const REMOTE_TOUCH_GESTURES: string =
  '单指移动光标、轻点左键，双指轻点右键，三指上下滑动滚动。开启双指缩放后，双指只用来缩放和移动画面。';

export function remoteVirtualTouchpadKeyboardGuide(
  protocol: string): RemoteVirtualTouchpadKeyboardGuide {
  if (protocol === 'vnc') {
    return {
      title: '虚拟触控板已启用',
      message: '需要输入文字时，展开贴边的 VNC 控制栏，点「键盘」。\n\n' + REMOTE_TOUCH_GESTURES
    };
  }
  const protocolLabel: string = protocol === 'rdp' ? 'RDP' : 'RustDesk';
  return {
    title: '虚拟触控板已启用',
    message: protocolLabel + ' 会话中需要输入文字时，点顶部或贴边会话栏的键盘入口。\n\n' + REMOTE_TOUCH_GESTURES
  };
}

/**
 * The touch-gesture change notice (once per device, see REMOTE_TOUCH_GESTURE_NOTICE_STORAGE_KEY): RDP, RustDesk and
 * VNC in a touch mode (触控板 or 直接触控), never over another prompt, never for a read-only VNC view.
 */
export function shouldShowRemoteTouchGestureNotice(protocol: string, connected: boolean, controlMode: number,
  promptVisible: boolean, viewOnly: boolean, alreadyShown: boolean): boolean {
  if (!connected || promptVisible || alreadyShown) { return false; }
  if (controlMode !== 0 && controlMode !== 1) { return false; }
  if (protocol !== 'rdp' && protocol !== 'rustdesk' && protocol !== 'vnc') { return false; }
  return protocol !== 'vnc' || !viewOnly;
}

export function remoteTouchGestureNotice(protocol: string): RemoteVirtualTouchpadKeyboardGuide {
  const wheelPlace: string = protocol === 'rdp' ? '控制中心' :
    (protocol === 'vnc' ? '贴边控制栏的「滚轮」' : '会话栏的「鼠标与触控」');
  return {
    title: '触控操作有变化',
    message: '· 滚动改为三指上下滑动。开启双指缩放时，双指只用来缩放和移动画面，不再和滚动抢手势；没开缩放时双指也还能滚动。\n' +
      '· 三指轻点不再打开控制面板，键盘、组合键和文件传输都在会话栏里。\n' +
      '· 滚轮的方向和速度可以在' + wheelPlace + '里直接调，和「设置 › 远程滚轮」同步。'
  };
}
