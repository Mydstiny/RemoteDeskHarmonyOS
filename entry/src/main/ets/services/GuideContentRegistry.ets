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
    title: '先选适合的连接方式',
    desc: 'RDP 连接 Windows，RustDesk 适合跨平台远控，SSH/SFTP 适合服务器维护；VNC 仅在当前版本明确支持时使用。'
  },
  {
    id: 'add-first-host',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '从“添加”开始',
    desc: '点击主机页的添加按钮，选择协议，按向导填写地址、端口、账号和密码，再保存第一台主机。'
  },
  {
    id: 'connection-security',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '第一次连接先核对安全信息',
    desc: 'RDP 会检查服务器证书，SSH 会显示主机指纹；RustDesk 可能需要设备密码或被控端批准。确认无误再信任。'
  },
  {
    id: 'remote-controls',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '连接后这样操作',
    desc: '远程画面支持触控、触控板、键鼠和虚拟键盘。三指触摸或控制栏可以打开键盘、剪贴板、缩放和断开操作。'
  },
  {
    id: 'transfer-clipboard',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '文件和剪贴板按真实能力工作',
    desc: 'SFTP 可浏览、上传和下载文件；文本剪贴板按当前会话能力同步。未就绪或不支持的操作不会假装成功。'
  },
  {
    id: 'background-video',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '后台继续连接，画面可进画中画',
    desc: '有真实远程视频时，后台会维持连接并尝试系统媒体播控和视频画中画；是否显示媒体胶囊仍由系统开关和设备能力决定。'
  },
  {
    id: 'secure-sync-backup',
    symbol: $rawfile('icons/key.svg'),
    title: '把凭据和数据保护好',
    desc: '主密码保护密钥库和验证器；登录华为账号可选择同步，离线模式只存本机。本地备份导入前会先校验。'
  },
  {
    id: 'help-and-settings',
    symbol: $rawfile('icons/cloud.svg'),
    title: '遇到问题先看设置',
    desc: '设置里可以重新打开教程、查看前置操作、反馈问题和获取社区入口。反馈时附上协议、设备和复现步骤。'
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
    desc: '教程完成。现在就从统一“添加”入口创建第一台远程主机，连接前按提示完成安全确认。'
  });
  return pages;
}

export function settingsUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '随时在设置查看',
    desc: '需要回顾时，从“设置 → 教程 → 简单使用教程”重新打开；部署细节可继续查看“如何进行前置操作”。'
  });
  return pages;
}
