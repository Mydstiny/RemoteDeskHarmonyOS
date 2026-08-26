export type SshPipPublicStatus = '已连接' | '后台保留';

/**
 * PiP is visible outside the application and may remain visible on the lock
 * screen. Only fixed public states may cross that boundary; arbitrary text
 * can contain commands, host identities, paths or secrets.
 */
export function sshPipPublicStatus(value: string): SshPipPublicStatus {
  return value.trim() === '后台保留' ? '后台保留' : '已连接';
}
