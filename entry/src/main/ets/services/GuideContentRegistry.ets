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
    title: '四种协议，各有所长',
    desc: 'Windows 桌面优先使用 RDP，跨平台远控选择 RustDesk，服务器维护与文件管理使用 SSH/SFTP，兼容设备也可通过 VNC 连接。'
  },
  {
    id: 'resource-wizard',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '从“添加”开始配置资源',
    desc: '主机页的统一添加入口会按协议引导填写凭据、中继、密钥和 2FA；也可切换经典模式。工作组与协议筛选方便整理大量设备。'
  },
  {
    id: 'connection-check',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '连接前先确认安全信息',
    desc: 'RDP 会核对并记录服务器证书，SSH 首次连接会确认主机指纹；RustDesk 可选择设备密码或请求被控端批准，减少误连和假成功。'
  },
  {
    id: 'remote-input',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '触控、键鼠和输入法',
    desc: '远程桌面支持触控板、直接触控与键鼠模式。实体键盘可选择 Windows 或 macOS 布局，虚拟键盘支持中文、Emoji 与连续文本输入。'
  },
  {
    id: 'transfer-clipboard',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '文件传输与剪贴板',
    desc: 'SFTP 上传和下载提供进度、取消与安全续传；RDP 支持本地文件剪贴板发送。文本剪贴板按会话真实能力双向同步，不可用操作不会显示为成功。'
  },
  {
    id: 'ssh-security',
    symbol: $rawfile('icons/key.svg'),
    title: 'SSH、密钥与 2FA',
    desc: 'SSH 支持密码、私钥、跳板机和公钥部署。密钥库可导入或生成密钥，2FA 验证器集中管理动态口令，隐私锁保护敏感数据。'
  },
  {
    id: 'rustdesk-relay-pro',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '管理 RustDesk 中继与 Pro',
    desc: '可以导入 RustDesk 客户端的中继配置，使用域名或 IP 连接自建服务器；Server Pro 账户可同步地址簿设备，并保留本地连接设置。'
  },
  {
    id: 'sync-backup',
    symbol: $rawfile('icons/cloud.svg'),
    title: '同步、离线与本地备份',
    desc: '登录华为账号后可按数据类别选择同步；离线模式只保存在本机。完整性校验、导出备份和恢复预检帮助降低覆盖或损坏风险。'
  },
  {
    id: 'background-responsive',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '跨设备布局与会话恢复',
    desc: '手机、折叠屏、平板与 PC 使用响应式布局。远程会话支持后台实况、前台恢复、动态分辨率与沉浸式悬浮控制栏。'
  },
  {
    id: 'feedback-community',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '反馈问题或加入社区',
    desc: '设置中的“反馈”入口支持发送邮件，或查看并保存最新畅联群聊二维码。反馈时附上协议、设备与复现步骤会更容易定位问题。'
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
    desc: '基础功能已经介绍完毕。现在可以从统一“添加”入口创建第一台远程主机，并按连接前提示完成安全确认。'
  });
  return pages;
}

export function settingsUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '随时在设置查看',
    desc: '需要回顾时，可从“设置 → 教程 → 简单使用教程”重新打开本指南；连接部署细节可继续查看“如何进行前置操作”。'
  });
  return pages;
}
