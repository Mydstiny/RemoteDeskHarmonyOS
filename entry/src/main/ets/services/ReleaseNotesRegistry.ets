export const CURRENT_RELEASE_VERSION: string = '1.1.2';
export const CURRENT_RELEASE_VERSION_CODE: number = 1001002;

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
      id: 'release-1-1-2',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.2：五协议工作台全面升级',
      desc: '从 1.1.1 升级后，Moonlight 正式加入 RDP、RustDesk、SSH/SFTP 与 VNC 工作台；会话操控、设备适配、安全校验和操作引导也同步增强。'
    },
    {
      id: 'release-moonlight-workflow',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'Moonlight 加入主机工作台',
      desc: '可发现或手动添加 Sunshine 主机，完成身份核对与配对，再浏览应用目录并发起串流；主机详情、应用缓存与连接设置都归入统一入口。'
    },
    {
      id: 'release-moonlight-session',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '串流、输入与生命周期更完整',
      desc: 'Moonlight 会话接入画面、声音、键鼠、触控和控制器输入，并处理重连、画中画、前后台恢复以及“仅断开/结束主机应用”的不同退出语义。'
    },
    {
      id: 'release-ssh-workspace',
      symbol: $rawfile('icons/command-line.svg'),
      title: 'SSH 升级为多窗格工作台',
      desc: '标签页、侧栏、终端窗格、检查器和状态栏重新组织；宽屏可并行处理多会话，手机和窄窗口则保留清晰的单任务路径与稳定输入焦点。'
    },
    {
      id: 'release-ssh-productivity',
      symbol: $rawfile('icons/folder-open.svg'),
      title: 'SSH/SFTP 工具集中到手边',
      desc: '新增终端搜索、常用命令、广播输入、配置档案与快捷键；端口转发、SFTP 双栏和传输中心也统一呈现进度、重试与完整性结果。'
    },
    {
      id: 'release-session-keyboard',
      symbol: $rawfile('icons/key.svg'),
      title: '图形会话共用远程键盘',
      desc: 'RDP、RustDesk、VNC 与 Moonlight 共用贴边入口，可切换 Windows/macOS 键位、发送功能键与导航键，并保存常用组合键；手机横屏和输入法弹出时仍可触达。'
    },
    {
      id: 'release-device-layouts',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '手机、Pad 与 PC 各得其所',
      desc: '手机优先触控和贴边控制，Pad 兼顾触控与键鼠，PC 使用独立会话窗口和多窗格工作区；弹窗、侧栏和控制面板会随可用窗口尺寸调整。'
    },
    {
      id: 'release-lan-discovery',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '局域网主机更容易找到',
      desc: 'RDP 与 RustDesk 可从局域网发现结果创建主机；保存时明确选择固定地址同步，或保留动态地址仅在本机自动刷新，避免 DHCP 变化污染云端记录。'
    },
    {
      id: 'release-security-preflight',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '连接前校验路径更一致',
      desc: '主机锁、RDP 证书、VNC TLS/明文决策与凭据重试统一在进入会话前完成；一次性凭据不会重复询问，服务器身份发生变化时也不会静默沿用旧信任。'
    },
    {
      id: 'release-guidance',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '引导只在真正需要时出现',
      desc: '首次教程按设备说明协议选择和安全连接；SSH、Moonlight 与远程触控提示默认各显示一次。需要反复查看时，可在“设置 → 教程”开启“始终显示引导”。'
    },
    {
      id: 'release-data-diagnostics',
      symbol: $rawfile('icons/cloud.svg'),
      title: '数据边界与排障更可靠',
      desc: 'Moonlight 主机和设置纳入明确的本地、备份与可选同步边界，配对信任仍只留在本机；诊断采集支持脱敏导出，失败阶段和恢复结果更容易定位。'
    },
    {
      id: 'welcome-1-1-2',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '欢迎使用 1.1.2',
      desc: '现在可以从主机工作台体验五种协议。第一次尝试新能力时先按界面核对服务端、身份与网络条件；完整步骤可从“设置 → 教程 → 操作引导中心”随时查看。'
    }
  ];
}
