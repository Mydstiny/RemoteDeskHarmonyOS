export type SshTerminalOrientation = 'system' | 'portrait' | 'landscape';

export function defaultSshTerminalOrientation(_isDesktopDevice: boolean): SshTerminalOrientation {
  // 所有设备进入 SSH 终端都跟随设备当前朝向（system），不再强制竖屏；
  // 用户仍可通过终端内的切换按钮手动锁定横/竖屏。
  return 'system';
}

export function toggleSshTerminalOrientation(current: SshTerminalOrientation): SshTerminalOrientation {
  return current === 'landscape' ? 'portrait' : 'landscape';
}
