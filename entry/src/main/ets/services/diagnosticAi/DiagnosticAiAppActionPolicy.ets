/**
 * The assistant never receives a route or an AppStorage key from a model. It only receives one of these typed
 * action ids, and the host/session surface maps the id to an existing UI module or callback. Keep this registry in
 * sync whenever a new settings sheet, protocol capability or session action is added.
 */
export type DiagnosticAiAppActionMode = 'execute' | 'floating' | 'inline';

export type DiagnosticAiAppActionId =
  | 'host.add' | 'cloud.sync' | 'diagnostic.log' | 'feedback' | 'ssh.keys' | 'rdp.credentials' | 'ai.config'
  | 'settings.account' | 'settings.appearance' | 'settings.wallpaper' | 'settings.haloColor'
  | 'settings.terminalColor' | 'settings.terminalFontSize' | 'settings.terminalSpacing' | 'settings.popup'
  | 'settings.keyboard' | 'settings.keyboardBehavior' | 'settings.keyboardShortcuts' | 'settings.keyboardFunctions'
  | 'settings.keyboardCustom' | 'settings.harmonyShortcut' | 'settings.secretVisibility'
  | 'settings.remotePortrait' | 'settings.remoteWheel' | 'settings.remotePinch' | 'settings.controlBar'
  | 'settings.rdpDisplay' | 'settings.sshSkin' | 'settings.diagnosticAi' | 'settings.aiHosts'
  | 'settings.aiDisplay' | 'settings.aiData' | 'settings.aiInstall'
  | 'settings.appIcon' | 'settings.keyVault' | 'settings.rdpCredentialEditor' | 'settings.proBadge'
  | 'diagnosticAi.assistant' | 'diagnosticAi.usage' | 'diagnosticAi.personalization' | 'diagnosticAi.sessions'
  | 'diagnosticAi.classicLogs'
  | 'settings.vncConnection' | 'settings.vncTimeout' | 'settings.vncSecurity' | 'settings.vncDisplay'
  | 'settings.vncInput' | 'settings.vncPerformance' | 'settings.vncClipboard' | 'settings.vncTrust'
  | 'settings.vncHosts' | 'settings.vncGateway'
  | 'settings.moonlightVideo' | 'settings.moonlightAudio' | 'settings.moonlightInput'
  | 'settings.moonlightNetwork' | 'settings.moonlightDiagnostics' | 'settings.moonlightTrust' | 'settings.moonlightData'
  | 'session.keyboard' | 'session.modifiers' | 'session.fileTransfer' | 'session.ctrlAltDel' | 'session.lock'
  | 'session.privacy' | 'session.audio' | 'session.clipboard' | 'session.filePaste' | 'session.resetCanvas'
  | 'session.rotate' | 'session.portrait' | 'session.display' | 'session.quality' | 'session.codec'
  | 'session.cursor' | 'session.browseMode' | 'session.relativeMouse' | 'session.reverseWheel'
  | 'session.swapButtons' | 'session.diagnostics' | 'session.disconnect';

export class DiagnosticAiAppAction {
  id: DiagnosticAiAppActionId;
  label: string;
  mode: DiagnosticAiAppActionMode;
  requiresConfirmation: boolean;

  constructor(id: DiagnosticAiAppActionId, label: string, mode: DiagnosticAiAppActionMode = 'execute',
    requiresConfirmation: boolean = false) {
    this.id = id; this.label = label; this.mode = mode; this.requiresConfirmation = requiresConfirmation;
  }
}

class ActionRule {
  id: DiagnosticAiAppActionId;
  label: string;
  groups: string[][];
  mode: DiagnosticAiAppActionMode;
  requiresConfirmation: boolean;

  constructor(id: DiagnosticAiAppActionId, label: string, groups: string[][],
    mode: DiagnosticAiAppActionMode = 'execute', requiresConfirmation: boolean = false) {
    this.id = id; this.label = label; this.groups = groups; this.mode = mode;
    this.requiresConfirmation = requiresConfirmation;
  }
}

