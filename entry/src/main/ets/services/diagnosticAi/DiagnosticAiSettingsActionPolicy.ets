import { hilog } from '@kit.PerformanceAnalysisKit';
import { recordDiagnosticEvent } from '../DiagnosticCaptureRuntime';
import { DiagnosticAiSettingProposal } from './DiagnosticAiModels';

/** One value a setting can take: what is stored and what the user reads. */
export class AiSettingChoice {
  value: string;
  label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

/**
 * A user setting the assistant may change. `key` is where its live value is read (AppStorage), unless the host page
 * reports it through the bridge. Credentials, addresses, certificates/TLS, proxies, VPN, accounts, payment and
 * security locks are deliberately absent: the assistant can only point the user to those screens.
 */
export class AiSettingSpec {
  id: string;
  label: string;
  key: string;
  choices: AiSettingChoice[];
  /** What it does, for the model (one short line). */
  note: string;

  constructor(id: string, label: string, key: string, choices: AiSettingChoice[], note: string = '') {
    this.id = id;
    this.label = label;
    this.key = key;
    this.choices = choices;
    this.note = note;
  }

  isBoolean(): boolean { return this.choices.length === 2 && this.choices[0].value === 'true'; }
}

function onOff(): AiSettingChoice[] { return [new AiSettingChoice('true', '开启'), new AiSettingChoice('false', '关闭')]; }
function choices(pairs: string[][]): AiSettingChoice[] {
  return pairs.map((pair: string[]): AiSettingChoice => new AiSettingChoice(pair[0], pair[1]));
}
function toggle(id: string, label: string, key: string, note: string = ''): AiSettingSpec {
  return new AiSettingSpec(id, label, key, onOff(), note);
}

const CONTROL_MODES: string[][] = [['0', '触控板'], ['1', '触控'], ['2', '键鼠']];

const SETTINGS: AiSettingSpec[] = [
  // 外观与主机列表
  new AiSettingSpec('ui.theme', '外观模式', 'currentTheme',
    choices([['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']])),
  toggle('ui.ambientLightEffect', '沉浸光感', 'ambientLightEffectEnabled', '玻璃与光晕效果'),
  toggle('ui.groupedHostCards', '主机分组卡片', 'groupedHostCards', '按协议把主机收进分组卡片'),
  toggle('ui.hostCardSensitiveHidden', '主机卡片隐藏连接信息', 'hostCardSensitiveInfoHidden', '卡片上不显示地址与用户名'),
  toggle('ui.liveViewEnabled', '实时视图', 'liveViewEnabled'),
  new AiSettingSpec('ui.hostAddMode', '添加主机样式', 'hostAddMode', choices([['modern', '新版'], ['classic', '经典']])),
  new AiSettingSpec('ui.virtualMouseStyle', '虚拟鼠标样式', 'virtualMouseStyle', choices([['circle', '圆形'], ['arrow', '箭头']])),
  // RDP
  toggle('rdp.audioEnabled', 'RDP 远程音频', 'rdpAudioEnabled'),
  toggle('rdp.clipboardEnabled', 'RDP 剪贴板', 'rdpClipboardEnabled'),
  toggle('rdp.driveEnabled', 'RDP 驱动器映射', 'rdpDriveEnabled', '把本机文件夹映射给 Windows'),
  toggle('rdp.showDiagnostics', 'RDP 诊断信息', 'rdpShowDiagnostics', '会话里显示帧率、延迟等'),
  new AiSettingSpec('rdp.colorDepth', 'RDP 色深', 'rdpColorDepth', choices([['16', '16 位'], ['24', '24 位'], ['32', '32 位']]),
    '低色深更省带宽'),
  new AiSettingSpec('rdp.controlMode', 'RDP 操控方式', 'rdpControlMode', choices(CONTROL_MODES)),
  new AiSettingSpec('rdp.remoteUiScale', 'RDP 远端界面大小', 'rdpRemoteUiScale',
    choices([['auto', '自动'], ['100', '标准'], ['140', '大'], ['180', '特大']]), '调整 Windows 字体与控件大小'),
  // RustDesk
  new AiSettingSpec('rustdesk.imageQuality', 'RustDesk 图像质量', 'rustdeskImageQuality',
    choices([['0', '速度优先'], ['1', '平衡'], ['2', '画质优先']])),
  new AiSettingSpec('rustdesk.codec', 'RustDesk 编码', 'rustdeskCodec',
    choices([['0', '自动'], ['1', 'VP8'], ['2', 'VP9'], ['3', 'AV1'], ['4', 'H264'], ['5', 'H265']]),
    '长时间连接建议 H264/H265'),
  new AiSettingSpec('rustdesk.controlMode', 'RustDesk 操控方式', 'rustdeskControlMode', choices(CONTROL_MODES)),
  toggle('rustdesk.audioEnabled', 'RustDesk 远程音频', 'rustdeskAudioEnabled'),
  toggle('rustdesk.clipboardEnabled', 'RustDesk 剪贴板', 'rustdeskClipboardEnabled'),
  toggle('rustdesk.filePasteEnabled', 'RustDesk 文件粘贴', 'rustdeskFilePasteEnabled'),
  toggle('rustdesk.showDiagnostics', 'RustDesk 诊断信息', 'rustdeskShowDiagnostics'),
  toggle('rustdesk.privacyMode', 'RustDesk 隐私模式', 'rustdeskPrivacyMode', '连接时让被控端黑屏'),
  toggle('rustdesk.lanDiscovery', 'RustDesk 局域网发现', 'rustdeskLanDiscovery'),
  toggle('rustdesk.presenceDetectionEnabled', 'RustDesk 在线检测', 'rustdeskPresenceDetectionEnabled'),
  toggle('rustdesk.remoteAppTouchScaleEnabled', 'RustDesk 远端触控缩放', 'rustdeskRemoteAppTouchScaleEnabled'),
  toggle('rustdesk.showLocalCursor', 'RustDesk 显示本地光标', 'rustdeskShowLocalCursor'),
  toggle('rustdesk.relativeMouseMode', 'RustDesk 相对鼠标', 'rustdeskRelativeMouseMode', '游戏等需要锁定鼠标时开启'),
  toggle('rustdesk.swapMouseButtons', 'RustDesk 交换鼠标按键', 'rustdeskSwapMouseButtons'),
  // SSH
  new AiSettingSpec('ssh.inputMode', 'SSH 输入方式', 'sshInputMode',
    choices([['0', '自动'], ['1', '虚拟键盘'], ['2', '实体键鼠']])),
  // 远程会话通用
  new AiSettingSpec('remote.displayScaleMode', '远程画面缩放', 'remoteDisplayScaleMode',
    choices([['fit', '适应'], ['fill', '填满'], ['100', '100%'], ['125', '125%'], ['150', '150%'], ['175', '175%'],
      ['200', '200%']])),
  // Stored as "disabled": its values read the right way round for the user.
  new AiSettingSpec('remote.quickExitDisabled', '会话快速退出', 'remoteSessionQuickExitDisabled',
    choices([['false', '开启'], ['true', '关闭']]), '关闭可防止误触退出远程会话'),
  toggle('remote.rdpPinchZoom', 'RDP 双指缩放', 'rdpPinchZoomEnabled'),
  toggle('remote.rustdeskPinchZoom', 'RustDesk 双指缩放', 'rustdeskPinchZoomEnabled'),
  toggle('remote.sshPinchZoom', 'SSH 双指缩放', 'sshPinchZoomEnabled'),
  toggle('remote.vncPinchZoom', 'VNC 双指缩放', 'vncPinchZoomEnabled'),
  toggle('remote.moonlightPinchZoom', 'Moonlight 双指缩放', 'moonlightPinchZoomEnabled'),
  toggle('remote.rdpReverseWheel', 'RDP 反向滚轮', 'rdpReverseWheel'),
  toggle('remote.rustdeskReverseWheel', 'RustDesk 反向滚轮', 'rustdeskReverseWheel'),
  toggle('remote.sshReverseWheel', 'SSH 反向滚轮', 'sshReverseWheel'),
  toggle('remote.vncReverseWheel', 'VNC 反向滚轮', 'vncReverseWheel'),
  toggle('remote.moonlightReverseWheel', 'Moonlight 反向滚轮', 'moonlightReverseWheel'),
  // AI 助理 itself: how it answers and how it moves.
  new AiSettingSpec('ai.personality', 'AI 回答风格', 'aiAssistant.personality',
    choices([['balanced', '均衡'], ['warm', '温和'], ['concise', '简洁'], ['technical', '技术']]), '技术风格才讲协议细节'),
  new AiSettingSpec('ai.verbosity', 'AI 回答长度', 'aiAssistant.verbosity',
    choices([['concise', '简短'], ['standard', '标准'], ['detailed', '详细']])),
  new AiSettingSpec('ai.role', 'AI 助手角色', 'aiAssistant.role',
    choices([['remote-expert', '远程桌面专家'], ['beginner-guide', '新手引导'], ['diagnostic-first', '排障优先'],
      ['privacy-first', '隐私优先']])),
  toggle('ai.reducedMotion', '减少 AI 动效', 'diagnosticAiReducedMotion', '关闭持续旋转和弹簧转场'),
  new AiSettingSpec('ai.style', 'AI 风格', 'aiStyle', choices([['siri', 'Siri 风格'], ['xiaoyi', '小艺风格']]),
    '小艺风格是蓝紫渐变和彩色光环，会一起换掉思考动画、悬浮球和完成动画'),
  new AiSettingSpec('ai.style.wash', 'AI 窗口晕染', 'aiStyle.wash', choices([['on', '开'], ['off', '关']]), '小艺风格下才有'),
  new AiSettingSpec('ai.motion.thinking', 'AI 思考动画', 'aiMotion.thinking', choices([['dots', '光点环'], ['xiaoyi', '小艺光环'], ['discs', '圆片环'],
    ['halo', '智能光环'], ['aurora', '极光环'], ['strands', '彩丝声波'], ['orbit', '彗星轨道'], ['wave', '语音波'], ['minimal', '简洁']])),
  new AiSettingSpec('ai.motion.orb', 'AI 悬浮球样式', 'aiMotion.orb', choices([['voice', '语音球'], ['xiaoyiRing', '小艺光环球'], ['aurora', '极光球'],
    ['halo', '智能光环'], ['sine', '正弦光带'], ['xiaoyi', '小艺标志'], ['glass', '玻璃球']])),
  new AiSettingSpec('ai.motion.done', 'AI 完成动画', 'aiMotion.done', choices([['check', '画圆打勾'], ['xiaoyi', '小艺光环'], ['island', '灵动岛光环'],
    ['bounce', '弹出对勾'], ['ripple', '涟漪扩散'], ['sparkle', '粒子绽放'], ['none', '不显示']])),
  new AiSettingSpec('ai.motion.open', 'AI 展开动画', 'aiMotion.open', choices([['morph', '灵动岛形变'], ['liquid', '液态弹出'],
    ['focus', '模糊聚焦'], ['fade', '淡入'], ['none', '关闭']])),
  new AiSettingSpec('ai.motion.sendGlow', 'AI 发送按钮光晕', 'aiMotion.sendGlow', choices([['flow', '流动'], ['comet', '彗星'],
    ['breath', '呼吸'], ['static', '静止'], ['off', '关闭']])),
  new AiSettingSpec('ai.motion.speed', 'AI 动效速度', 'aiMotion.speed', choices([['slow', '慢'], ['normal', '标准'], ['fast', '快']]))
];

/**
 * Where settings are really changed: the host page registers the same savers its settings screens use (so a change
 * by the assistant persists, syncs and takes effect exactly like a tap in 设置), and reports values it keeps itself.
 */
export class DiagnosticAiSettingsBridge {
  private static applier: ((id: string, value: string) => boolean) | null = null;
  private static reader: ((id: string) => string | null) | null = null;

