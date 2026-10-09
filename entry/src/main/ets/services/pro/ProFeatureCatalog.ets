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
    '在手机、平板或鸿蒙 PC 上插入 USB 安全密钥（或使用配对手机的通行密钥），供远程 Windows 里的网站和应用注册、登录；' +
    '每次使用都先在本机确认。', 23);
  // Debug builds reach it through the experimental path; Release keeps it closed until device acceptance. Phones and
  // tablets too (2026-10-07): a USB-C key plugs in there as well, and the paired-phone path needs no USB at all.
  feature.availability = 'experimental';
  feature.devices = ['phone', 'tablet', 'pc'];
  feature.protocols = ['rdp'];
  feature.capabilities = ['SystemCapability.USB.USBManager'];
  return feature;
}
function phonePasskey(): ProFeature {
  const feature = planned('pro.security.phonePasskey', '手机通行密钥',
    '原型：用同一华为账号的手机作为通行密钥，确认后验证人脸、指纹或锁屏密码，完成其他设备上的注册和登录。', 23);
  // Debug prototype only (experimental); Release keeps it closed.
  feature.availability = 'experimental';
  return feature;
}
function personalization(): ProFeature {
  const feature = planned(PRO_PERSONALIZATION_FEATURE, '个性化方案',
    '自定义组合键（命名、按键序列、系统键与小键盘）与 SSH 终端皮肤：字体、配色、功能键栏和顶栏成套切换，也可以自由搭配。');
  feature.availability = 'available';
  return feature;
}
/**
 * Pro 反馈 (the Pro-only 畅联群 and QQ 群) is closed to users for now (2026-10-09): it is left out of the catalog, so
 * its 反馈 tab and its Pro listings do not show. The groups stay ready behind this switch.
 */
export const PRO_FEEDBACK_OPEN: boolean = false;
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
function hostHealth(): ProFeature {
  const feature = planned('pro.hostHealth', '主机健康中心',
    '看懂主机为什么连不上：找不到主机、端口不通、超时、证书或指纹需要确认、对端不在线，分别用白话说明并给出下一步；保留每台主机最近 20 次检测记录，支持批量检测，AI 助理也能解读。');
  feature.availability = 'available';
  feature.protocols = ['rdp', 'ssh', 'vnc', 'rustdesk'];
  return feature;
}
function sessionEvidence(): ProFeature {
  const feature = planned('pro.session.evidence', '截屏给 AI 看与诊断证据包',
    '在 RDP、RustDesk、VNC、Moonlight 会话里截下远端画面：本机识别画面里的文字，你确认后交给 AI 解读报错；也可以保存到图库，' +
    '或把截图、会话摘要和诊断时间线打包分享、发给开发者。SSH 可以把终端屏幕上的文字交给 AI。图片不会自动上传。');
  feature.availability = 'available';
  feature.protocols = ['rdp', 'rustdesk', 'vnc', 'moonlight', 'ssh'];
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
    hostHealth(),
    sessionEvidence(),
    rdpAdvancedDisplay(),
    rustDeskAdvancedDisplay(),
    personalization(),
    remoteAi('pro.ai.workspace', '远程 AI 工作台', '在自己的电脑上运行 AI（Codex、DSH、Pi），查看执行过程、批准操作并恢复会话；目前限同一局域网。'),
    remoteAi('pro.ai.codex', 'Codex 远程控制', '连接电脑端 Codex 插件，使用原生会话、审批与文件差异。'),
    remoteAi('pro.ai.dsh', 'DSH 远程控制', '连接电脑端 DSH 插件，使用已配置的模型与原生工具。'),
    remoteAi('pro.ai.pi', 'Pi 远程控制',
      '连接电脑端 Pi 插件，使用电脑上已登录的模型，继续 Pi 与 pi-gui 里的对话，权限分只读、修改前询问、完全访问三档。'),
    planned('pro.ai.rustdeskTransport', 'AI 跨网连接', '后续通过自建 RustDesk 服务连接电脑上的 AI 工作台。'),
    appIcon(),
    knockTransfer(),
    connectionShare(),
    continuation(),
    ...(PRO_FEEDBACK_OPEN ? [proFeedback()] : []),
    securityKeyRedirect(),
    phonePasskey()
  ];
}
/**
 * Where each feature stands in development and device acceptance; shown on the Pro page and given to the AI (its
 * knowledge lists every feature with this text). A feature that is not finished says why, in plain words.
 */
