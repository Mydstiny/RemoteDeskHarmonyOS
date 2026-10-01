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
    '选择随应用提供的白底版或透明底版图标，随时恢复默认。', 26);
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
  feature.availability = 'experimental';
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
function personalization(): ProFeature {
  const feature = planned(PRO_PERSONALIZATION_FEATURE, '个性化方案',
    '自定义组合键（命名、按键序列、系统键与小键盘）与 SSH 终端皮肤：字体、配色、功能键栏和顶栏成套切换，也可以自由搭配。');
  feature.availability = 'experimental';
  return feature;
}
function proFeedback(): ProFeature {
  const feature = planned('pro.feedback', 'Pro 反馈',
    '加入 Pro 专属畅联群或 QQ 群，选择适合你的反馈渠道。');
  feature.availability = 'available';
  return feature;
}
function experimentalWorkspace(): ProFeature {
  const feature = planned('pro.workspaces', '工作区与布局',
    '把常用的一组会话存成工作区，一键依次打开；SSH 可指定初始目录，PC 按保存的布局摆放窗口。');
  feature.availability = 'experimental';
  feature.minApiVersion = 26;
  return feature;
}
function experimentalHostManagement(): ProFeature {
  const feature = planned('pro.hostManagement', '高级主机管理',
    '跨协议分组与标签、智能分组筛选、多选批量编辑与连通检测，以及不含密码的导入导出。');
  feature.availability = 'experimental';
  feature.minApiVersion = 26;
  return feature;
}
function rdpAdvancedDisplay(): ProFeature {
  const feature = planned(PRO_RDP_ADVANCED_DISPLAY_FEATURE, 'RDP 高级显示方案',
    '自定义远端桌面宽高与 Windows 100–500% 界面缩放，并按设备保存显示方案。');
  feature.availability = 'experimental';
  feature.protocols = ['rdp'];
  feature.capabilities = ['rdp.displayControl'];
  return feature;
}
function rustDeskAdvancedDisplay(): ProFeature {
  const feature = planned(PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE, 'RustDesk 高级显示方案',
    '在已验证的远端显示器和权限条件下提交自定义分辨率，并回读实际应用结果。');
  feature.availability = 'experimental';
  feature.protocols = ['rustdesk'];
  feature.capabilities = ['rustdesk.displayControl'];
  return feature;
}
function diagnosticsFeature(id: string, title: string, description: string): ProFeature {
  const feature = planned(id, title, description);
  feature.availability = 'experimental';
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
    experimentalWorkspace(),
    experimentalHostManagement(),
    rdpAdvancedDisplay(),
    rustDeskAdvancedDisplay(),
    diagnosticsFeature(PRO_DIAGNOSTICS_FEATURE, '诊断与 AI 帮助', '使用自有 AI Provider 分析脱敏诊断事件，并保留传统日志抓取。'),
    diagnosticsFeature(PRO_DIAGNOSTICS_PROVIDER_FEATURE, '辅助 AI 配置', '配置国内 AI Provider、保存设备级密钥并拉取模型列表。'),
    diagnosticsFeature(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, '启动 AI 辅助', '在应用内打开 AI 浮窗、生成诊断建议并预览可控设置操作。'),
    diagnosticsFeature(PRO_DIAGNOSTICS_EMAIL_FEATURE, '诊断邮件打包', '预览脱敏日志和诊断结果后调用系统邮件编辑器。'),
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
    planned('pro.security.webauthnRedirect', '安全密钥重定向', '在支持的 RDP 会话中使用本地安全密钥。'),
    planned('pro.security.phonePasskey', '手机通行密钥', '探索使用华为手机完成远端支持的认证。')
  ];
}
/** Where each feature stands in development and device acceptance; shown on the Pro page. */
export function proFeatureProgress(id: string): string {
  switch (id) {
    case 'pro.personalization.appIcon': return '已完成 · 手机实机验收通过';
    case 'pro.connection.continuation': return '已完成 · 手机与平板实机验收通过（SSH、RDP、RustDesk、VNC）；PC 待验证';
    case 'pro.file.knockTransfer': return '已开发 · 等待鸿蒙 PC 实机验证';
    case 'pro.connection.knockShare': return '已开发 · 等待应用链接域名配置后验证';
    case 'pro.ai.workspace':
    case 'pro.ai.codex':
    case 'pro.ai.dsh': return '已开发（局域网连接） · 实机验收暂缓';
    case 'pro.ai.rustdeskTransport': return '规划中 · 等待 RustDesk 数据通道';
    case 'pro.security.webauthnRedirect': return '开发中 · USB 安全密钥能力探测通过，待硬件与 RDP 验证';
    case 'pro.security.phonePasskey': return '可行性研究中';
    case 'pro.personalization': return '已开发 · 自定义组合键与 SSH 终端皮肤待实机验收';
    case 'pro.workspaces': return '已开发 · 依次打开、布局编辑与 PC 窗口摆放待实机验收';
    case 'pro.hostManagement': return '已开发 · 分组、标签、智能分组、批量操作与导入导出待实机验收';
    case PRO_RDP_ADVANCED_DISPLAY_FEATURE: return '已开发 · RDP 自定义尺寸与 Windows 缩放待真实 Windows 矩阵验收';
    case PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE: return '已开发 · 能力感知自定义分辨率待 RustDesk peer/设备矩阵验收';
    case 'pro.feedback': return '已上线 · Pro 专属畅联群与 QQ 群';
    case PRO_DIAGNOSTICS_FEATURE:
    case PRO_DIAGNOSTICS_PROVIDER_FEATURE:
    case PRO_DIAGNOSTICS_ASSISTANT_FEATURE:
    case PRO_DIAGNOSTICS_EMAIL_FEATURE: return '已实现基础链路 · Provider、邮件与实机验收待完成';
    default: return '';
  }
}

export function proDevice(type: string): ProDevice {
  if (type === 'phone') { return 'phone'; }
  if (type === 'tablet') { return 'tablet'; }
  if (type === 'pc' || type === '2in1') { return 'pc'; }
  return 'unknown';
}
