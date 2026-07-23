export const CURRENT_RELEASE_VERSION: string = '1.0.8';

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
      id: 'background-video-pip',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '新增远程视频后台播放',
      desc: '有真实视频的远程会话进入后台后继续保持连接，并尝试进入 VIDEO_PLAY 画中画，画面承载真实远程帧。'
    },
    {
      id: 'avsession-media-identity',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '新增系统媒体播控身份',
      desc: '远程视频会以 AVSession video 身份出现在系统媒体控制入口；标题、协议和播放/暂停状态会随会话同步。'
    },
    {
      id: 'native-vp9-background-crash',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '修复切后台 VP9 崩溃',
      desc: '修复软件解码线程与渲染回调并发关闭导致的 bad_function_call、SIGABRT 以及 renderer 已销毁后仍回调的问题。'
    },
    {
      id: 'pip-frame-lifecycle',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '修复画中画静帧和误启动',
      desc: 'PIP 改用官方 XComponent free-node 视频承载并保留有效视频源；无连接、旧会话或退出应用时不会短暂弹出空画中画。'
    },
    {
      id: 'grip-permission-startup',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '智感握姿启动即准备',
      desc: '移动设备启动后自动申请握姿权限，设置页改为显示当前状态，不再提供容易误触的开关；权限弹窗不会阻塞主机列表首屏。'
    },
    {
      id: 'onboarding-rewrite',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '重写新用户引导与教程',
      desc: '将首次介绍和“简单使用教程”统一为添加主机、首次安全确认、远程操作、文件传输、后台视频和数据保护的上手步骤。'
    },
    {
      id: 'responsive-guide-sheets',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '修复引导弹窗在小屏溢出',
      desc: '收紧不同断点的 Sheet 高度、内容宽度和分页间距，手机、折叠屏、平板与 PC 使用各自合适的弹窗布局。'
    },
    {
      id: 'welcome-1-0-8',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '欢迎使用 1.0.8',
      desc: '这一版把远程连接的后台连续性、视频窗口生命周期和首次使用引导收敛到同一条可验证的产品路径。'
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
