export const CURRENT_RELEASE_VERSION: string = '1.0.7';

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
      id: 'rdp-render-session',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: 'RDP 画面与会话更可靠',
      desc: '重构画面调度、脏区合并、动态分辨率和断开释放流程，改善长时间连接、窗口缩放、后台返回及快速切换设备时的卡顿、黑屏和占用。'
    },
    {
      id: 'remote-input-keyboard',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '远程输入与实体键盘升级',
      desc: '修复中文、Emoji、光标移动和输入法回环；键鼠模式支持实体键盘、组合键及 Windows/macOS 布局，macOS 输入源可接收真实物理按键。'
    },
    {
      id: 'rdp-file-certificate',
      symbol: $rawfile('icons/shield-check.svg'),
      title: 'RDP 文件发送与证书管理',
      desc: '新增本地文件剪贴板发送；设置中可查看、刷新或忘记已信任的 RDP 证书。共享磁盘和连接能力按远端真实状态反馈，避免假成功。'
    },
    {
      id: 'rustdesk-relay-domain',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'RustDesk 中继与域名连接完善',
      desc: '修复 ID、直连、中继与 RDP 域名解析链路；支持导入 RustDesk 客户端中继配置，并完善连接结束、快速重连和异步资源释放。'
    },
    {
      id: 'rustdesk-pro-auth',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'Server Pro 地址簿与认证',
      desc: '新增 Server Pro 账户登录和地址簿设备同步。每次连接可选择设备密码或请求被控端批准，并区分一次性密码、永久密码与本地保存策略。'
    },
    {
      id: 'modern-add-security',
      symbol: $rawfile('icons/key.svg'),
      title: '统一添加流程与安全工具',
      desc: '新增现代资源添加向导，覆盖主机、RustDesk 中继、VNC、SSH 密钥和 2FA；支持密钥导入、生成、公钥部署和多种配置文件导入。'
    },
    {
      id: 'sync-backup-feedback',
      symbol: $rawfile('icons/cloud.svg'),
      title: '同步、备份与反馈更完整',
      desc: '完善云端数据选择同步、本地备份完整性校验与安全恢复；新增邮件和畅联群反馈入口，并修复二维码加载、保存及弹窗快速切换问题。'
    },
    {
      id: 'responsive-onboarding',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '手机、Pad 与 PC 体验统一',
      desc: '优化折叠屏断点、沉浸式悬浮栏、远程光标和响应式布局。更新说明、新用户介绍与教程统一适配深浅色，并按设备使用系统 Sheet。'
    },
    {
      id: 'welcome-1-0-7',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '欢迎使用 1.0.7',
      desc: '1.0.7 集中完善了连接、输入、传输、安全、同步与跨设备体验。感谢每一次测试和反馈，现在可以继续探索新版功能。'
    }
  ];
}
