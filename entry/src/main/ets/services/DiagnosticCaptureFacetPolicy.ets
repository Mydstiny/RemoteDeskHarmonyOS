import { DiagnosticModuleId, normalizeDiagnosticModules } from './DiagnosticCapturePolicy';

/**
 * 日志子模块: a finer selection inside the capture modules, so a capture (and what the AI reads of it) covers just the
 * part of the app a problem is about. Each event code of the catalog belongs to exactly one sub-module; selecting a
 * sub-module turns on its module for capture, and the AI bundle keeps only the selected sub-modules' events (plus the
 * capture's own start/stop markers). The export contract of a capture is unchanged: the runtime still records whole
 * modules, the narrowing happens when the bundle is made.
 */
export class DiagnosticCaptureFacet {
  id: string;
  moduleId: DiagnosticModuleId;
  label: string;
  /** What it covers, for the user and the model. */
  detail: string;
  events: string[];
  /** Words in a question that point at this sub-module (local fallback when no model plan is available). */
  hints: string[];

  constructor(id: string, moduleId: DiagnosticModuleId, label: string, detail: string, events: string[], hints: string[]) {
    this.id = id;
    this.moduleId = moduleId;
    this.label = label;
    this.detail = detail;
    this.events = events;
    this.hints = hints;
  }
}

