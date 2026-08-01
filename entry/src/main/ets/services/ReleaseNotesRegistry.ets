export const CURRENT_RELEASE_VERSION: string = '1.1.0';

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
      id: 'release-1-1-0',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.0：一次完整升级',
      desc: '这是从 1.0.8 到 1.1.0 的累计更新：四协议工作台、远程输入、连接性能、数据安全与云同步恢复都得到持续改进。'
    },
    {
      id: 'release-four-protocols',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '四种协议各归其位',
      desc: 'RDP、RustDesk、SSH/SFTP 与 VNC 共用主机工作台，同时保留各自的认证、连接与设置边界；添加和筛选路径更统一。'
    },
    {
      id: 'release-input-performance',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '远程画面与输入更顺手',
      desc: 'VNC 的 ZRLE 解码、滚轮与键盘输入得到优化；触控、触控板、鼠标、实体键盘和输入法继续按设备形态协同工作。'
    },
    {
      id: 'release-cloud-recovery',
      symbol: $rawfile('icons/cloud.svg'),
      title: '云同步恢复不再卡死',
      desc: '导入本地备份后，自动同步会等待你的选择；明确执行“上传本机”或“下载云端”后，仅同步已勾选的数据，未勾选的数据继续保留在本机。'
    },
    {
      id: 'release-security-boundaries',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '凭据与数据边界更清楚',
      desc: '证书、主机指纹、RustDesk 凭据、SSH 密钥和验证器继续分开管理；云同步按账号和勾选范围执行，不把失败显示成成功。'
    },
    {
      id: 'release-rustdesk-workflow',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: 'RustDesk 配置与诊断更可靠',
      desc: '服务器保存、统一添加流程、认证边界与连接诊断得到加强；本地保存和云端结果分别反馈，失败时保留可继续处理的信息。'
    },
    {
      id: 'welcome-1-1-0',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '欢迎使用 1.1.0',
      desc: '这一版汇总 1.0.8 以来的远程协议、输入、数据安全与云同步改进。仍需真实协议或设备验证的能力不会被界面描述为已经可用。'
    }
  ];
}
