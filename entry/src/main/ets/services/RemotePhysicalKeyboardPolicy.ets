/**
 * Physical-keyboard policy for RDP and RustDesk remote sessions.
 *
 * RDP is a Windows-only remote desktop protocol in this app, so it always
 * uses the Windows layout. RustDesk, VNC and Moonlight can target macOS or
 * Windows and therefore require an explicit choice.
 */
export enum RemoteKeyboardLayout {
  WINDOWS = 'windows',
  MACOS = 'macos'
}

/** PC sessions default to the physical keyboard/mouse path (mode 2). */
export function remoteControlModeDefaultForDevice(isDesktopDevice: boolean): number {
  return isDesktopDevice ? 2 : 0;
}

export const HARMONY_KEYCODE_CTRL_LEFT: number = 2072;
export const HARMONY_KEYCODE_CTRL_RIGHT: number = 2073;
export const HARMONY_KEYCODE_META_LEFT: number = 2076;
export const HARMONY_KEYCODE_META_RIGHT: number = 2077;
export const MACOS_CAPS_LOCK_LONG_PRESS_MS: number = 350;

export function isMacCapsLockLongPress(durationMs: number): boolean {
  return durationMs >= MACOS_CAPS_LOCK_LONG_PRESS_MS;
}

export function mapPhysicalKeyForRemoteLayout(layout: RemoteKeyboardLayout, keyCode: number): number {
  if (layout !== RemoteKeyboardLayout.MACOS) {
    return keyCode;
  }
  switch (keyCode) {
    case HARMONY_KEYCODE_CTRL_LEFT: return HARMONY_KEYCODE_META_LEFT;
    case HARMONY_KEYCODE_CTRL_RIGHT: return HARMONY_KEYCODE_META_RIGHT;
    case HARMONY_KEYCODE_META_LEFT: return HARMONY_KEYCODE_CTRL_LEFT;
    case HARMONY_KEYCODE_META_RIGHT: return HARMONY_KEYCODE_CTRL_RIGHT;
    default: return keyCode;
  }
}

export function shouldChoosePhysicalKeyboardLayout(protocol: string, _isDesktopDevice: boolean,
  _breakpoint: string): boolean {
  // 键盘布局描述的是远端系统，不取决于控制端是 PC、Pad 还是 Phone。
  // RDP 目标固定为 Windows；RustDesk/VNC must not infer a remote OS from
  // the controller, so they use an explicit session choice.
  return protocol === 'rustdesk' || protocol === 'vnc' || protocol === 'moonlight';
}

/** RDP always targets Windows, including when a session surface is reused. */
export function physicalKeyboardLayoutForProtocol(protocol: string,
  selectedLayout: RemoteKeyboardLayout): RemoteKeyboardLayout {
  return protocol === 'rdp' ? RemoteKeyboardLayout.WINDOWS : selectedLayout;
}

export function shouldConsumeRemoteBack(connected: boolean, isDesktopDevice: boolean,
  _breakpoint: string, keyboardMouseMode: boolean, physicalKeyboardConnected: boolean,
  hardwareKeyboardProxyActive: boolean): boolean {
  return connected && isDesktopDevice && keyboardMouseMode &&
    physicalKeyboardConnected && hardwareKeyboardProxyActive;
}

export function shouldAutoSwitchVncKeyboardMouseMode(
  protocol: string,
  connected: boolean,
  viewOnly: boolean,
  externalKeyboardMouseConnected: boolean,
  currentMode: number,
  sessionId: number,
  alreadyAppliedSessionId: number
): boolean {
  return protocol === 'vnc' && connected && !viewOnly &&
    externalKeyboardMouseConnected && currentMode !== 2 && sessionId > 0 &&
    alreadyAppliedSessionId !== sessionId;
}

export function remoteKeyboardLayoutDescription(layout: RemoteKeyboardLayout): string {
  if (layout === RemoteKeyboardLayout.MACOS) {
    return 'Ctrl 映射为 Command，Win/Meta 映射为 Control；使用 Win/Meta+空格切换远端输入法。';
  }
  return 'Ctrl、Alt、Shift、Win 保持原键位，适合 Windows 和常规 RDP 会话。';
}
