export const CURRENT_RELEASE_VERSION: string = '1.1.1';

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
      id: 'release-1-1-1',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.1：VNC 与远程工作台焕新',
      desc: '这一版以 VNC 全链路升级为主线，并重构 SSH/SFTP、强化 RustDesk 与 RDP，同时补齐主机管理、2FA 和多设备输入体验。'
    },
    {
      id: 'release-vnc-performance',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: 'VNC 画面更快、更稳',
      desc: '系统优化 VNC 连接、ZRLE 解码、画面刷新与异常恢复链路；复杂桌面和连续操作下的响应、稳定性与诊断能力全面提升。'
    },
    {
      id: 'release-vnc-input',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: 'VNC 操控与设置更完整',
      desc: '键盘、鼠标、滚轮、触控板与剪贴板协作更可靠；连接和会话选项重新梳理，语义化图标让编码、画质和输入设置更容易辨认。'
    },
    {
      id: 'release-rustdesk-performance',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'RustDesk 性能与在线监测',
      desc: '优化视频解码、帧率调度、输入延迟与重连表现；主机可按需开启在线状态监测，快速识别当前可连接的设备。'
    },
    {
      id: 'release-rustdesk-account',
      symbol: $rawfile('icons/shield-check.svg'),
      title: 'RustDesk 登录与 2FA 修复',
      desc: '修复部分中继账户无法登录或同步的问题；支持远端 2FA 校验，并可使用本地验证器中匹配的动态口令自动完成校验。'
    },
    {
      id: 'release-host-workspace',
      symbol: $rawfile('icons/folder-open.svg'),
      title: '主机分组与性能监控',
      desc: '主机可以按类型分类排布；多主机性能监控改为独立开关，需要时查看连接质量，不需要时减少后台观测开销。'
    },
    {
      id: 'release-ssh-multi-session',
      symbol: $rawfile('icons/command-line.svg'),
      title: 'SSH 会话彻底重构',
      desc: '新的会话工作台可以同时连接多台 SSH 主机，在标签页之间切换并保留各自终端、认证和重连状态。'
    },
    {
      id: 'release-sftp-forwarding',
      symbol: $rawfile('icons/folder-open.svg'),
      title: 'SFTP 升级与隧道转发',
      desc: 'SFTP 文件浏览、传输、恢复和双主机操作全面升级；SSH 新增本地、远程与动态隧道转发，常用转发配置可以独立管理。'
    },
    {
      id: 'release-rdp-security',
      symbol: $rawfile('icons/shield-check.svg'),
      title: 'RDP 性能与证书安全',
      desc: '优化 RDP 画面、输入与连接稳定性，并接入 FreeRDP 官方证书校验和信任机制，让首次连接和证书变化提示更明确。'
    },
    {
      id: 'release-authenticator-logos',
      symbol: $rawfile('icons/key.svg'),
      title: '验证器展示真实品牌 Logo',
      desc: '2FA 验证器新增真实供应商 Logo，并优先按签发方和账号信息匹配；动态口令、SSH 密钥与远程凭据仍保持独立管理。'
    },
    {
      id: 'release-input-fixes',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '缩放、画布与触控板修复',
      desc: '修复双指缩放与画布移动冲突：双指长按后拖动即可平移画布；同时修复 PC 端触控板无法正常操控远端的问题。'
    },
    {
      id: 'welcome-1-1-1',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '欢迎使用 1.1.1',
      desc: '现在可以从主机工作台开始体验新版 VNC、RustDesk、SSH/SFTP 与 RDP。更多开关和协议细节可在设置及简单使用教程中随时查看。'
    }
  ];
}