const RULES: ActionRule[] = [
  new ActionRule('host.add', '打开添加主机', [['添加', '新建', '新增', '“+”', '"+"', '+'], ['主机', '连接', '协议', '设备']]),
  new ActionRule('cloud.sync', '打开云同步', [['云同步', '同步', '云端', '备份']], 'execute', true),
  new ActionRule('diagnostic.log', '查看诊断日志', [['日志', '诊断记录']], 'floating'),
  new ActionRule('feedback', '提交反馈', [['反馈', '联系开发', '联系我们']], 'execute', true),
  new ActionRule('ssh.keys', '打开 SSH 密钥库', [['密钥', '公钥', '私钥', 'key']]),
  new ActionRule('rdp.credentials', '管理 RDP 凭据', [['凭据', '账号密码', '用户名和密码', '登录凭证']], 'execute', true),
  new ActionRule('settings.appIcon', '打开应用图标设置', [['应用图标', '图标主题', '图标样式']]),
  new ActionRule('settings.keyVault', '打开密钥库', [['密钥库', 'SSH 密钥', '密钥管理']]),
  new ActionRule('settings.rdpCredentialEditor', '打开 RDP 凭据编辑器', [['RDP', '凭据'], ['编辑', '新增', '修改']],'execute', true),
  new ActionRule('settings.proBadge', '打开 Pro 标识设置', [['Pro 标识', 'Pro 徽章', '专业版标识']]),
  new ActionRule('ai.config', '打开 AI 配置', [['AI', 'ai', '模型', 'Provider', '服务商'], ['配置', '设置', '密钥', 'API Key', 'apikey']]),

  new ActionRule('settings.account', '打开账号设置', [['账号', '登录', '账户'], ['设置', '管理', '切换']]),
  new ActionRule('settings.appearance', '打开外观设置', [['外观', '主题', '颜色', '字体']]),
  new ActionRule('settings.wallpaper', '打开壁纸设置', [['壁纸', '背景']]),
  new ActionRule('settings.haloColor', '打开沉浸光晕设置', [['光晕', '沉浸光感', '光感']]),
  new ActionRule('settings.terminalColor', '打开终端颜色设置', [['终端', '文字颜色', '前景色']]),
  new ActionRule('settings.terminalFontSize', '打开终端字号设置', [['终端', '字号', '字体大小']]),
  new ActionRule('settings.terminalSpacing', '打开终端行距设置', [['终端', '行距', '行间距']]),
  new ActionRule('settings.popup', '打开弹窗设置', [['弹窗', '提示', '通知']]),
  new ActionRule('settings.keyboard', '打开虚拟键盘设置', [['虚拟键盘', '键盘']]),
  new ActionRule('settings.keyboardBehavior', '打开键盘行为设置', [['键盘', '行为', '回车', '退格']]),
  new ActionRule('settings.keyboardShortcuts', '打开键盘快捷键设置', [['键盘', '快捷键', '组合键']]),
  new ActionRule('settings.keyboardFunctions', '打开键盘功能键设置', [['键盘', '功能键', 'F1', 'F2']]),
  new ActionRule('settings.keyboardCustom', '打开自定义键盘设置', [['键盘', '自定义', '按键']]),
  new ActionRule('settings.harmonyShortcut', '打开鸿蒙快捷方式设置', [['鸿蒙', '系统快捷方式', '快捷方式']]),
  new ActionRule('settings.secretVisibility', '打开敏感信息显示设置', [['敏感信息', '密钥显示', '密码显示']], 'execute', true),
  new ActionRule('settings.remotePortrait', '打开竖屏显示设置', [['竖屏', '旋转', '纵向显示']]),
  new ActionRule('settings.remoteWheel', '打开滚轮方向设置', [['滚轮', '滚动方向']]),
  new ActionRule('settings.remotePinch', '打开双指缩放设置', [['双指', '捏合', '缩放']]),
  new ActionRule('settings.controlBar', '打开会话控制栏设置', [['控制栏', '会话栏', '工具栏显示']]),
  new ActionRule('settings.rdpDisplay', '打开 RDP 显示设置', [['RDP', '分辨率', '显示缩放']]),
  new ActionRule('settings.sshSkin', '打开 SSH 外观设置', [['SSH', '终端皮肤', '终端外观']]),
  new ActionRule('settings.diagnosticAi', '打开 AI 助理设置', [['AI 助理', 'AI助理', '诊断与 AI', '诊断AI', 'AI 帮助'], ['设置', '页面', '入口', '帮助']]),
  new ActionRule('settings.aiHosts', '打开远程 AI 主机设置', [['远程 AI', 'AI 主机', '电脑端 AI']]),
  new ActionRule('settings.aiDisplay', '打开远程 AI 显示设置', [['远程 AI', 'AI 显示', '显示入口']]),
  new ActionRule('settings.aiData', '打开远程 AI 数据设置', [['远程 AI', 'AI 数据', '数据策略']]),
  new ActionRule('settings.aiInstall', '打开远程 AI 安装设置', [['远程 AI', 'AI 安装', '安装电脑端']]),

  new ActionRule('settings.vncConnection', '打开 VNC 连接设置', [['VNC', '连接设置']]),
  new ActionRule('settings.vncTimeout', '打开 VNC 超时设置', [['VNC', '超时']]),
  new ActionRule('settings.vncSecurity', '打开 VNC 安全设置', [['VNC', '安全', 'TLS']]),
  new ActionRule('settings.vncDisplay', '打开 VNC 显示设置', [['VNC', '显示', '缩放']]),
  new ActionRule('settings.vncInput', '打开 VNC 输入设置', [['VNC', '输入', '鼠标', '触控']]),
  new ActionRule('settings.vncPerformance', '打开 VNC 性能设置', [['VNC', '性能', '帧率']]),
  new ActionRule('settings.vncClipboard', '打开 VNC 剪贴板设置', [['VNC', '剪贴板']]),
  new ActionRule('settings.vncTrust', '打开 VNC 信任设置', [['VNC', '信任', '证书']]),
  new ActionRule('settings.vncHosts', '打开 VNC 主机管理', [['VNC', '主机管理', '地址簿']]),
  new ActionRule('settings.vncGateway', '打开 VNC 网关设置', [['VNC', '网关', 'Repeater']]),
  new ActionRule('settings.moonlightVideo', '打开 Moonlight 画面设置', [['Moonlight', '画面', '视频']]),
  new ActionRule('settings.moonlightAudio', '打开 Moonlight 音频设置', [['Moonlight', '音频', '声音']]),
  new ActionRule('settings.moonlightInput', '打开 Moonlight 输入设置', [['Moonlight', '输入', '手柄']]),
  new ActionRule('settings.moonlightNetwork', '打开 Moonlight 网络设置', [['Moonlight', '网络', '安全']]),
  new ActionRule('settings.moonlightDiagnostics', '打开 Moonlight 诊断设置', [['Moonlight', '诊断', '性能']]),
  new ActionRule('settings.moonlightTrust', '打开 Moonlight 信任设置', [['Moonlight', '信任', '配对']]),
  new ActionRule('settings.moonlightData', '打开 Moonlight 数据设置', [['Moonlight', '数据', '同步']]),
  new ActionRule('diagnosticAi.assistant', '启动 AI 辅助', [['启动 AI 辅助', 'AI 助手', '询问 AI']]),
  new ActionRule('diagnosticAi.usage', '打开 AI 用量监控', [['AI 用量', 'Token 用量', '缓存命中', '费用估算']]),
  new ActionRule('diagnosticAi.personalization', '打开 AI 个性化设置', [['AI 个性化', '助手名字', '助手性格', '本地记忆']]),
  new ActionRule('diagnosticAi.sessions', '打开 AI 会话管理', [['AI 会话', '历史对话', '继续对话']]),
  new ActionRule('diagnosticAi.classicLogs', '打开传统日志抓取', [['传统日志', '手动抓日志', '导出诊断日志']]),

  new ActionRule('session.keyboard', '打开远程键盘', [['键盘', '打字', '输入']], 'inline'),
  new ActionRule('session.modifiers', '打开组合键面板', [['组合键', '修饰键', 'Ctrl', 'Alt', 'Shift']], 'inline'),
  new ActionRule('session.fileTransfer', '打开文件传输', [['文件传输', '传文件', '上传文件', '下载文件']], 'floating', true),
  new ActionRule('session.ctrlAltDel', '发送 Ctrl+Alt+Delete', [['Ctrl+Alt+Delete', 'Ctrl Alt Del', '安全登录']], 'execute', true),
  new ActionRule('session.lock', '锁定远程设备', [['锁定远程', '锁屏远程']], 'execute', true),
  new ActionRule('session.privacy', '切换隐私模式', [['隐私模式', '隐藏远端画面']], 'execute', true),
  new ActionRule('session.audio', '切换远程音频', [['远程音频', '声音']], 'inline'),
  new ActionRule('session.clipboard', '切换剪贴板', [['剪贴板同步', '远程剪贴板']], 'inline'),
  new ActionRule('session.filePaste', '切换文件粘贴', [['文件粘贴', '粘贴文件']], 'inline'),
  new ActionRule('session.resetCanvas', '重置画面位置', [['重置画面', '恢复画布', '画面位置']], 'inline'),
  new ActionRule('session.rotate', '旋转远程画面', [['旋转画面', '画面旋转']], 'inline'),
  new ActionRule('session.portrait', '切换竖屏显示', [['竖屏显示', '纵向显示']], 'inline'),
  new ActionRule('session.display', '打开远程显示选择', [['远程显示器', '显示器选择', '分辨率']], 'inline'),
  new ActionRule('session.quality', '打开画质设置', [['画质', '清晰度', '流畅度']], 'inline'),
  new ActionRule('session.codec', '打开编码设置', [['编码', 'H.264', 'H.265', 'AV1']], 'inline'),
  new ActionRule('session.cursor', '切换本地光标', [['本地光标', '鼠标光标']], 'inline'),
  new ActionRule('session.browseMode', '切换浏览模式', [['浏览模式', '查看模式']], 'inline'),
  new ActionRule('session.relativeMouse', '切换相对鼠标', [['相对鼠标', '相对模式']], 'inline'),
  new ActionRule('session.reverseWheel', '切换反向滚轮', [['反向滚轮', '滚轮反向']], 'inline'),
  new ActionRule('session.swapButtons', '切换鼠标按键', [['交换鼠标按键', '左右键']], 'inline'),
  new ActionRule('session.diagnostics', '打开会话诊断', [['会话诊断', '性能面板', '连接诊断']], 'floating'),
  new ActionRule('session.disconnect', '断开远程连接', [['断开连接', '退出远程会话']], 'execute', true)
];