export function proFeatureProgress(id: string): string {
  switch (id) {
    case 'pro.personalization.appIcon': return '已完成 · 实机验收通过 · 系统要求鸿蒙 7（API 26）及以上，更低版本不显示';
    case 'pro.connection.continuation':
      return '已上线（试用） · 手机与平板实机验收通过（SSH、RDP、RustDesk、VNC） · PC 端待验证：作者还没有鸿蒙 PC 真机';
    case 'pro.file.knockTransfer':
      return '已开发 · 暂不开放：碰一碰要在鸿蒙 PC 真机上验证，作者还没有真机，模拟器也不支持碰一碰';
    case 'pro.connection.knockShare':
      return '已开发 · 暂不开放：需要先在华为开发者后台配置应用链接（App Linking）域名，目前还没有配置';
    case 'pro.ai.workspace':
    case 'pro.ai.codex':
    case 'pro.ai.dsh':
      return '已开发（局域网连接） · 试用开放 · 排在 Pi 之后，电脑端插件的真实对话验收还没有做，使用中可能遇到问题';
    case 'pro.ai.pi': return '已开发（局域网连接） · 试用开放 · 电脑端插件已通过真实对话验收 · 手机端实机验收进行中';
    case 'pro.ai.rustdeskTransport': return '规划中 · 还不能用：RustDesk 的数据通道尚未接入，目前只能在同一局域网内连接电脑上的 AI';
    case 'pro.security.webauthnRedirect':
      return '开发中 · 仅调试版：需要用实体 USB 安全密钥和远程 Windows 逐项验证注册、登录，验收完成前正式版不开放';
    case 'pro.security.phonePasskey':
      return '原型 · 仅调试版：目前只能在本应用内测试注册与登录，还不能给普通网站和其他应用使用；RDP 接入待鸿蒙 PC 真机验收';
    case 'pro.personalization': return '已完成 · 实机验收通过（自定义组合键与 SSH 终端皮肤）';
    case 'pro.workspaces':
      return '已上线（试用） · 平板 SSH + RustDesk 实机通过 · PC 按布局摆放窗口待验证（作者还没有鸿蒙 PC 真机） · 手机屏幕小，默认关闭';
    case 'pro.hostHealth':
      return '已开发 · 试用开放 · 覆盖 RDP、SSH、VNC、RustDesk，Moonlight 稍后接入 · 待手机、平板、PC 验收';
    case 'pro.session.evidence':
      return '已开发 · 试用开放 · RDP、RustDesk、VNC、Moonlight 截屏与 SSH 屏幕文字可用 · 识别文字依赖系统的本机文字识别，' +
        '不支持的设备只能保存和打包 · 待手机、平板、PC 验收';
    case 'pro.hostManagement': return '已上线（试用） · 分组、标签、批量操作与导入导出在手机、平板和鸿蒙 PC 模拟器上验收通过';
    case PRO_RDP_ADVANCED_DISPLAY_FEATURE:
      return '已上线（试用） · 自定义尺寸与 Windows 缩放已在作者的 Windows 上可用；不同 Windows 版本和显示器组合还在逐一验证';
    case PRO_RUSTDESK_ADVANCED_DISPLAY_FEATURE:
      return '已上线（试用） · 能否改分辨率取决于被控端的 RustDesk 版本、显示器和权限，各种组合还在逐一验证';
    case 'pro.feedback': return '暂不开放 · Pro 专属畅联群与 QQ 群已准备好，开放时间另行通知';
    case PRO_DIAGNOSTICS_FEATURE:
      return '已上线（试用） · 聊天、助理诊断、AI 语音（Beta）、文档与数据管理、需求收集 · 各家 AI 服务的接口不完全一样，仍在逐家实测';
    case PRO_DIAGNOSTICS_PROVIDER_FEATURE: return '已上线（试用） · 多家服务商、本机安全存储密钥、模型列表';
    case PRO_DIAGNOSTICS_ASSISTANT_FEATURE: return '已上线（试用） · 主页、设置、PC 左下角与各协议连接中的入口，悬浮球与语音模式';
    case PRO_DIAGNOSTICS_EMAIL_FEATURE:
      return '已上线（试用） · 结构化诊断邮件与日志附件 · 各家邮件应用处理附件的方式不同，兼容性仍在逐个实测';
    default: return '';
  }
}

/** Every Pro feature with its state, one line each: what the AI knows about Pro (kept with the Pro page text). */
export function proFeatureStatusKnowledge(): string {
  const lines: string[] = [];
  for (const feature of proFeatures()) {
    if (feature.id === 'core.connection') { continue; }
    const progress: string = proFeatureProgress(feature.id);
    lines.push('- ' + feature.title + '：' + feature.description + (progress.length > 0 ? '（状态：' + progress + '）' : ''));
  }
  return lines.join('\n');
}

export function proDevice(type: string): ProDevice {
  if (type === 'phone') { return 'phone'; }
  if (type === 'tablet') { return 'tablet'; }
  if (type === 'pc' || type === '2in1') { return 'pc'; }
  return 'unknown';
}
