export const PRO_LIFETIME: string = 'pro.lifetime';
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
    '在手机、平板和 PC 间重新认证同账号的主机并恢复目录或桌面视图。目前仅支持 RDP 和直连 SSH，RustDesk 与 VNC 计划后续支持。', 23);
  feature.availability = 'experimental';
  feature.devices = ['phone', 'tablet', 'pc']; feature.protocols = ['ssh', 'rdp'];
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
    planned('pro.workspaces', '工作区与布局', '保存常用会话组合，让每次开工更从容。'),
    planned('pro.hostManagement', '高级主机管理', '智能分组与批量配置，减少重复操作。'),
    planned('pro.personalization', '个性化方案', '多套工具栏、快捷键与外观方案。'),
    remoteAi('pro.ai.workspace', '远程 AI 工作台', '在自己的电脑上运行 AI，查看执行过程、批准操作并恢复会话。'),
    remoteAi('pro.ai.codex', 'Codex 远程控制', '连接电脑端 Codex 插件，使用原生会话、审批与文件差异。'),
    remoteAi('pro.ai.dsh', 'DSH 远程控制', '连接电脑端 DSH 插件，使用已配置的模型与原生工具。'),
    planned('pro.ai.rustdeskTransport', 'AI 跨网连接', '后续通过自建 RustDesk 服务连接电脑上的 AI 工作台。'),
    appIcon(),
    knockTransfer(),
    connectionShare(),
    continuation(),
    planned('pro.security.webauthnRedirect', '安全密钥重定向', '在支持的 RDP 会话中使用本地安全密钥。'),
    planned('pro.security.phonePasskey', '手机通行密钥', '探索使用华为手机完成远端支持的认证。')
  ];
}
export function proDevice(type: string): ProDevice {
  if (type === 'phone') { return 'phone'; }
  if (type === 'tablet') { return 'tablet'; }
  if (type === 'pc' || type === '2in1') { return 'pc'; }
  return 'unknown';
}