/** Match only a predeclared action. Unknown model text remains explanatory text. */
export function diagnosticAiAppActionsForSteps(steps: string[]): DiagnosticAiAppAction[] {
  const found: DiagnosticAiAppAction[] = [];
  steps.forEach((step: string): void => {
    const text: string = step.toLowerCase();
    RULES.forEach((rule: ActionRule): void => {
      if (found.some((a: DiagnosticAiAppAction): boolean => a.id === rule.id)) { return; }
      const matches: boolean = rule.groups.every((words: string[]): boolean =>
        words.some((word: string): boolean => text.indexOf(word.toLowerCase()) >= 0));
      if (matches) { found.push(new DiagnosticAiAppAction(rule.id, rule.label, rule.mode, rule.requiresConfirmation)); }
    });
  });
  return found;
}

export function diagnosticAiAppActionLabel(id: DiagnosticAiAppActionId): string {
  const rule: ActionRule | undefined = RULES.find((r: ActionRule): boolean => r.id === id);
  return rule !== undefined ? rule.label : '执行操作';
}

export function diagnosticAiAppActionMode(id: DiagnosticAiAppActionId): DiagnosticAiAppActionMode {
  const rule: ActionRule | undefined = RULES.find((r: ActionRule): boolean => r.id === id);
  return rule === undefined ? 'inline' : rule.mode;
}

export function diagnosticAiAppActionRequiresConfirmation(id: DiagnosticAiAppActionId): boolean {
  const rule: ActionRule | undefined = RULES.find((r: ActionRule): boolean => r.id === id);
  return rule !== undefined && rule.requiresConfirmation;
}

/** Stable catalog injected into the Provider prompt; the model may only return one of these IDs. */
export function diagnosticAiAppActionCatalog(): string {
  return RULES.map((rule: ActionRule): string =>
    rule.id + '|' + rule.label + '|' + rule.mode + '|' + (rule.requiresConfirmation ? 'confirm' : 'direct')).join('\n');
}

export function diagnosticAiAppActionId(value: string): DiagnosticAiAppActionId | null {
  const rule: ActionRule | undefined = RULES.find((item: ActionRule): boolean => item.id === value.trim());
  return rule === undefined ? null : rule.id;
}
