/**
 * RemoteImmersivePolicy.ets — 远程桌面系统导航栏沉浸策略。
 *
 * 只描述生命周期决策，不依赖 Window/UI，便于单元测试。
 */

function isRemoteSessionProtocol(protocol: string): boolean {
  return protocol === 'rdp' || protocol === 'rustdesk' || protocol === 'vnc' ||
    protocol === 'moonlight' || protocol === 'ssh';
}
export function shouldHideRemoteNavigation(protocol: string, connected: boolean): boolean {
  return connected && isRemoteSessionProtocol(protocol);
}

/**
 * Hiding the status bar prevents a mobile/Pad mouse pointer from entering the
 * notification shade hit area while the remote canvas owns keyboard/mouse input.
 */
export function shouldHideRemoteStatusBar(protocol: string, connected: boolean,
  isDesktopDevice: boolean, _breakpoint: string, _rustdeskControlMode: number): boolean {
  if (!connected || isDesktopDevice) {
    return false;
  }
  // Every phone/Pad remote-session page owns the complete interaction surface.
  // A protocol control-mode switch must never silently expose a system hit
  // target above the remote canvas.
  return isRemoteSessionProtocol(protocol);
}

export function shouldReapplyRemoteNavigation(protocol: string, connected: boolean,
  backgroundPreserved: boolean): boolean {
  return backgroundPreserved && shouldHideRemoteNavigation(protocol, connected);
}

export function shouldRestoreRemoteNavigation(reason: string, backgroundPreserved: boolean): boolean {
  return !(backgroundPreserved && reason === 'background-preserve');
}
