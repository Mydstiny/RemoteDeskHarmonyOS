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

export function shouldReapplyRemoteNavigation(protocol: string, connected: boolean,
  backgroundPreserved: boolean): boolean {
  return backgroundPreserved && shouldHideRemoteNavigation(protocol, connected);
}

export function shouldRestoreRemoteNavigation(reason: string, backgroundPreserved: boolean): boolean {
  return !(backgroundPreserved && reason === 'background-preserve');
}