const FACETS: DiagnosticCaptureFacet[] = [
  new DiagnosticCaptureFacet('app.lifecycle', 'core.app', '应用前后台', '应用切到后台、回到前台、画中画与分屏',
    ['app_lifecycle'], ['后台', '切回', '画中画', '分屏', '闪退', '崩溃', '重启']),
  new DiagnosticCaptureFacet('app.faults', 'core.app', '闪退与卡死', '最近 7 天的闪退、卡死次数与本次运行的未捕获异常',
    ['app_fault_history', 'app_exception'], ['闪退', '崩溃', '卡死', '无响应', '打不开', '白屏']),
  new DiagnosticCaptureFacet('app.window', 'core.app', '窗口与方向', '屏幕旋转、横竖屏请求与窗口尺寸',
    ['window_orientation_request', 'window_orientation_state'], ['旋转', '横屏', '竖屏', '方向', '窗口']),

  new DiagnosticCaptureFacet('rdp.connect', 'connection.rdp', 'RDP 连接与断开',
    '连接请求、计算机名解析（DNS、域名后缀、局域网）、状态变化、失败原因类别与断开',
    ['rdp_connection_request', 'rdp_name_resolution', 'rdp_state_changed', 'rdp_disconnect', 'rdp_failure'],
    ['rdp', 'windows', '远程桌面', '连不上', '失败', 'tcp', '超时', '断开', '掉线', '解析', '计算机名', '主机名', '域名']),
  new DiagnosticCaptureFacet('rdp.security', 'connection.rdp', 'RDP 证书与认证',
    '证书预检（含是否只支持旧版 TLS）、你对证书的选择、旧版 TLS / TLS 登录的选择与恢复、NLA/凭据相关失败',
    ['rdp_preflight', 'rdp_certificate', 'rdp_security_choice'],
    ['证书', '认证', '密码', 'nla', 'tls', '凭据', '旧版', '降级', 'win7', 'windows 7', '2008']),
  new DiagnosticCaptureFacet('rdp.devices', 'connection.rdp', 'RDP 剪贴板、驱动器与音频', '剪贴板通道、驱动器映射与远程音频的启用结果',
    ['rdp_clipboard', 'rdp_drive', 'rdp_audio'], ['剪贴板', '复制', '粘贴', '驱动器', '共享文件夹', '声音', '音频']),
  new DiagnosticCaptureFacet('rdp.display', 'connection.rdp', 'RDP 画面与性能',
    '帧率、解码、延迟、分辨率、显示布局，以及 GFX 能力协商与实际线上编码（RemoteFX/H.264）',
    ['rdp_runtime_snapshot', 'rdp_display_layout', 'rdp_graphics_negotiation'],
    ['rdp', '黑屏', '花屏', '卡顿', '延迟', '画面', '分辨率', '模糊', '帧率', 'h264', 'h.264', 'gfx',
      'remotefx', '编码', '流量']),

  new DiagnosticCaptureFacet('rustdesk.connect', 'connection.rustdesk', 'RustDesk 连接',
    '预检、连接请求、二次验证、直连阶段（地址来源/地址类别/TCP/登录）、失败原因类别、状态变化与断开',
    ['rustdesk_preflight', 'rustdesk_connection_request', 'rustdesk_state_changed', 'rustdesk_two_factor',
      'rustdesk_disconnect', 'rustdesk_failure', 'rustdesk_direct_stage'],
    ['rustdesk', '连不上', '验证码', '二次验证', '批准', '断开', '掉线', 'id', '直连', 'easytier',
      '虚拟网', 'zerotier', 'tailscale', 'ip']),
  new DiagnosticCaptureFacet('rustdesk.presence', 'connection.rustdesk', 'RustDesk 在线检测', '主机在线状态探测',
    ['rustdesk_presence'], ['在线', '离线', '在线检测']),
  new DiagnosticCaptureFacet('rustdesk.clipboard', 'connection.rustdesk', 'RustDesk 剪贴板', '剪贴板同步通道的启用结果',
    ['rustdesk_clipboard'], ['剪贴板', '复制', '粘贴']),
  new DiagnosticCaptureFacet('rustdesk.display', 'connection.rustdesk', 'RustDesk 画面与性能',
    '首帧耗时、帧率、编码、显示器切换，画面方向（解码器证据、PC 上的方向自检与自动纠正、你的日志标记），以及画质切换请求和远端码率是否变化',
    ['rustdesk_runtime_snapshot', 'rustdesk_display_switch', 'rustdesk_orientation_observation', 'rustdesk_first_frame',
      'rustdesk_quality_request', 'rustdesk_quality_result'],
    ['rustdesk', '黑屏', '卡顿', '延迟', '画面', '编码', '显示器', '模糊', '画质', '清晰', '码率', '颠倒', '倒置', '翻转',
      '镜像', '反了']),

  new DiagnosticCaptureFacet('ssh.session', 'connection.ssh_sftp', 'SSH 会话', '预检、认证、失败原因类别、会话状态与断开',
    ['ssh_session_event', 'ssh_preflight', 'ssh_disconnect', 'ssh_runtime_snapshot', 'ssh_failure'],
    ['ssh', '终端', '连不上', '认证', '指纹', '断开', '掉线', '卡顿']),
  new DiagnosticCaptureFacet('sftp.transfer', 'connection.ssh_sftp', 'SFTP 文件传输', '上传下载任务的开始、结果与失败原因',
    ['sftp_task_started', 'sftp_task_completed', 'sftp_failure'], ['sftp', '上传', '下载', '文件', '传输']),

  new DiagnosticCaptureFacet('vnc.connect', 'connection.vnc', 'VNC 连接', '连接请求、预检、失败原因类别、状态变化与断开',
    ['vnc_connection_request', 'vnc_preflight', 'vnc_state_changed', 'vnc_disconnect', 'vnc_failure'],
    ['vnc', '连不上', '认证', '断开', '掉线']),
  new DiagnosticCaptureFacet('vnc.display', 'connection.vnc', 'VNC 画面', '画面更新进度、被拒绝的更新与运行状态',
    ['vnc_update_rejected', 'vnc_update_progress', 'vnc_runtime_snapshot'], ['vnc', '黑屏', '卡顿', '画面', '花屏']),

  new DiagnosticCaptureFacet('moonlight.pairing', 'connection.moonlight', 'Moonlight 配对与应用', '配对与主机应用列表',
    ['moonlight_pair', 'moonlight_catalog'], ['moonlight', '配对', 'pin', '应用列表']),
  new DiagnosticCaptureFacet('moonlight.stream', 'connection.moonlight', 'Moonlight 串流', '启动串流、状态变化、性能与方向',
    ['moonlight_launch', 'moonlight_state_changed', 'moonlight_runtime_snapshot', 'moonlight_orientation_observation'],
    ['moonlight', '串流', '游戏', '卡顿', '延迟', '黑屏']),

  new DiagnosticCaptureFacet('cloud.sync', 'data.cloud_sync', '云同步', '同步请求、开始、完成、重试与跳过',
    ['cloud_sync_requested', 'cloud_sync_started', 'cloud_sync_completed', 'cloud_sync_retry', 'cloud_sync_skipped'],
    ['同步', '云', '多设备', '丢失', '不一致']),
  new DiagnosticCaptureFacet('store.database', 'data.local_store', '本地数据库', '数据库初始化、迁移与写入',
    ['local_store_init', 'local_store_rebind', 'local_store_schema', 'local_store_mutation'],
    ['数据', '保存', '主机丢失', '数据库', '存不上']),
  new DiagnosticCaptureFacet('store.backup', 'data.local_store', '备份与恢复', '导出备份与从备份恢复',
    ['local_backup_export', 'local_backup_restore'], ['备份', '恢复', '导出', '导入']),

  new DiagnosticCaptureFacet('routing.gateway', 'network.routing', 'RDP/VNC 网关', 'RDP 网关与 VNC 网关路由',
    ['routing_rdp_gateway', 'routing_vnc_gateway'], ['网关', 'gateway']),
  new DiagnosticCaptureFacet('routing.relay', 'network.routing', 'RustDesk 中继', '中继服务器与 RustDesk Pro 路由',
    ['routing_rustdesk_relay', 'routing_rustdesk_pro'], ['中继', 'relay', '服务器', 'pro']),
  new DiagnosticCaptureFacet('routing.ssh', 'network.routing', 'SSH 代理与转发', 'SSH 代理跳板与端口转发',
    ['routing_ssh_proxy', 'routing_ssh_forwarding'], ['代理', '跳板', '转发', '端口']),

  new DiagnosticCaptureFacet('account.login', 'core.account', '华为账号登录', '手动登录、静默恢复与离线恢复的结果和错误码',
    ['account_login'], ['登录', '账号', '华为账号', '登不上']),
  new DiagnosticCaptureFacet('ai.request', 'core.ai', 'AI 请求与配置', 'AI 服务请求的结果、耗时、HTTP 状态与失败类别，AI 配置问题',
    ['ai_request', 'ai_config'], ['ai', '助手', '模型', 'api', 'key', '超时', '连不上']),
  new DiagnosticCaptureFacet('ai.actions', 'core.ai', 'AI 执行的操作', 'AI 一键修改设置的结果',
    ['ai_setting'], ['ai', '助手', '设置', '没生效']),
  new DiagnosticCaptureFacet('keys.manage', 'security.ssh_key', 'SSH 密钥管理', '生成、导入、检查、口令、存储与删除密钥',
    ['ssh_key_generate', 'ssh_key_import', 'ssh_key_inspect', 'ssh_key_passphrase', 'ssh_key_store', 'ssh_key_delete'],
    ['密钥', '私钥', '公钥', '导入', '口令']),
  new DiagnosticCaptureFacet('keys.auth', 'security.ssh_key', 'SSH 密钥认证', '安装公钥与密钥登录测试',
    ['ssh_key_install', 'ssh_key_auth_test'], ['密钥登录', '公钥', '认证', 'authorized_keys'])
];

