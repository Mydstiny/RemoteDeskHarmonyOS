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
      id: 'ime-session-stability',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '远程输入更稳定',
      desc: '优化中文、Emoji 和光标移动的远程输入会话，减少重复输入、光标跳动和输入法回环，长文本与连续操作更可靠。'
    },
    {
      id: 'rdp-certificate-trust',
      symbol: $rawfile('icons/shield-check.svg'),
      title: 'RDP 证书信任可管理',
      desc: '设置中可以查看已信任的 RDP 证书，重新获取证书信息，或忘记已有信任记录；下次连接时会重新进行确认。'
    },
    {
      id: 'rustdesk-session-stability',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'RustDesk 会话恢复更可靠',
      desc: '改进连接结束、快速重连和异步流释放的生命周期处理，避免旧会话在新连接建立后恢复为已连接状态。'
    },
    {
      id: 'welcome-1-0-7',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '欢迎使用 1.0.7',
      desc: '本次更新集中完善远程输入、RDP 安全确认和 RustDesk 会话稳定性。感谢使用 RemoteDesktop。'
    }
  ];
}
