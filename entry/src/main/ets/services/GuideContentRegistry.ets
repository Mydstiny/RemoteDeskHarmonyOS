/**
 * GuideContentRegistry — 新用户引导与设置教程的唯一内容源。
 *
 * 两种入口共享全部功能介绍，只使用不同的收尾页。
 */
export interface GuideContentPage {
  id: string;
  symbol: ResourceStr;
  title: string;
  desc: string;
}

const SHARED_GUIDE_PAGES: GuideContentPage[] = [
  {
    id: 'four-protocol-workspace',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '四种协议，一个工作台',
    desc: 'RDP 连接 Windows，RustDesk 负责跨平台远控，SSH/SFTP 管理服务器，VNC 连接标准兼容设备。先按目标设备选择协议。'
  },
  {
    id: 'add-and-organize',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '添加、分组，再连接',
    desc: '从统一“添加”入口选择协议并保存主机；再用分组和协议筛选整理设备。连接前仍可检查地址、端口和账号。'
  },
  {
    id: 'verify-before-trust',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '第一次连接，先确认身份',
    desc: '核对 RDP 证书、SSH 主机指纹或 RustDesk 被控端信息；密码、批准和二次验证只在来源可信时提交。'
  },
  {
    id: 'session-controls',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '按设备选择操控方式',
    desc: '手机可用触控和虚拟键盘，Pad/PC 可配合触控板、鼠标与实体键盘；会话控制栏用于切换输入、缩放和断开。'
  },
  {
    id: 'files-and-tools',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '文件、剪贴板与安全工具',
    desc: '用 SFTP 浏览和传输文件，按会话能力同步文本剪贴板；密钥库与验证器帮助保管 SSH 密钥和一次性验证码。'
  },
  {
    id: 'cloud-and-backup',
    symbol: $rawfile('icons/cloud.svg'),
    title: '同步前，先选数据和方向',
    desc: '华为账号云同步只处理你勾选的数据。恢复备份后，请明确选择“上传本机”或“下载云端”，确认方向后再执行。'
  }
];

function sharedPages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  SHARED_GUIDE_PAGES.forEach((page: GuideContentPage): void => { pages.push(page); });
  return pages;
}

export function firstInstallGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'start-first-host',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '从第一台主机开始',
    desc: '准备好了。进入工作台，选择协议并添加第一台主机；遇到提示时先核对安全信息，再开始连接。'
  });
  return pages;
}

export function settingsUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '需要时随时回来',
    desc: '从“设置 → 教程 → 简单使用教程”可以重新查看；协议部署、账号和服务端准备请继续打开“如何进行前置操作”。'
  });
  return pages;
}
