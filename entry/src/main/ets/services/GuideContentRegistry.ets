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
    id: 'vnc-first-steps',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: 'VNC：先确认服务与端口',
    desc: '确认远端已启用 VNC 服务，再填写地址、端口和密码。连接质量不理想时，可在主机设置中调整画质、编码和输入选项。'
  },
  {
    id: 'add-and-organize',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '添加、分组并观察主机',
    desc: '从统一“添加”入口选择协议并保存主机，再按类型分组整理设备。在线检测和性能监控都可按需开启，不使用时保持关闭即可。'
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
    desc: '手机和 Pad 可使用虚拟触控板，PC 推荐实体键鼠。双指缩放画面；双指长按后拖动可平移画布，会话控制栏还能切换输入方式。'
  },
  {
    id: 'ssh-workspace',
    symbol: $rawfile('icons/command-line.svg'),
    title: 'SSH：多会话各自独立',
    desc: 'SSH 工作台可同时连接多台主机并保留各自终端。需要访问内网服务时，可为当前主机配置本地、远程或动态隧道转发。'
  },
  {
    id: 'files-and-tools',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '用 SFTP 管理与传输文件',
    desc: '在 SSH 会话中打开 SFTP，可浏览本机和远端目录、上传下载或在两台 SSH 主机间传输。重要任务中断后可从任务记录继续处理。'
  },
  {
    id: 'two-factor-and-credentials',
    symbol: $rawfile('icons/key.svg'),
    title: '密钥、证书与 2FA 分开保管',
    desc: '验证器使用真实供应商 Logo 帮助识别动态口令；SSH 密钥、RDP 证书信任和 RustDesk 凭据仍独立保存，连接时只选择需要的凭据。'
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
