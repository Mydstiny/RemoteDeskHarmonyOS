/**
 * RemoteImmersivePolicy.ets — 远程桌面系统导航栏沉浸策略。
 *
 * 只描述生命周期决策，不依赖 Window/UI，便于单元测试。
 */

function isRemoteDesktopProtocol(protocol: string): boolean {
  return protocol === 'rdp' || protocol === 'rustdesk';
}
export function shouldHideRemoteNavigation(protocol: string, connected: boolean): boolean {
  return connected && isRemoteDesktopProtocol(protocol);
}

/**
 * Hiding the status bar prevents a mobile/Pad mouse pointer from entering the
 * notification shade hit area while the remote canvas owns keyboard/mouse input.
 */
export function shouldHideRemoteStatusBar(protocol: string, connected: boolean,
  isDesktopDevice: boolean, _breakpoint: string, rustdeskControlMode: number): boolean {
  if (!connected || isDesktopDevice) {
    return false;
  }
  // RDP's canvas owns the complete mobile/Pad input surface. Keep the system
  // status bar out of that hit area for every RDP control mode. RustDesk keeps
  // its existing keyboard/mouse-only rule because its touch modes use the bar.
  return protocol === 'rdp' ||
    (protocol === 'rustdesk' && rustdeskControlMode === 2);
}

export function shouldReapplyRemoteNavigation(protocol: string, connected: boolean,
  backgroundPreserved: boolean): boolean {
  return backgroundPreserved && shouldHideRemoteNavigation(protocol, connected);
}

export function shouldRestoreRemoteNavigation(reason: string, backgroundPreserved: boolean): boolean {
  return !(backgroundPreserved && reason === 'background-preserve');
}
