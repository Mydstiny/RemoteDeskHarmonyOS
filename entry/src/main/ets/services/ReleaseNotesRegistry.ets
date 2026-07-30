export const CURRENT_RELEASE_VERSION: string = '1.0.10';

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
      id: 'rustdesk-relay-save',
      symbol: $rawfile('icons/shield-check.svg'),
      title: 'RustDesk 服务器可靠保存',
      desc: '服务器配置先在本机事务提交并按稳定 ID 回读；云同步失败不会再伪装成本地保存失败，失败时保留草稿并给出可操作原因。'
    },
    {
      id: 'rustdesk-unified-setup',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '更清晰的服务器添加流程',
      desc: 'RustDesk 服务器统一为一个添加流程，默认只需导入配置或填写服务器地址与公钥；端口、API 和控制面能力按需展开。'
    },
    {
      id: 'rustdesk-auth-boundaries',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '登录与中继凭据不再混用',
      desc: '地址簿登录、Server Pro 控制面令牌、共享访问 Key 和服务器公钥保持独立；只有来源和能力均可证明的配置才会向连接请求投影令牌。'
    },
    {
      id: 'rustdesk-connection-diagnostics',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '连接诊断可判定',
      desc: 'FORCE_RELAY 与 DIRECT_IP 路径显式校验并返回结构化阶段、错误码和尝试编号；日志不会记录密码、令牌、密钥或完整地址。'
    },
    {
      id: 'welcome-1-0-10',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '欢迎使用 1.0.10',
      desc: '这一版聚焦 RustDesk 服务器保存、普通用户控制面登录与中继连接。AUTO/P2P 回退仍需真实协议和设备验证，当前不会被界面描述为已经可用。'
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
