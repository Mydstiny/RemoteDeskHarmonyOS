export const PRO_LIFETIME: string = 'pro.lifetime';
export const PRO_PERSONALIZATION_FEATURE: string = 'pro.personalization';
export const PRO_RDP_ADVANCED_DISPLAY_FEATURE: string = 'pro.display.rdpAdvanced';
export const PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE: string = 'pro.display.rustdeskAdvanced';
export const PRO_DIAGNOSTICS_FEATURE: string = 'pro.diagnostics';
export const PRO_DIAGNOSTICS_PROVIDER_FEATURE: string = 'pro.diagnostics.providerConfig';
export const PRO_DIAGNOSTICS_ASSISTANT_FEATURE: string = 'pro.diagnostics.assistant';
export const PRO_DIAGNOSTICS_EMAIL_FEATURE: string = 'pro.diagnostics.emailBundle';
export type ProAvailability = 'available' | 'planned' | 'experimental' | 'disabled';
export type ProDevice = 'phone' | 'tablet' | 'pc' | 'unknown';
export interface ProFeature {
  id: string;
  title: string;
  description: string;
  requiredEntitlementId: string;
  availability: ProAvailability;
  minAppVersionCode: number;
  minApiVersion: number;
  devices: ProDevice[];
  protocols: string[];
  capabilities: string[];
  permissions: string[];
  serverAuthorized: boolean;
}
function planned(id: string, title: string, description: string, api: number = 23): ProFeature {
  return { id, title, description, requiredEntitlementId: PRO_LIFETIME, availability: 'planned',
    minAppVersionCode: 0, minApiVersion: api, devices: ['phone', 'tablet', 'pc'],
    protocols: [], capabilities: [], permissions: [], serverAuthorized: false };
}
function appIcon(): ProFeature {
  const feature = planned('pro.personalization.appIcon', '预设应用图标',
    '选择随应用提供的白底版或透明底版图标，随时恢复默认。需要鸿蒙 7（API 26）及以上。', 26);
  feature.availability = 'available';
  return feature;
}
function knockTransfer(): ProFeature {
  const feature = planned('pro.file.knockTransfer', '碰一碰传文件',
    '在鸿蒙 PC 的 SFTP 窗口接收手机文件，确认后上传到选定目录。', 26);
  feature.availability = 'experimental';
  feature.devices = ['pc'];
  feature.protocols = ['ssh'];
  feature.capabilities = ['SystemCapability.Collaboration.HarmonyShare'];
  return feature;
}
function continuation(): ProFeature {
  const feature = planned('pro.connection.continuation', '同账号接续',
    '在手机、平板和 PC 间重新连接同账号的主机：直连 SSH 恢复目录，RDP 恢复桌面视图，RustDesk 与 VNC 重新连接同一台远程桌面。', 23);
  feature.availability = 'available';
  feature.devices = ['phone', 'tablet', 'pc']; feature.protocols = ['ssh', 'rdp', 'rustdesk', 'vnc'];
  feature.capabilities = ['SystemCapability.DistributedDataManager.DataObject.DistributedObject'];
  feature.permissions = ['ohos.permission.DISTRIBUTED_DATASYNC'];
  return feature;
}
function connectionShare(): ProFeature {
  const feature = planned('pro.connection.knockShare', '碰一碰分享连接',
    '确认后分享直连 SSH 信息，接收端自行认证并恢复文件目录。', 23);
  feature.availability = 'experimental';
  feature.protocols = ['ssh'];
  feature.capabilities = ['SystemCapability.Collaboration.HarmonyShare'];
  return feature;
}
function securityKeyRedirect(): ProFeature {
  const feature = planned('pro.security.webauthnRedirect', '安全密钥重定向',
    '在鸿蒙 PC 上插入 USB 安全密钥，供远程 Windows 里的网站和应用注册、登录；每次使用都先在本机确认。', 23);
  // Debug builds reach it through the experimental path; Release keeps it closed until device acceptance.
  feature.availability = 'experimental';
  feature.devices = ['pc'];
  feature.protocols = ['rdp'];
  feature.capabilities = ['SystemCapability.USB.USBManager'];
  return feature;
}
function personalization(): ProFeature {
  const feature = planned(PRO_PERSONALIZATION_FEATURE, '个性化方案',
    '自定义组合键（命名、按键序列、系统键与小键盘）与 SSH 终端皮肤：字体、配色、功能键栏和顶栏成套切换，也可以自由搭配。');
  feature.availability = 'available';
  return feature;
}
function proFeedback(): ProFeature {
  const feature = planned('pro.feedback', 'Pro 反馈',
    '加入 Pro 专属畅联群或 QQ 群，选择适合你的反馈渠道。');
  feature.availability = 'available';
  return feature;
}
function workspaces(): ProFeature {
  const feature = planned('pro.workspaces', '工作区与布局',
    '把常用的一组会话存成工作区，一键依次打开；SSH 可指定初始目录，PC 按保存的布局摆放窗口。需要鸿蒙 7（API 26）及以上。');
  feature.availability = 'available';
  feature.minApiVersion = 26;
  return feature;
}
function hostManagement(): ProFeature {
  const feature = planned('pro.hostManagement', '高级主机管理',
    '跨协议分组与标签、智能分组筛选、多选批量编辑与连通检测，以及不含密码的导入导出。需要鸿蒙 7（API 26）及以上。');
  feature.availability = 'available';
  feature.minApiVersion = 26;
  return feature;
}
function rdpAdvancedDisplay(): ProFeature {
  const feature = planned(PRO_RDP_ADVANCED_DISPLAY_FEATURE, 'RDP 高级显示方案',
    '自定义远端桌面宽高与 Windows 100–500% 界面缩放，并按设备保存显示方案。');
  feature.availability = 'available';
  feature.protocols = ['rdp'];
  feature.capabilities = ['rdp.displayControl'];
  return feature;
}
function rustDeskAdvancedDisplay(): ProFeature {
  const feature = planned(PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE, 'RustDesk 高级显示方案',
    '在已验证的远端显示器和权限条件下提交自定义分辨率，并回读实际应用结果。');
  feature.availability = 'available';
  feature.protocols = ['rustdesk'];
  feature.capabilities = ['rustdesk.displayControl'];
  return feature;
}
function aiAssistant(id: string, title: string, description: string): ProFeature {
  const feature = planned(id, title, description);
  feature.availability = 'available';
  return feature;
}
function remoteAi(id: string, title: string, description: string): ProFeature {
  const feature = planned(id, title, description);
  // The local LAN pairing/session path is shipped and guarded by the real
  // entitlement, device, protocol, capability and transport checks. Keep
  // RustDesk AI transport separately planned until its data channel exists.
  feature.availability = 'available';
  feature.protocols = ['ai'];
  return feature;
}
// Returned declarations are owned by the caller; UI cannot mutate the authority catalog.
export function proFeatures(): ProFeature[] {
  return [
    { id: 'core.connection', title: '完整的远程连接', description: '全部协议、正常画质与核心操作继续免费。',
      requiredEntitlementId: '', availability: 'available', minAppVersionCode: 0, minApiVersion: 0,
      devices: [], protocols: [], capabilities: [], permissions: [], serverAuthorized: false },
    // AI 助理 leads the catalog: it is what Pro is mostly about now.
    aiAssistant(PRO_DIAGNOSTICS_FEATURE, 'AI 助理',
      '聊天、助理诊断与 AI 语音：用你自己配置的 AI 回答问题、处理文档、管理 App 里的数据、排查连接，记下你的需求并整理成反馈邮件。'),
    aiAssistant(PRO_DIAGNOSTICS_PROVIDER_FEATURE, 'AI 服务配置', '配置 AI 服务、在本机安全存储里保存密钥，并拉取可用模型。'),
    aiAssistant(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, 'AI 入口与悬浮球',
      '在主页、设置和每种协议的连接中打开 AI：面板、悬浮球、小对话框与语音模式。'),
    aiAssistant(PRO_DIAGNOSTICS_EMAIL_FEATURE, '诊断与反馈邮件',
      '把诊断结论、详细分析和建议步骤整理成邮件，诊断日志作为附件，确认后在邮件应用里发送。'),
    workspaces(),
    hostManagement(),
    rdpAdvancedDisplay(),
    rustDeskAdvancedDisplay(),
    personalization(),
    remoteAi('pro.ai.workspace', '远程 AI 工作台', '在自己的电脑上运行 AI，查看执行过程、批准操作并恢复会话。'),
    remoteAi('pro.ai.codex', 'Codex 远程控制', '连接电脑端 Codex 插件，使用原生会话、审批与文件差异。'),
    remoteAi('pro.ai.dsh', 'DSH 远程控制', '连接电脑端 DSH 插件，使用已配置的模型与原生工具。'),
    planned('pro.ai.rustdeskTransport', 'AI 跨网连接', '后续通过自建 RustDesk 服务连接电脑上的 AI 工作台。'),
    appIcon(),
    knockTransfer(),
    connectionShare(),
    continuation(),
    proFeedback(),
    securityKeyRedirect(),
    planned('pro.security.phonePasskey', '手机通行密钥', '探索使用华为手机完成远端支持的认证。')
  ];
}
/** Where each feature stands in development and device acceptance; shown on the Pro page. */
export function proFeatureProgress(id: string): string {
  switch (id) {
    case 'pro.personalization.appIcon': return '已完成 · 实机验收通过 · 仅鸿蒙 7（API 26）及以上可用';
    case 'pro.connection.continuation': return '已完成 · 手机与平板实机验收通过（SSH、RDP、RustDesk、VNC）；PC 待验证';
    case 'pro.file.knockTransfer': return '已开发 · 等待鸿蒙 PC 实机验证，暂不开放';
    case 'pro.connection.knockShare': return '已开发 · 等待应用链接域名配置，暂不开放';
    case 'pro.ai.workspace':
    case 'pro.ai.codex':
    case 'pro.ai.dsh': return '已开发（局域网连接） · 实机验收暂缓';
    case 'pro.ai.rustdeskTransport': return '规划中 · 等待 RustDesk 数据通道';
    case 'pro.security.webauthnRedirect': return '开发中 · RDP 安全密钥通道已接入调试版，待鸿蒙 PC、安全密钥与 Windows 验收';
    case 'pro.security.phonePasskey': return '可行性研究中';
    case 'pro.personalization': return '已完成 · 实机验收通过（自定义组合键与 SSH 终端皮肤）';
    case 'pro.workspaces':
      return '已开发 · 试用开放 · 平板 SSH + RustDesk 实机通过；RustDesk + RDP 与 PC 窗口摆放待验收；手机默认关闭';
    case 'pro.hostManagement': return '已开发 · 试用开放 · 分组、标签、智能分组、批量操作与导入导出待实机验收';
    case PRO_RDP_ADVANCED_DISPLAY_FEATURE: return '已开发 · 试用开放 · RDP 自定义尺寸与 Windows 缩放待真实 Windows 矩阵验收';
    case PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE: return '已开发 · 试用开放 · 能力感知自定义分辨率待 RustDesk peer/设备矩阵验收';
    case 'pro.feedback': return '已上线 · 实机验收通过 · Pro 专属畅联群与 QQ 群';
    case PRO_DIAGNOSTICS_FEATURE:
      return '已上线（试用） · 聊天、助理诊断、AI 语音（Beta）、文档与数据管理、需求收集；更多服务商的实机验收进行中';
    case PRO_DIAGNOSTICS_PROVIDER_FEATURE: return '已上线（试用） · 多家服务商、本机安全存储密钥、模型列表';
    case PRO_DIAGNOSTICS_ASSISTANT_FEATURE: return '已上线（试用） · 主页、设置、PC 左下角与各协议连接中的入口，悬浮球与语音模式';
    case PRO_DIAGNOSTICS_EMAIL_FEATURE: return '已上线（试用） · 结构化诊断邮件与日志附件；各邮件应用的附件兼容性待实机验收';
    default: return '';
  }
}

export function proDevice(type: string): ProDevice {
  if (type === 'phone') { return 'phone'; }
  if (type === 'tablet') { return 'tablet'; }
  if (type === 'pc' || type === '2in1') { return 'pc'; }
  return 'unknown';
}
