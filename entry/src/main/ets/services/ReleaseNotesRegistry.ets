export const CURRENT_RELEASE_VERSION: string = '1.0.6';

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
      id: 'verified-capabilities',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '连接能力更可信',
      desc: '连接能力改为依据真实会话状态展示。尚未就绪或未获得远端确认的功能会说明原因，减少无效操作和假成功。'
    },
    {
      id: 'cancellable-transfer',
      symbol: $rawfile('icons/folder-open.svg'),
      title: '传输可取消、可续传',
      desc: 'SFTP 上传和下载期间可直接取消，部分上传可按已确认位置安全续传；RDP 与 RustDesk 也会反馈真实传输状态。'
    },
    {
      id: 'input-clipboard',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '输入与剪贴板更自然',
      desc: '系统输入法增强中文、Emoji 和大段文字的顺序输入；RDP 与 RustDesk 纯文本剪贴板支持双向同步和回环保护。'
    },
    {
      id: 'selective-cloud-sync',
      symbol: $rawfile('icons/cloud.svg'),
      title: '云同步由你决定',
      desc: '现在可以选择需要同步的数据，并获得前置条件指引、失败重试、下载回滚和异常恢复，跨设备同步更加可控。'
    },
    {
      id: 'local-backup',
      symbol: $rawfile('icons/key.svg'),
      title: '本地备份与安全恢复',
      desc: '新增本地数据导出、导入预检和事务恢复。发现无效备份时不会覆盖现有数据，并会明确提示敏感信息风险。'
    },
    {
      id: 'session-stability',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '长时间会话更加稳定',
      desc: '优化 RustDesk 长连接控制调度、远程会话后台实况和返回恢复，降低持续连接中的输入延迟与任务阻塞。'
    },
    {
      id: 'harmony-experience',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '更原生的鸿蒙体验',
      desc: '恢复沉浸式光感悬浮底栏，并完善手机、平板和 PC 的响应式布局、空状态、弹窗关闭与远程沉浸导航。'
    },
    {
      id: 'feedback-community',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '反馈与用户社区',
      desc: '设置中新增邮箱反馈和畅联群聊入口。群聊二维码可远程更新、失败重试，也可以保存到系统相册后识别加入。'
    },
    {
      id: 'welcome-1-0-6',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '欢迎使用 1.0.6',
      desc: '本次更新集中完善连接、输入、传输、同步、安全和鸿蒙原生体验。感谢使用 RemoteDesktop。'
    }
  ];
}