/** Durations the AI plan may ask for (a subset of the capture's allowed durations). */
const PLAN_DURATIONS: number[] = [1, 3, 5, 10];

export function diagnosticCaptureFacets(): DiagnosticCaptureFacet[] { return FACETS.slice(); }

export function diagnosticCaptureFacet(id: string): DiagnosticCaptureFacet | undefined {
  return FACETS.find((facet: DiagnosticCaptureFacet): boolean => facet.id === id);
}

/** Known sub-module ids only, de-duplicated, in catalog order. */
export function normalizeDiagnosticFacets(ids: string[]): string[] {
  return FACETS.filter((facet: DiagnosticCaptureFacet): boolean => ids.indexOf(facet.id) >= 0)
    .map((facet: DiagnosticCaptureFacet): string => facet.id);
}

/** The capture modules a selection of sub-modules needs (应用状态 is always on). */
export function diagnosticModulesForFacets(ids: string[]): DiagnosticModuleId[] {
  const modules: string[] = [];
  normalizeDiagnosticFacets(ids).forEach((id: string): void => {
    const facet: DiagnosticCaptureFacet | undefined = diagnosticCaptureFacet(id);
    if (facet !== undefined && modules.indexOf(facet.moduleId) < 0) { modules.push(facet.moduleId); }
  });
  return normalizeDiagnosticModules(modules);
}

/** Whether an event belongs to the selection (the capture's own markers always do; no selection keeps everything). */
export function diagnosticEventInFacets(moduleId: string, eventCode: string, ids: string[]): boolean {
  if (ids.length === 0) { return true; }
  if (moduleId === 'core.app' && eventCode.indexOf('capture_') === 0) { return true; }
  return FACETS.some((facet: DiagnosticCaptureFacet): boolean => ids.indexOf(facet.id) >= 0 &&
    facet.moduleId === moduleId && facet.events.indexOf(eventCode) >= 0);
}

export function diagnosticPlanDurations(): number[] { return PLAN_DURATIONS.slice(); }

export function normalizeDiagnosticPlanDuration(minutes: number): number {
  if (PLAN_DURATIONS.indexOf(minutes) >= 0) { return minutes; }
  return PLAN_DURATIONS.reduce((best: number, value: number): number =>
    Math.abs(value - minutes) < Math.abs(best - minutes) ? value : best, 3);
}

/** The sub-module catalog for the model: id|名称|覆盖内容. */
export function diagnosticFacetCatalog(): string {
  return FACETS.map((facet: DiagnosticCaptureFacet): string => facet.id + '|' + facet.label + '|' + facet.detail).join('\n');
}

/**
 * Local plan when no model plan is available: sub-modules whose hints the question mentions, preferring the protocol
 * it names; at least the app's own lifecycle.
 */
export function diagnosticFacetsForQuestion(question: string): string[] {
  const value: string = question.toLowerCase();
  const protocols: string[] = ['rdp', 'rustdesk', 'ssh', 'sftp', 'vnc', 'moonlight'];
  const named: string[] = protocols.filter((name: string): boolean => value.indexOf(name) >= 0);
  const picked: string[] = FACETS.filter((facet: DiagnosticCaptureFacet): boolean => {
    const prefix: string = facet.id.split('.')[0];
    if (named.length > 0 && protocols.indexOf(prefix) >= 0 && named.indexOf(prefix) < 0) { return false; }
    return facet.hints.some((hint: string): boolean => value.indexOf(hint.toLowerCase()) >= 0);
  }).map((facet: DiagnosticCaptureFacet): string => facet.id);
  if (picked.indexOf('app.lifecycle') < 0) { picked.unshift('app.lifecycle'); }
  return normalizeDiagnosticFacets(picked).slice(0, 8);
}
