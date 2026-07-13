export const CURRENT_RELEASE_VERSION: string = '1.0.6';

export interface ReleaseNotePage { symbol: ResourceStr; title: string; desc: string; }

export function pagesForReleasedVersion(version: string): ReleaseNotePage[] {
  if (version !== CURRENT_RELEASE_VERSION) { return []; }
  return [
    { symbol: $rawfile('icons/shield-check.svg'), title: '能力状态更清晰',
      desc: '连接能力现在以真实会话状态为准。尚未挂载或尚未获得远端确认的功能会明确说明原因，不再出现无效操作或假成功。' },
    { symbol: $rawfile('icons/computer-desktop.svg'), title: '主机工作台',
      desc: '新增收藏、最近使用、工作组、排序与连接健康信息，让常用主机更容易查找和管理。' },
    { symbol: $rawfile('icons/folder-open.svg'), title: '可靠传输与剪贴板',
      desc: 'SFTP 支持取消与安全续传，RDP 与 RustDesk 传输采用远端确认状态；纯文本剪贴板增加双向同步、长度限制与回环保护。' },
    { symbol: $rawfile('icons/shield-check.svg'), title: '欢迎使用 1.0.6',
      desc: '感谢使用 RemoteDesktop。我们会继续把连接稳定性、数据安全和鸿蒙原生体验放在首位。' }
  ];
}
