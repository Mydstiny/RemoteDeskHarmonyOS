export const CURRENT_RELEASE_VERSION: string = '1.0.9';

export interface ReleaseNotePage {
  id: string;
  symbol: ResourceStr;
  title: string;
  desc: string;
}

export function pagesForReleasedVersion(version: string): ReleaseNotePage[] {
  if (version !== CURRENT_RELEASE_VERSION) { return []; }
  return [
    {
      id: 'account-data-isolation',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '账号数据完全隔离',
      desc: '离线模式和每个已验证的华为账号使用独立本地数据空间；登录、登出或切换账号时会停止旧账号同步并清理敏感缓存。'
    },
    {
      id: 'fail-closed-cloud-sync',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '云同步故障安全升级',
      desc: '首次拉取、重新启用同步、超时和迟到回调进入统一持久化队列；账号或数据形态无法验证时会停止同步，避免覆盖本地或云端数据。'
    },
    {
      id: 'portable-backup-v3',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '本地备份与恢复 v3',
      desc: '备份新增账号绑定和完整性清单，并支持旧版备份按兼容表部分恢复；登录令牌、密码、私钥、2FA 密钥和设备信任默认不会导出。'
    },
    {
      id: 'welcome-1-0-9',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '欢迎使用 1.0.9',
      desc: '这一版重建了账号、云同步、加密和本地备份的生命周期边界；涉及跨设备云数据的最终结果仍以设置页的同步状态为准。'
    }
  ];
}

export enum StartupMode { FIRST_INSTALL_GUIDE, RELEASE_NOTES, LOGIN }

function parseVersion(value: string): number[] | null {
  const parts: string[] = value.split('.');
  if (parts.length !== 3) { return null; }
  const values: number[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    if (!/^\d+$/.test(parts[i])) { return null; }
    values.push(Number(parts[i]));
  }
  return values;
}

export function compareReleaseVersion(left: string, right: string): number {
  const a: number[] | null = parseVersion(left);
  const b: number[] | null = parseVersion(right);
  if (a === null || b === null) { return 0; }
  for (let i: number = 0; i < 3; i++) {
    if (a[i] < b[i]) { return -1; }
    if (a[i] > b[i]) { return 1; }
  }
  return 0;
}

export function resolveStartupMode(guideShown: boolean, lastSeen: string, current: string,
  hasCurrentReleaseNotes: boolean): StartupMode {
  if (!guideShown) { return StartupMode.FIRST_INSTALL_GUIDE; }
  if (!hasCurrentReleaseNotes || parseVersion(current) === null) {
    return StartupMode.LOGIN;
  }
  const previous: string = lastSeen.length === 0 ? '0.0.0' : lastSeen;
  if (parseVersion(previous) === null) { return StartupMode.LOGIN; }
  return compareReleaseVersion(previous, current) < 0 ? StartupMode.RELEASE_NOTES : StartupMode.LOGIN;
}

/**
 * 手机端的首次介绍和版本更新说明都使用底部半屏 Sheet。
 * 登录模式没有引导内容，不应触发 Sheet。
 */
export function shouldPresentGuideAsBottomSheet(mode: StartupMode, breakpoint: string): boolean {
  return mode !== StartupMode.LOGIN && breakpoint === 'sm';
}

/**
 * Pad/PC 端的版本更新说明和首次介绍都使用居中系统 Sheet。
 */
export function shouldPresentGuideAsDialog(mode: StartupMode, breakpoint: string): boolean {
  return mode !== StartupMode.LOGIN && breakpoint !== 'sm';
}