  static register(apply: (id: string, value: string) => boolean, read: (id: string) => string | null): void {
    DiagnosticAiSettingsBridge.applier = apply;
    DiagnosticAiSettingsBridge.reader = read;
  }

  static unregister(apply: (id: string, value: string) => boolean): void {
    if (DiagnosticAiSettingsBridge.applier === apply) {
      DiagnosticAiSettingsBridge.applier = null;
      DiagnosticAiSettingsBridge.reader = null;
    }
  }

  static apply(id: string, value: string): boolean {
    const apply = DiagnosticAiSettingsBridge.applier;
    let applied: boolean = false;
    if (apply !== null) {
      try { applied = apply(id, value); } catch (_error) { applied = false; }
    }
    hilog.info(0x0000, 'AiSettings', 'apply %{public}s=%{public}s bridge=%{public}s ok=%{public}s', id, value,
      apply === null ? 'none' : 'host', applied ? 'yes' : 'no');
    recordDiagnosticEvent('core.ai', 'ai_setting', applied ? 'succeeded' : 'failed', 0, 0,
      SETTINGS.findIndex((spec: AiSettingSpec): boolean => spec.id === id) + 1);
    return applied;
  }

  static read(id: string): string | null {
    const read = DiagnosticAiSettingsBridge.reader;
    if (read === null) { return null; }
    try { return read(id); } catch (_error) { return null; }
  }
}

export function diagnosticAiSettingSpecs(): AiSettingSpec[] { return SETTINGS.slice(); }

export function diagnosticAiSettingSpec(settingId: string): AiSettingSpec | undefined {
  return SETTINGS.find((spec: AiSettingSpec): boolean => spec.id === settingId);
}

export function diagnosticAiSettingIdAllowed(settingId: string): boolean {
  return diagnosticAiSettingSpec(settingId) !== undefined;
}

/** The setting's live value as one of its choice values, or null when unknown. */
export function diagnosticAiSettingCurrent(settingId: string): string | null {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(settingId);
  if (spec === undefined) { return null; }
  const reported: string | null = DiagnosticAiSettingsBridge.read(settingId);
  if (reported !== null) { return reported; }
  if (settingId === 'ui.theme') {
    if (AppStorage.get<boolean>('followSystem') === true) { return 'system'; }
    const theme: string | undefined = AppStorage.get<string>('currentTheme');
    return theme === 'dark' ? 'dark' : theme === 'light' ? 'light' : null;
  }
  const stored: Object | undefined = AppStorage.get<Object>(spec.key);
  if (stored === undefined || stored === null) { return null; }
  const value: string = typeof stored === 'boolean' ? (stored ? 'true' : 'false') : String(stored);
  return spec.choices.some((choice: AiSettingChoice): boolean => choice.value === value) ? value : null;
}

/**
 * The choice a proposal asks for. Models write values loosely (开启 / on / true, "32 位", "H265", "画质"), so the
 * value is matched against each choice's stored value and label; anything else is not a valid target.
 */
export function diagnosticAiProposalChoice(proposal: DiagnosticAiSettingProposal): AiSettingChoice | null {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(proposal.settingId);
  if (spec === undefined) { return null; }
  const raw: string = proposal.proposedValue.trim();
  const lower: string = raw.toLowerCase();
  if (spec.isBoolean()) {
    if (['true', 'on', '1', 'yes', '开启', '打开', '启用', '开'].indexOf(lower) >= 0) { return spec.choices[0]; }
    if (['false', 'off', '0', 'no', '关闭', '停用', '禁用', '关'].indexOf(lower) >= 0) { return spec.choices[1]; }
    return null;
  }
  const exact: AiSettingChoice | undefined = spec.choices.find((choice: AiSettingChoice): boolean =>
    choice.value.toLowerCase() === lower || choice.label.toLowerCase() === lower);
  if (exact !== undefined) { return exact; }
  const loose: AiSettingChoice | undefined = spec.choices.find((choice: AiSettingChoice): boolean =>
    lower.indexOf(choice.label.toLowerCase()) >= 0 || choice.label.toLowerCase().indexOf(lower) >= 0);
  return loose !== undefined ? loose : null;
}

export function diagnosticAiProposalIsSafe(proposal: DiagnosticAiSettingProposal): boolean {
  return diagnosticAiSettingIdAllowed(proposal.settingId) && proposal.currentValue.length <= 256 &&
    proposal.proposedValue.length <= 256 && proposal.reason.length <= 2000 &&
    proposal.rollbackValue.length <= 256 && proposal.requiresUserConfirmation;
}

/** The catalog the model sees: id, name, the values it may propose (value=label) and the live value. */
export function diagnosticAiSettingCatalog(): string {
  return SETTINGS.map((spec: AiSettingSpec): string => {
    const current: string | null = diagnosticAiSettingCurrent(spec.id);
    const values: string = spec.choices.map((choice: AiSettingChoice): string => choice.value + '=' + choice.label).join('/');
    return spec.id + '|' + spec.label + '|' + values + (current === null ? '' : '|当前=' + current) +
      (spec.note === '' ? '' : '|' + spec.note);
  }).join('\n');
}

/**
 * Apply a proposal the user tapped: through the host page's savers (persisted, synced, effective at once). The tap is
 * the confirmation and the live value is the truth; a setting already at the target is left alone.
 */
export function diagnosticAiApplyProposal(proposal: DiagnosticAiSettingProposal): boolean {
  const choice: AiSettingChoice | null = diagnosticAiProposalChoice(proposal);
  if (choice === null || !diagnosticAiProposalIsSafe(proposal)) { return false; }
  return diagnosticAiApplySetting(proposal.settingId, choice.value);
}

/** Set a catalog setting to one of its choice values (also used to undo). */
export function diagnosticAiApplySetting(settingId: string, value: string): boolean {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(settingId);
  if (spec === undefined || !spec.choices.some((choice: AiSettingChoice): boolean => choice.value === value)) {
    return false;
  }
  if (diagnosticAiSettingCurrent(settingId) === value) { return false; }
  return DiagnosticAiSettingsBridge.apply(settingId, value);
}

export function diagnosticAiSettingActionText(settingId: string): string {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(settingId);
  return spec !== undefined ? spec.label : '应用设置';
}

/** The label of one of a setting's values (开启 / 32 位 / H265 …). */
export function diagnosticAiSettingValueLabel(settingId: string, value: string): string {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(settingId);
  const choice: AiSettingChoice | undefined = spec === undefined ? undefined :
    spec.choices.find((item: AiSettingChoice): boolean => item.value === value);
  return choice !== undefined ? choice.label : value;
}

const PROTOCOLS: string[] = ['rustdesk', 'moonlight', 'rdp', 'ssh', 'vnc'];
const PROTOCOL_PREFIXES: string[] = ['RustDesk ', 'Moonlight ', 'RDP ', 'SSH ', 'VNC '];
const TURN_ON: string[] = ['开启', '打开', '启用', '允许', '开一下', '打开一下'];
const TURN_OFF: string[] = ['关闭', '关掉', '关了', '禁用', '停用', '取消', '不要'];

/** Other words people use for a setting (its label without the protocol is always one). */
function settingWords(id: string): string[] {
  switch (id) {
    case 'ui.theme': return ['外观', '主题', '深色模式', '浅色模式', '暗色', '夜间模式', '跟随系统'];
    case 'ui.ambientLightEffect': return ['沉浸光感', '光感'];
    case 'ui.groupedHostCards': return ['分组'];
    case 'ui.hostCardSensitiveHidden': return ['隐藏连接信息', '隐藏地址', '敏感信息'];
    case 'ui.liveViewEnabled': return ['实况窗', '后台连接'];
    case 'ui.virtualMouseStyle': return ['虚拟鼠标', '鼠标样式'];
    case 'rdp.audioEnabled': case 'rustdesk.audioEnabled': return ['音频', '声音'];
    case 'rdp.clipboardEnabled': case 'rustdesk.clipboardEnabled': return ['剪贴板', '复制粘贴'];
    case 'rdp.driveEnabled': return ['驱动器', '文件夹映射', '磁盘映射'];
    case 'rdp.showDiagnostics': case 'rustdesk.showDiagnostics': return ['诊断信息', '性能信息', '帧率显示'];
    case 'rdp.colorDepth': return ['色深', '颜色深度'];
    case 'rdp.controlMode': case 'rustdesk.controlMode': return ['操控', '控制方式', '操作方式'];
    case 'rdp.remoteUiScale': return ['界面大小', '字体大小', '远端界面'];
    case 'rustdesk.imageQuality': return ['画质', '图像质量', '清晰度'];
    case 'rustdesk.codec': return ['编码', '编解码', 'codec'];
    case 'rustdesk.lanDiscovery': return ['局域网'];
    case 'rustdesk.presenceDetectionEnabled': return ['在线检测', '在线状态'];
    case 'rustdesk.showLocalCursor': return ['本地光标'];
    case 'rustdesk.swapMouseButtons': return ['交换鼠标', '左右键'];
    case 'ssh.inputMode': return ['输入方式', '键盘模式'];
    case 'remote.displayScaleMode': return ['画面缩放', '缩放比例', '显示比例'];
    case 'remote.quickExitDisabled': return ['快速退出'];
    case 'ai.personality': return ['回答风格', '说话风格', '语气'];
    case 'ai.verbosity': return ['回答长度', '回答详细', '说得详细', '说得简短'];
    case 'ai.role': return ['助手角色', 'ai 角色'];
    case 'ai.reducedMotion': return ['减少动效', '减少动画', '关闭动画'];
    case 'ai.style': return ['ai 风格', 'ai 外观', '小艺风格', 'siri 风格', '小艺样式', 'siri 样式'];
    case 'ai.style.wash': return ['窗口晕染', '晕染'];
    case 'ai.motion.thinking': return ['思考动画', '加载动画'];
    case 'ai.motion.orb': return ['悬浮球'];
    case 'ai.motion.done': return ['完成动画', '打勾动画'];
    case 'ai.motion.open': return ['展开动画', '打开动画'];
    case 'ai.motion.sendGlow': return ['发送按钮', '光晕'];
    case 'ai.motion.speed': return ['动效速度', '动画速度'];
    default: break;
  }
  if (id.indexOf('PinchZoom') > 0) { return ['双指缩放', '捏合缩放']; }
  if (id.indexOf('ReverseWheel') > 0) { return ['反向滚轮', '滚轮方向', '滚轮反向']; }
  return [];
}

function protocolOf(id: string): string {
  const lower: string = id.toLowerCase();
  const head: string = lower.split('.')[0];
  if (PROTOCOLS.indexOf(head) >= 0) { return head; }
  if (head === 'remote') {
    const named: string | undefined = PROTOCOLS.find((p: string): boolean => lower.indexOf('.' + p) >= 0);
    return named !== undefined ? named : '';
  }
  return '';
}

function compact(text: string): string { return text.toLowerCase().replace(/\s+/g, ''); }

function subjectWords(spec: AiSettingSpec): string[] {
  let subject: string = spec.label;
  PROTOCOL_PREFIXES.forEach((prefix: string): void => {
    if (subject.indexOf(prefix) === 0) { subject = subject.slice(prefix.length); }
  });
  return [compact(subject)].concat(settingWords(spec.id).map((word: string): string => compact(word)));
}

/** The choice a clause names: the longest label (or, when the setting itself is named, value) found in it. */
function namedChoice(spec: AiSettingSpec, clause: string, subjectHit: boolean): AiSettingChoice | null {
  let best: AiSettingChoice | null = null;
  let bestLength: number = 0;
  spec.choices.forEach((choice: AiSettingChoice): void => {
    const label: string = compact(choice.label);
    // Without the setting's name, only distinctive values count (H265, 画质优先, 深色), not 自动/标准/大.
    const distinctive: boolean = label.length >= 3 || /[a-z0-9]/.test(label) || label === '深色' || label === '浅色';
    if ((subjectHit || distinctive) && clause.indexOf(label) >= 0 && label.length > bestLength) {
      best = choice; bestLength = label.length;
    }
    const value: string = compact(choice.value);
    if (subjectHit && value.length >= 2 && value !== 'true' && value !== 'false' && clause.indexOf(value) >= 0 &&
      value.length > bestLength) {
      best = choice; bestLength = value.length;
    }
  });
  return best;
}

/**
 * Setting changes the user asked for in plain words ("把 RustDesk 编码改成 H265，画质优先", "关闭 RDP 音频和剪贴板"),
 * read locally so a request always gets its one-tap buttons even when the model only describes the steps. Clauses
 * carry the protocol and the on/off verb forward ("画质优先" after a RustDesk clause is RustDesk's).
 */
export function diagnosticAiSettingIntents(question: string): DiagnosticAiSettingProposal[] {
  const clauses: string[] = question.split(/[，,。；;、\n]|并且|然后|同时|还有|以及|和/)
    .map((part: string): string => compact(part)).filter((part: string): boolean => part.length > 0);
  const found: DiagnosticAiSettingProposal[] = [];
  let protocolContext: string = '';
  let verbContext: string = '';
  clauses.forEach((clause: string): void => {
    const named: string[] = PROTOCOLS.filter((p: string): boolean => clause.indexOf(p) >= 0);
    if (named.length > 0) { protocolContext = named[0]; }
    const protocols: string[] = named.length > 0 ? named : protocolContext !== '' ? [protocolContext] : [];
    if (TURN_ON.some((word: string): boolean => clause.indexOf(word) >= 0)) { verbContext = 'true'; }
    else if (TURN_OFF.some((word: string): boolean => clause.indexOf(word) >= 0)) { verbContext = 'false'; }
    SETTINGS.forEach((spec: AiSettingSpec): void => {
      const protocol: string = protocolOf(spec.id);
      if (protocol !== '' && protocols.length > 0 && protocols.indexOf(protocol) < 0) { return; }
      if (protocol === '' && named.length > 0 && spec.id.indexOf('ui.') !== 0 && spec.id.indexOf('remote.') !== 0) { return; }
      const subjectHit: boolean = subjectWords(spec).some((word: string): boolean => word.length > 0 && clause.indexOf(word) >= 0);
      let value: string = '';
      if (spec.isBoolean()) {
        if (!subjectHit || verbContext === '') { return; }
        value = verbContext;
      } else {
        const choice: AiSettingChoice | null = namedChoice(spec, clause, subjectHit);
        if (choice === null) { return; }
        value = choice.value;
      }
      if (found.some((p: DiagnosticAiSettingProposal): boolean => p.settingId === spec.id)) { return; }
      const current: string | null = diagnosticAiSettingCurrent(spec.id);
      found.push({ settingId: spec.id, currentValue: current ?? '', proposedValue: value, reason: '按你的要求修改',
        evidenceRefs: [], risk: 'low', requiresUserConfirmation: true, rollbackValue: current ?? '' });
    });
  });
  return found.slice(0, 6);
}

class AiOptimizationRule {
  protocols: string[];
  words: string[];
  settingId: string;
  value: string;
  reason: string;

