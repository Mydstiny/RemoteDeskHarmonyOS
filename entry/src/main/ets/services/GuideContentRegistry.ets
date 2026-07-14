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
    id: 'protocols',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '选择合适的连接方式',
    desc: 'Windows 桌面优先使用 RDP，跨平台远控可选择 RustDesk；服务器维护和文件操作可使用 SSH 与 SFTP。'
  },
  {
    id: 'host-management',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '添加和管理远程主机',
    desc: '在主机页添加或编辑连接，并通过工作组和协议筛选整理设备。连接前检查会提示必要配置和当前可用能力。'
  },
  {
    id: 'remote-input',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '自然地控制远程设备',
    desc: '远程桌面支持触控板、直接触控和键鼠操作。系统键盘可顺序发送中文、Emoji 与大段文字，三指触摸可唤起控制面板。'
  },
  {
    id: 'transfer-clipboard',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '传输文件与同步文本',
    desc: 'SFTP 上传和下载支持中途取消与安全续传；RDP 和 RustDesk 会按真实会话能力提供文件操作，纯文本剪贴板支持双向同步。'
  },
  {
    id: 'ssh-security',
    symbol: $rawfile('icons/key.svg'),
    title: '安全使用 SSH 与密钥',
    desc: 'SSH 支持密码、私钥和跳板机，并会保存已确认的主机指纹。密钥库、2FA 验证器和隐私锁帮助保护敏感数据。'
  },
  {
    id: 'sync-backup',
    symbol: $rawfile('icons/cloud.svg'),
    title: '同步、离线与本地备份',
    desc: '登录华为账号后可选择需要同步的数据；离线模式只保存在本机。你也可以导出本地备份，并在预检后安全恢复。'
  },
  {
    id: 'background-responsive',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '适配你的鸿蒙设备',
    desc: '远程会话支持后台实况与返回恢复。手机、平板和 PC 使用响应式布局，并保留沉浸式光感悬浮底栏。'
  },
  {
    id: 'feedback-community',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '反馈问题或加入社区',
    desc: '在设置的“反馈”入口可以发送邮件，或获取最新畅联群聊二维码；二维码加载后也可以保存到系统相册。'
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
    id: 'welcome',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '欢迎使用',
    desc: '准备工作已经完成。现在可以从添加第一台远程主机开始，按连接场景逐步启用需要的能力。'
  });
  return pages;
}

export function settingsUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '随时在设置查看',
    desc: '需要回顾时，可从“设置 → 教程 → 简单使用教程”再次打开这里，查看最新版本的功能说明。'
  });
  return pages;
}