  constructor(protocols: string[], words: string[], settingId: string, value: string, reason: string) {
    this.protocols = protocols;
    this.words = words;
    this.settingId = settingId;
    this.value = value;
    this.reason = reason;
  }
}

const LAG: string[] = ['卡顿', '卡住', '很卡', '有点卡', '卡死', '延迟', '慢', '掉帧', '不流畅', '帧率低'];
const OPTIMIZATIONS: AiOptimizationRule[] = [
  new AiOptimizationRule(['rdp'], LAG, 'rdp.colorDepth', '16', '降低色深能明显减少画面数据量，网络一般时更流畅'),
  new AiOptimizationRule(['rdp'], LAG.concat(['黑屏', '花屏']), 'rdp.showDiagnostics', 'true',
    '会话里显示帧率、延迟和解码情况，能看出卡在网络还是解码'),
  new AiOptimizationRule(['rustdesk'], LAG, 'rustdesk.imageQuality', '0', '速度优先会降低画质换取更低的延迟'),
  new AiOptimizationRule(['rustdesk'], LAG, 'rustdesk.codec', '4', 'H264 有硬件解码，长时间连接更稳定、更省电'),
  new AiOptimizationRule(['rustdesk'], LAG.concat(['黑屏', '花屏']), 'rustdesk.showDiagnostics', 'true',
    '会话里显示帧率、延迟和编码情况'),
  new AiOptimizationRule(['rustdesk'], ['模糊', '不清晰', '画质差', '画质不好'], 'rustdesk.imageQuality', '2', '画质优先让画面更清晰'),
  new AiOptimizationRule(['rdp'], ['没声音', '没有声音', '听不到', '无声'], 'rdp.audioEnabled', 'true', '打开后远端的声音会传到本机'),
  new AiOptimizationRule(['rustdesk'], ['没声音', '没有声音', '听不到', '无声'], 'rustdesk.audioEnabled', 'true',
    '打开后远端的声音会传到本机'),
  new AiOptimizationRule(['rdp'], ['剪贴板', '复制', '粘贴'], 'rdp.clipboardEnabled', 'true', '打开后本机和远端可以互相复制粘贴'),
  new AiOptimizationRule(['rustdesk'], ['剪贴板', '复制', '粘贴'], 'rustdesk.clipboardEnabled', 'true',
    '打开后本机和远端可以互相复制粘贴'),
  new AiOptimizationRule(['rdp'], ['字太小', '字体小', '看不清', '界面太小', '字小'], 'rdp.remoteUiScale', '140',
    '把 Windows 的字体和控件放大一档')
];

/**
 * Settings that commonly help with a described problem ("RDP 很卡" → lower color depth, show the session's
 * diagnostics). Offered with the answer so the user can try a fix right away, next to the log capture plan; settings
 * already at the suggested value are dropped by the caller.
 */
export function diagnosticAiOptimizationIntents(question: string): DiagnosticAiSettingProposal[] {
  const value: string = compact(question);
  const found: DiagnosticAiSettingProposal[] = [];
  OPTIMIZATIONS.forEach((rule: AiOptimizationRule): void => {
    if (!rule.protocols.some((p: string): boolean => value.indexOf(p) >= 0)) { return; }
    if (!rule.words.some((word: string): boolean => value.indexOf(compact(word)) >= 0)) { return; }
    if (found.some((p: DiagnosticAiSettingProposal): boolean => p.settingId === rule.settingId)) { return; }
    if (diagnosticAiSettingCurrent(rule.settingId) === rule.value) { return; }
    const current: string | null = diagnosticAiSettingCurrent(rule.settingId);
    found.push({ settingId: rule.settingId, currentValue: current ?? '', proposedValue: rule.value, reason: rule.reason,
      evidenceRefs: [], risk: 'low', requiresUserConfirmation: true, rollbackValue: current ?? '' });
  });
  return found.slice(0, 3);
}
