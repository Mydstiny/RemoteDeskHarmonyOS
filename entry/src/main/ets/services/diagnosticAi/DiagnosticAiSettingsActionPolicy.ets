import { hilog } from '@kit.PerformanceAnalysisKit';
import { recordDiagnosticEvent } from '../DiagnosticCaptureRuntime';
import { DiagnosticAiSettingProposal } from './DiagnosticAiModels';
import { AI_SESSION_REPLY_MODES } from './AiSessionVoicePolicy';
import { remoteWheelSpeedChoices, remoteWheelSpeedLabel } from '../RemoteWheelPreferencePolicy';

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
/** 远程滚轮 › 速度: 25% steps from 25% to 400% (VNC to 1000%); 100% is each protocol's tuned default. */
function wheelSpeed(protocol: string, name: string): AiSettingSpec {
  const speeds: string[][] = remoteWheelSpeedChoices(protocol).map((v: number): string[] => [v.toString(), remoteWheelSpeedLabel(v)]);
  return new AiSettingSpec('remote.' + protocol + 'WheelSpeed', name + ' 滚轮速度', protocol + 'WheelSpeed', choices(speeds),
    '每格滚轮、每次双指滑动在远端滚动的距离；嫌快调低、嫌慢调高，100% 为默认' +
      (protocol === 'vnc' ? '；macOS 屏幕共享等滚得少的服务器可调到 400%–1000%' : ''));
}

const SETTINGS: AiSettingSpec[] = [
  // 外观与主机列表
  new AiSettingSpec('ui.theme', '外观模式', 'currentTheme',
    choices([['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']])),
  toggle('ui.ambientLightEffect', '沉浸光感', 'ambientLightEffectEnabled', '玻璃与光晕效果'),
  toggle('ui.groupedHostCards', '主机分组卡片', 'groupedHostCards', '按协议把主机收进分组卡片'),
  toggle('ui.hostCardSensitiveHidden', '主机卡片隐藏连接信息', 'hostCardSensitiveInfoHidden', '卡片上不显示地址与用户名'),
  toggle('ui.liveViewEnabled', '实时视图', 'liveViewEnabled'),
  new AiSettingSpec('ui.hostAddMode', '添加主机样式', 'hostAddMode', choices([['modern', '新版'], ['classic', '经典']])),
  new AiSettingSpec('ui.settingsVisual', '全新视觉外观', 'settingsVisualStyle',
    choices([['modern', '全新视觉'], ['classic', '经典']]),
    '全新视觉：设置分组、可搜索、显示当前值，远程主机、密钥保险库、中继页换新外观；经典：原来的样子'),
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
  wheelSpeed('rdp', 'RDP'),
  wheelSpeed('rustdesk', 'RustDesk'),
  wheelSpeed('ssh', 'SSH'),
  wheelSpeed('vnc', 'VNC'),
  wheelSpeed('moonlight', 'Moonlight'),
  // 远程 AI (Codex, DSH, Claude Agent on the user's computer): kept per account by the host page's bridge.
  new AiSettingSpec('remoteAi.uiStyle', '远程 AI 界面风格', 'remoteAi.uiStyle',
    choices([['claude', 'Claude 风格'], ['codex', 'Codex 风格']]),
    '远程 AI 会话页的外观：Claude 是对话时间线，Codex 是对话/日志/差异分页；下次打开会话生效'),
  toggle('remoteAi.showExecution', '远程 AI 显示工具执行过程', 'remoteAi.showExecution', '会话里列出工具调用与执行记录'),
  toggle('remoteAi.reconnectOnForeground', '远程 AI 回到前台后恢复查看', 'remoteAi.reconnectOnForeground',
    '回到 App 时重新校验服务并读取会话，控制权仍需手动取得'),
  // AI 助理 itself: how it answers and how it moves.
  new AiSettingSpec('ai.personality', 'AI 回答风格', 'aiAssistant.personality',
    choices([['balanced', '均衡'], ['warm', '温和'], ['concise', '简洁'], ['technical', '技术']]), '技术风格才讲协议细节'),
  new AiSettingSpec('ai.verbosity', 'AI 回答长度', 'aiAssistant.verbosity',
    choices([['concise', '简短'], ['standard', '标准'], ['detailed', '详细']])),
  new AiSettingSpec('ai.role', 'AI 助手角色', 'aiAssistant.role',
    choices([['remote-expert', '远程桌面专家'], ['beginner-guide', '新手引导'], ['diagnostic-first', '排障优先'],
      ['privacy-first', '隐私优先']])),
  toggle('ai.reducedMotion', '减少 AI 动效', 'diagnosticAiReducedMotion', '关闭持续旋转和弹簧转场'),
  // AI 语音 (per account): kept by the host page's bridge.
  toggle('ai.voice.enabled', 'AI 语音', 'aiVoice.enabled', '语音模式、对悬浮球说话和自动朗读回答的总开关'),
  new AiSettingSpec('ai.voice.sessionReply', '连接中语音回答', 'aiVoice.sessionReply', choices(AI_SESSION_REPLY_MODES),
    '远程连接里的悬浮球 AI 什么时候把回答读出来；只在本次连接用语音回答时改用 switch_mode 的 voice，不必改设置'),
  new AiSettingSpec('ai.voice.rate', 'AI 朗读语速', 'aiVoice.rate', choices([['slow', '慢'], ['normal', '正常'], ['fast', '快']])),
  toggle('ai.voice.continuous', 'AI 连续对话', 'aiVoice.continuous', '语音模式下回答说完后接着听'),
  toggle('ai.voice.sessionStartVoice', '连接中 AI 启动时进入语音模式', 'aiVoice.sessionStartVoice',
    '远程连接里启动 AI 时直接是语音模式；本次连接里切换语音用 switch_mode'),
  toggle('ai.voice.sessionQuickStart', '连接中点 AI 按钮直接启动', 'aiVoice.sessionQuickStart',
    '关闭：点侧栏 AI 按钮先打开 AI 控制面板；开启：直接启动或关闭 AI，长按打开面板'),
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
/** On and off words; 不要关 / 别关 keep something on, 不用开 / 别开 leave it off, 开着 / 关着 keep it so. */
const TURN_ON: string[] = ['不要再关', '别再关', '不能关', '不要关', '不用关', '别关', '开启', '打开', '启用', '允许', '开一下', '开着',
  '开起来', '开了', '开下', '开开'];
const TURN_OFF: string[] = ['关闭', '关掉', '关一下', '关下', '关了', '关着', '禁用', '停用', '取消', '不要开', '不用开', '别开',
  '不再需要', '不需要', '用不着', '没必要开', '不想用', '不想要', '不要把', '不用把', '不想把', '别把', '不要让', '不想让', '别让', '不让',
  '不要'];
/** Off words that only refuse (不要, 别把, 别让 …): before a setting they turn the verb after it the other way (别让音频开着). */
const REFUSALS: string[] = ['不要把', '不用把', '不想把', '别把', '不要让', '不想让', '别让', '不让', '不要'];
/** Off words a negation turns back on (不要关闭, 别再关了, 取消隐藏). */
const NEGATABLE_OFF: string[] = ['关闭', '关掉', '关一下', '关下', '关了', '禁用', '停用', '隐藏起来', '隐藏掉', '隐藏'];
/** Right before an on-word these turn it off (不要打开, 别开启, 不再打开); 要不要打开 asks to turn it on, 不得不打开 must. */
const NEGATIONS: string[] = ['不需要', '不要', '不用', '无需', '不必', '不再', '别再', '不想', '不准', '不许', '别', '不'];
/** What may stand between a negation and its verb (不要再打开, 不要让 RDP 显示, 别给我关了, 不要一直开着). */
const NEGATION_GAP: string[] = ['给我', '一直', '总是', '老是', '始终', '让', '再', '给', '去', '我', '总', '老'];
/** …and before 显示 / 隐藏 these too (关闭显示本地光标, 取消隐藏); before 打开 they are a verb of their own (关闭开启剪贴板). */
const SHOW_NEGATIONS: string[] = ['停止', '取消', '关闭', '关掉'];
/** Words ending in 别 that do not negate (分别打开). */
const NOT_NEGATIONS: string[] = ['分别', '特别', '区别', '识别', '级别', '类别', '个别', '告别'];
/** Names that may stand between a verb and what it turns (打开 RDP 音频, 关闭 RustDesk 显示本地光标). */
const NAMES: string[] = ['rustdesk', 'moonlight', 'rdp', 'ssh', 'vnc', '远程ai', 'ai'];
/** What may stand between a verb and the setting after it (关闭 RDP 的音频). */
const BEFORE_FILLER: string[] = NAMES.concat(['所有', '全部', '这个', '那个', '一下', '会话', '协议', '保持', '一直', '的', '把', '将',
  '让', '下', '里', '中', '上']);
/** …and between a setting and the verb after it (音频也打开, 音频关闭后再打开, 音频要不要打开). */
const AFTER_FILLER: string[] = NAMES.concat(['要不要', '都给我', '给我', '帮我', '重新', '后再', '统统', '一起', '全部', '还是', '的话',
  '一直', '都', '也', '再', '就', '先', '后', '要', '全', '给']);
/** What may stand between a verb after its setting and the next setting (音频打开再把剪贴板关掉, 开启但是剪贴板关闭). */
const CONNECTORS: string[] = ['顺便把', '另外把', '然后把', '再把', '并把', '但是', '不过', '而且', '顺便', '另外', '接着', '之后', '还要',
  '帮我', '给我', '再', '并', '把', '但', '而', '又', '也', '后'];
/** What may stand between two settings named together, the first taking the second's verb (音频剪贴板都打开). */
const LIST_FILLER: string[] = NAMES.concat(['还有', '的', '都', '也', '与', '跟', '及']);
/** What may end a clause after a verb that follows its setting (音频关掉吧). */
const PARTICLES: string[] = ['好不好', '行不行', '就可以', '就好', '就行', '即可', '可以', '试试', '看看', '一下', '起来', '谢谢', '拜托',
  '了', '吧', '啊', '呀', '哦', '吗', '呢', '嘛', '掉', '下', '的', '啦', '哈', '咯', '呗', '嘞', '哟', '噢', '喔', '~', '～', '…', '.',
  'ok'];
/** What a follow-up may say besides its verb to be a plain request (帮我关掉吧, 那就直接关了). */
const FOLLOW_UP_FILLER: string[] = ['那就', '直接', '好了', '再说', '得了', '的话', '没用', '算了', '先', '再', '就', '那', '它', '你',
  '嗯'];
/** After 开着 / 关着 these describe a state that goes wrong (剪贴板开着但是复制不了), not ask to keep it. */
const STATE_BUT: string[] = ['但是', '可是', '还是', '但', '却', '也'];
/** A sentence with a change in it, ending like these, asks politely for it (关掉 RDP 音频好吗). */
const POLITE_ENDINGS: RegExp = /(好吗|行吗|可以吗|成吗|好不好|行不行)[？?]?$/;
/**
 * 显示 / 隐藏 turn the 显示… settings (诊断信息, 本地光标, 工具执行过程) on and off: only those, never in a question, and
 * before what they show (显示本地光标). After it they mostly describe what is seen (本地光标不显示, 显示异常, 显示不出来),
 * except 显示出来 / 隐藏起来 / 隐藏掉, 不要显示 / 别显示, and 把…隐藏.
 */
const SHOW: string[] = ['显示出来', '显示'];
const HIDE: string[] = ['隐藏起来', '隐藏掉', '隐藏'];
const SHOW_AFTER: string[] = ['显示出来', '隐藏起来', '隐藏掉'];
const QUESTION_WORDS: string[] = ['怎么', '为什么', '为何', '什么', '如何', '吗', '?', '？'];
/**
 * A sentence asking about a setting or describing a problem with it proposes nothing (音频打开了吗, H265 和 H264 哪个好,
 * 我打开了音频但是没声音, 关闭隐私模式后黑屏了): it is for the assistant to answer or diagnose.
 */
const ASKS: string[] = ['为什么', '为何', '哪个', '哪种', '是什么', '什么样', '是否', '有什么', '有啥', '会怎样', '会怎么样', '怎么',
  '如何'];
const COMPLAINS: string[] = ['但是没', '但没', '还是没', '之后还是', '后还是', '还是有', '失败', '不起作用', '没反应', '不管用', '就不能',
  '看不到', '用不了', '不能用', '黑屏', '卡住', '会卡', '变卡', '很卡', '好卡', '太卡', '特别卡', '卡顿', '很慢', '杂音', '自己打开',
  '自己关', '打不开', '关不掉', '开不了', '关不了'];
/** …and one ending like a question asks, unless it asks for something (能把音频关掉吗, 可以帮我打开剪贴板吗). */
const MAYBE_ASKS: string[] = ['吗', '没有', '了没', '呢', '?', '？'];
const REQUESTS: string[] = ['帮我', '帮忙', '麻烦', '能不能', '能否', '可不可以', '可以', '给我', '我想', '我要', '想要', '希望', '要不要',
  '请', '能'];
/** A clause with only a verb and one of these changes the switches just named (打开 RDP 音频，算了还是关掉吧). */
const CHANGE_OF_MIND: string[] = ['算了', '还是', '不对', '改主意'];
/** A clause with one of these leaves its settings as they are (剪贴板留着, 先不要动 RDP 剪贴板). */
const NO_CHANGE: string[] = ['不要改', '别改', '不用改', '不要动', '别动', '不用动', '不碰', '留着', '保留', '不变', '维持'];
/** What a clause may hold besides names to count as a bare list item (RDP 音频, 剪贴板也一样). */
const BARE_FILLER: string[] = ['一样', '同样', '也是', '还有', '以及', '都', '也', '的', '把', '将', '还', '和', '跟', '及', '呢', '吧',
  '啊', '呀', '了'];
/** Single-character 开 / 关 count right next to a setting (关 RDP 音频, 剪贴板开), unless they belong to a word (相关, 离开). */
const NOT_SINGLE_BEFORE: string[] = ['打', '相', '有', '机', '离', '公', '展', '召', '避', '难', '玄', '海'];
/** Before a value, these refuse it (关掉深色模式, 不要用 H265): a setting with two values gets the other one. */
const VALUE_REFUSALS: string[] = ['不要用', '不想用', '不再用', '别用', '不需要', '不想要', '不用', '不要', '不想', '关掉', '关闭', '关了',
  '关一下', '退出', '取消', '停用', '别'];
/** …and after it (深色模式关掉, H265 不要了). */
const VALUE_REFUSALS_AFTER: string[] = ['不需要了', '不要了', '不用了', '关一下', '关掉', '关闭', '关了', '不要', '不用', '停用', '取消'];
/** Before 换成 / 改成 …, these refuse the change itself (不要换成深色模式, 先不要切换到 H265). */
const CHANGE_REFUSALS: string[] = ['先不要', '暂时不要', '不要', '不想', '不用', '不再', '别'];
/** Values too plain to name a setting by themselves (不显示 is also what people say about anything on screen). */
const PLAIN_LABELS: string[] = ['不显示'];
/** 开启 / 关闭 (or 开 / 关) as a setting's two values: it is turned on and off like a switch (会话快速退出, 窗口晕染). */
const ON_LABELS: string[] = ['开启', '开'];
const OFF_LABELS: string[] = ['关闭', '关'];

/** Other words people use for a setting (its label without the protocol is always one). */
function settingWords(id: string): string[] {
  switch (id) {
    case 'ui.theme': return ['外观', '主题', '深色模式', '浅色模式', '暗色', '夜间模式', '跟随系统'];
    case 'ui.ambientLightEffect': return ['沉浸光感', '光感'];
    case 'ui.groupedHostCards': return ['分组卡片', '分组'];
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
    case 'ai.verbosity': return ['回答长度', '回答详细', '回答简短', '说得详细', '说得简短', '详细一点', '简短一点'];
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
    case 'remoteAi.uiStyle': return ['远程 ai 风格', '远程 ai 界面', '远程 ai 外观', '会话页风格', '工作区风格', 'claude 风格',
      'codex 风格'];
    // Not 工具调用 / 执行过程 alone: those are the AI 助理's own tools. A word with + needs all its parts (远程 AI 里不
    // 显示执行过程).
    case 'remoteAi.showExecution': return ['工具执行过程', '远程 ai+执行过程', '远程 ai+工具过程', '远程 ai+执行记录',
      '远程 ai+工具执行', '远程 ai+工具调用'];
    case 'remoteAi.reconnectOnForeground': return ['恢复查看', '回到前台'];
    default: break;
  }
  if (id.indexOf('PinchZoom') > 0) { return ['双指缩放', '捏合缩放']; }
  if (id.indexOf('ReverseWheel') > 0) { return ['反向滚轮', '滚轮方向', '滚轮反向']; }
  if (id.indexOf('WheelSpeed') > 0) { return ['滚轮速度', '滚动速度', '滚轮灵敏度']; }
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
  const words: string[] = settingWords(spec.id).map((word: string): string => compact(word));
  // A 显示… switch is named by what it shows (本地光标): 显示 / 不显示 before that read as verbs.
  if (isShowSwitch(spec) && words.length > 0) { return words; }
  let subject: string = spec.label;
  PROTOCOL_PREFIXES.forEach((prefix: string): void => {
    if (subject.indexOf(prefix) === 0) { subject = subject.slice(prefix.length); }
  });
  return [compact(subject)].concat(words);
}

function isShowSwitch(spec: AiSettingSpec): boolean { return spec.id.indexOf('.show') > 0; }

/** The value that turns a setting on (or off), or null when it is not a switch. */
function switchValue(spec: AiSettingSpec, on: boolean): string | null {
  if (spec.isBoolean()) { return on ? 'true' : 'false'; }
  if (spec.choices.length !== 2) { return null; }
  const wanted: AiSettingChoice | undefined = spec.choices.find((choice: AiSettingChoice): boolean =>
    (on ? ON_LABELS : OFF_LABELS).indexOf(choice.label) >= 0);
  const other: AiSettingChoice | undefined = spec.choices.find((choice: AiSettingChoice): boolean =>
    (on ? OFF_LABELS : ON_LABELS).indexOf(choice.label) >= 0);
  return wanted !== undefined && other !== undefined ? wanted.value : null;
}

/** Words that put the wanted value after them: 从 A 换成 B means B. */
const CHANGE_TO: string[] = ['换成', '改成', '改为', '切到', '切换到', '切换成', '换到', '设为', '设成', '调成', '调到', '变成'];

/**
 * The choice a clause names: what follows its last 换成 / 改成 / 切到 … when that names one, else the longest label (or,
 * when the setting itself is named, value) found in the whole clause.
 */
function namedChoice(spec: AiSettingSpec, clause: string, subjectHit: boolean): AiSettingChoice | null {
  if (changeRefused(clause)) { return null; }
  let cut: number = -1;
  CHANGE_TO.forEach((word: string): void => {
    const at: number = clause.lastIndexOf(word);
    if (at >= 0 && at + word.length > cut) { cut = at + word.length; }
  });
  if (cut > 0 && cut < clause.length) {
    const wanted: AiSettingChoice | null = longestChoice(spec, clause.slice(cut), subjectHit);
    if (wanted !== null) { return wanted; }
  }
  return longestChoice(spec, clause, subjectHit);
}

/** Whether the value named at `at` (`length` long) is refused rather than asked for (关掉深色模式, 深色模式关掉, 不用 H265). */
function refusedAt(clause: string, at: number, length: number): boolean {
  const before = (end: number): boolean => {
    const text: string = clause.slice(Math.max(0, beforeNames(clause, end) - 3), beforeNames(clause, end));
    return VALUE_REFUSALS.some((word: string): boolean => text.endsWith(word));
  };
  let end: number = at;
  while (end > 0 && (clause.charAt(end - 1) === '用' || clause.charAt(end - 1) === '成')) { end--; }
  if (before(at) || before(end)) { return true; }
  // After it only when that is where the clause ends (深色模式关掉, H265 不要了), not when the off word is the next
  // setting's (速度优先关闭音频).
  const next: number = skipWords(clause, at + length, ['模式', '风格', '主题'].concat(AFTER_FILLER));
  return VALUE_REFUSALS_AFTER.some((word: string): boolean => clause.startsWith(word, next) &&
    onlyFiller(clause.slice(next + word.length), PARTICLES));
}

/** Whether the clause refuses the change it names (不要换成深色模式, 先不要切换到 H265). */
function changeRefused(clause: string): boolean {
  return CHANGE_TO.some((word: string): boolean => {
    let at: number = clause.indexOf(word);
    while (at >= 0) {
      const end: number = beforeNames(clause, at, ['先', '再', '暂时']);
      const text: string = clause.slice(Math.max(0, end - 4), end);
      if (CHANGE_REFUSALS.some((refusal: string): boolean => text.endsWith(refusal))) { return true; }
      at = clause.indexOf(word, at + word.length);
    }
    return false;
  });
}

/** A value of a two-valued setting the clause refuses (关闭小艺风格): the other one is wanted. */
function otherOfRefused(spec: AiSettingSpec, clause: string): AiSettingChoice | null {
  if (spec.choices.length !== 2) { return null; }
  for (let i = 0; i < 2; i++) {
    const label: string = compact(spec.choices[i].label);
    const at: number = clause.indexOf(label);
    if (at >= 0 && refusedAt(clause, at, label.length) && clause.indexOf(compact(spec.choices[1 - i].label)) < 0) {
      return spec.choices[1 - i];
    }
  }
  return null;
}

/** Other names of a value (夜间模式 is 深色). */
function valueWords(spec: AiSettingSpec, choice: AiSettingChoice): string[] {
  if (spec.id === 'ui.theme') {
    if (choice.value === 'dark') { return ['夜间模式', '暗色', '黑色主题']; }
    if (choice.value === 'light') { return ['日间模式', '亮色', '白色主题']; }
  }
  return [];
}

function longestChoice(spec: AiSettingSpec, clause: string, subjectHit: boolean): AiSettingChoice | null {
  let best: AiSettingChoice | null = null;
  let bestLength: number = 0;
  spec.choices.forEach((choice: AiSettingChoice): void => {
    const label: string = compact(choice.label);
    // A value said with 的 before something else describes that (小艺风格的思考动画; 改成圆形的 still asks for it), and
    // one refused is not wanted.
    const at: number = clause.indexOf(label);
    const rest: string = clause.slice(at + label.length + 1);
    const describes: boolean = clause.charAt(at + label.length) === '的' && SETTINGS.some((other: AiSettingSpec): boolean =>
      other.id !== spec.id && subjectWords(other).some((word: string): boolean => word.length > 0 && rest.startsWith(word)));
    if (at >= 0 && (refusedAt(clause, at, label.length) || describes)) { return; }
    valueWords(spec, choice).forEach((word: string): void => {
      const wordAt: number = clause.indexOf(word);
      if (wordAt >= 0 && word.length > bestLength && !refusedAt(clause, wordAt, word.length)) {
        best = choice; bestLength = word.length;
      }
    });
    // With the setting named, a 风格 / 样式 value may be said short (AI 风格改成小艺).
    const stem: string = label.replace(/(风格|样式)$/, '');
    const stemAt: number = clause.indexOf(stem);
    if (subjectHit && stem !== label && stem.length >= 2 && stemAt >= 0 && stem.length > bestLength &&
      !refusedAt(clause, stemAt, stem.length)) {
      best = choice; bestLength = stem.length;
    }
    // Without the setting's name, only distinctive values count (H265, 画质优先, 深色), not 自动/标准/大/不显示.
    const distinctive: boolean = (label.length >= 3 || /[a-z0-9]/.test(label) || label === '深色' || label === '浅色') &&
      PLAIN_LABELS.indexOf(label) < 0;
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
 * An on or off word in a clause: where it is, which way it turns, whether it may follow what it turns, and whether it
 * only refuses (不要, 别把: it turns the verb after the setting the other way).
 */
class AiVerb {
  at: number;
  length: number;
  on: boolean;
  trails: boolean;
  refuses: boolean;

  constructor(at: number, length: number, on: boolean, trails: boolean, refuses: boolean) {
    this.at = at;
    this.length = length;
    this.on = on;
    this.trails = trails;
    this.refuses = refuses;
  }
}

/** Where a clause names a setting. */
class AiSpan {
  start: number;
  end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

/** A negation before a verb: where it starts and which it is. */
class AiNegation {
  start: number;
  word: string;

  constructor(start: number, word: string) {
    this.start = start;
    this.word = word;
  }
}

/** Where the text from `from` on continues past any of these words (in any order). */
function skipWords(clause: string, from: number, words: string[]): number {
  let at: number = from;
  let moved: boolean = true;
  while (moved) {
    moved = false;
    let longest: string = '';
    for (let i = 0; i < words.length; i++) {
      if (clause.startsWith(words[i], at) && words[i].length > longest.length) { longest = words[i]; }
    }
    if (longest !== '') { at += longest.length; moved = true; }
  }
  return at;
}

/** Where the text from `from` on continues past the names (RDP, 远程 AI …) it starts with. */
function afterNames(clause: string, from: number): number {
  return skipWords(clause, from, NAMES);
}

/** Where the text before `end` starts once the names (and `words`) it ends with are left out. */
function beforeNames(clause: string, end: number, words: string[] = []): number {
  const all: string[] = NAMES.concat(words);
  let at: number = end;
  let moved: boolean = true;
  while (moved) {
    moved = false;
    for (let i = 0; i < all.length; i++) {
      if (at >= all[i].length && clause.slice(at - all[i].length, at) === all[i]) { at -= all[i].length; moved = true; }
    }
  }
  return at;
}

/** Whether `text` is only these words (any number, in any order). */
function onlyFiller(text: string, fillers: string[]): boolean {
  return skipWords(text, 0, fillers) === text.length;
}

/**
 * The negation right before a verb (不要打开, 别再关了; names and 让 / 再 between do not separate them: 不要让 RDP 显示 …),
 * or null. 要不要 asks, 不得不 must.
 */
function negationOf(clause: string, at: number, word: string): AiNegation | null {
  const end: number = beforeNames(clause, at, NEGATION_GAP);
  const before: string = clause.slice(Math.max(0, end - 3), end);
  if (before.endsWith('要不要') || before.endsWith('要不') || before.endsWith('不得不')) { return null; }
  const showing: boolean = SHOW.indexOf(word) >= 0 || HIDE.indexOf(word) >= 0;
  const negations: string[] = showing ? SHOW_NEGATIONS.concat(NEGATIONS) : NEGATIONS;
  for (let i = 0; i < negations.length; i++) {
    if (!before.endsWith(negations[i])) { continue; }
    if (negations[i] === '别' && NOT_NEGATIONS.some((other: string): boolean => before.endsWith(other))) { return null; }
    return new AiNegation(end - negations[i].length, negations[i]);
  }
  return null;
}

/**
 * The clause's on and off words in order. A negated one turns the other way and counts as one (不要打开, 不要关闭, 取消
 * 隐藏); one followed by 的 describes a thing (关掉的音频, 禁用的驱动器) rather than says what to do with it.
 */
function clauseVerbs(clause: string, onWords: string[], offWords: string[]): AiVerb[] {
  const verbs: AiVerb[] = [];
  const add = (at: number, end: number, on: boolean, word: string, negation: string): void => {
    if (clause.charAt(end) === '的') { return; }
    if ((word === '开着' || word === '关着') && STATE_BUT.some((but: string): boolean => clause.startsWith(but, end))) { return; }
    for (let i = 0; i < verbs.length; i++) {
      if (at < verbs[i].at + verbs[i].length && verbs[i].at < end) { return; }
    }
    let trails: boolean = true;
    if (SHOW.indexOf(word) >= 0 || HIDE.indexOf(word) >= 0) {
      trails = SHOW_AFTER.indexOf(word) >= 0 || (negation !== '' && negation !== '不') ||
        (word === '隐藏' && clause.lastIndexOf('把', at) >= 0);
    }
    verbs.push(new AiVerb(at, end - at, on, trails, negation === '' && REFUSALS.indexOf(word) >= 0));
  };
  const each = (words: string[], visit: (word: string, at: number) => void): void => {
    for (let w = 0; w < words.length; w++) {
      let at: number = clause.indexOf(words[w]);
      while (at >= 0) {
        visit(words[w], at);
        at = clause.indexOf(words[w], at + words[w].length);
      }
    }
  };
  // Negated verbs first: they are the longer reading (不要打开 is one verb, not 不要 and 打开).
  each(onWords.concat(offWords.filter((word: string): boolean => NEGATABLE_OFF.indexOf(word) >= 0)),
    (word: string, at: number): void => {
      const negation: AiNegation | null = negationOf(clause, at, word);
      if (negation !== null) { add(negation.start, at + word.length, offWords.indexOf(word) >= 0, word, negation.word); }
    });
  each(onWords, (word: string, at: number): void => { add(at, at + word.length, true, word, ''); });
  each(offWords, (word: string, at: number): void => {
    // 要不要 asks rather than refuses.
    if (!(word === '不要' && clause.charAt(at - 1) === '要')) { add(at, at + word.length, false, word, ''); }
  });
  verbs.sort((a: AiVerb, b: AiVerb): number => a.at - b.at);
  return verbs;
}

/**
 * Where the clause names a setting: of its words found, the one ending last (the longest at that end: 远程音频 over
 * 音频). A protocol's setting is looked for after that protocol's name (RDP 音频打开 RustDesk 音频关闭). A word with +
 * needs all its parts and is placed at the last one (远程 AI 里不显示执行过程).
 */
function subjectSpan(spec: AiSettingSpec, clause: string): AiSpan | null {
  const protocol: string = protocolOf(spec.id);
  const from: number = protocol !== '' ? Math.max(0, clause.indexOf(protocol)) : 0;
  const span: AiSpan | null = spanFrom(spec, clause, from);
  return span !== null || from === 0 ? span : spanFrom(spec, clause, 0);
}

function spanFrom(spec: AiSettingSpec, clause: string, from: number): AiSpan | null {
  let best: AiSpan | null = null;
  const words: string[] = subjectWords(spec);
  for (let w = 0; w < words.length; w++) {
    if (words[w].length === 0) { continue; }
    const parts: string[] = words[w].split('+');
    let found: boolean = true;
    let at: number = -1;
    for (let p = 0; p < parts.length && found; p++) {
      at = clause.indexOf(parts[p], from);
      found = at >= 0;
    }
    if (!found) { continue; }
    const span: AiSpan = new AiSpan(at, at + parts[parts.length - 1].length);
    if (best === null || span.end > best.end || (span.end === best.end && span.start < best.start)) { best = span; }
  }
  return best;
}

/** The verb right before a setting, with only names or particles between (打开 RDP 的音频), or null. */
function verbBefore(clause: string, span: AiSpan, verbs: AiVerb[]): AiVerb | null {
  for (let i = verbs.length - 1; i >= 0; i--) {
    const end: number = verbs[i].at + verbs[i].length;
    if (end > span.start) { continue; }
    return onlyFiller(clause.slice(end, span.start), BEFORE_FILLER) ? verbs[i] : null;
  }
  return null;
}

/**
 * The verb right after a setting (音频也打开, 音频关闭后再打开), when nothing of its own follows it: the clause ends (or
 * only particles do), or another setting or verb comes next, perhaps after a connector (音频打开剪贴板关闭, 音频打开再把
 * 剪贴板关掉). 取消静音, 不要让别人看到 are about something else.
 */
function verbAfter(clause: string, span: AiSpan, verbs: AiVerb[], named: AiSpan[]): AiVerb | null {
  for (let i = 0; i < verbs.length; i++) {
    const verb: AiVerb = verbs[i];
    if (verb.at < span.end) { continue; }
    if (!verb.trails || !onlyFiller(clause.slice(span.end, verb.at), AFTER_FILLER)) { return null; }
    const end: number = verb.at + verb.length;
    const next: number = skipWords(clause, end, NAMES.concat(CONNECTORS));
    if (onlyFiller(clause.slice(end), PARTICLES) || named.some((other: AiSpan): boolean => other.start === next)) { return verb; }
    const following: AiVerb | undefined = verbs.find((other: AiVerb): boolean => other.at === next);
    if (following === undefined) { return null; }
    // 音频关闭后再打开: the setting ends as the last verb says, unless that verb is the next setting's (音频关闭开启剪贴板).
    const after: number = skipWords(clause, following.at + following.length, BEFORE_FILLER);
    const nextNamed: boolean = named.some((other: AiSpan): boolean => other.start === after);
    return nextNamed || !following.trails ? verb : verbAfter(clause, new AiSpan(span.start, following.at), verbs, named);
  }
  return null;
}

/**
 * Which way a clause turns a switch with no verb next to it: the last verb after it when nothing else is named after
 * that verb (音频剪贴板都打开), else the nearest verb before it (打开之前关闭的剪贴板), else the first verb after it, else
 * '' (the request carried from earlier clauses applies).
 */
/** The last verb after a setting with nothing else named after it (音频剪贴板都打开: 打开), or null. */
function trailingVerb(span: AiSpan, verbs: AiVerb[], named: AiSpan[]): AiVerb | null {
  let trailing: AiVerb | null = null;
  for (let i = 0; i < verbs.length; i++) {
    const verb: AiVerb = verbs[i];
    if (verb.at < span.end || !verb.trails) { continue; }
    if (!named.some((other: AiSpan): boolean => other.start >= verb.at + verb.length)) { trailing = verb; }
  }
  return trailing;
}

function toggleWay(span: AiSpan, verbs: AiVerb[], named: AiSpan[]): string {
  const trailing: AiVerb | null = trailingVerb(span, verbs, named);
  if (trailing !== null) { return trailing.on ? 'on' : 'off'; }
  let before: AiVerb | null = null;
  for (let i = 0; i < verbs.length; i++) {
    if (verbs[i].at + verbs[i].length <= span.start) { before = verbs[i]; }
  }
  if (before !== null) { return before.on ? 'on' : 'off'; }
  for (let i = 0; i < verbs.length; i++) {
    const verb: AiVerb = verbs[i];
    if (verb.at >= span.end && verb.trails) { return verb.on ? 'on' : 'off'; }
  }
  return '';
}

/**
 * A value found for a setting the clause does not name, inside the words or values of one it does name, is that
 * one's (小艺光环 in 悬浮球用小艺光环球 is the orb's 小艺光环球, not also the thinking and done motions).
 */
function claimedByNamed(label: string, spec: AiSettingSpec, named: AiSettingSpec[]): boolean {
  for (let n = 0; n < named.length; n++) {
    if (named[n].id === spec.id) { continue; }
    const words: string[] = subjectWords(named[n]).concat(
      named[n].choices.map((choice: AiSettingChoice): string => compact(choice.label)));
    if (words.some((word: string): boolean => word.length > 0 && (word.indexOf(label) >= 0 || label.indexOf(word) >= 0))) {
      return true;
    }
  }
  return false;
}

/**
 * Whether a clause is only names (RDP 音频, 剪贴板也), a list item waiting for its verb, rather than says something about
 * them (剪贴板不能用了).
 */
function bareClause(clause: string, spans: AiSpan[], protocols: string[]): boolean {
  let rest: string = clause;
  spans.slice().sort((a: AiSpan, b: AiSpan): number => b.start - a.start).forEach((span: AiSpan): void => {
    rest = rest.slice(0, span.start) + rest.slice(span.end);
  });
  protocols.forEach((protocol: string): void => { rest = rest.split(protocol).join(''); });
  // 帮我把 RDP 音频和剪贴板都打开: a request's opening words still leave a list item.
  return onlyFiller(rest, BARE_FILLER.concat(REQUESTS));
}

/** Whether `text` asks for something: a request word not negated (不想要 does not ask). */
function hasRequest(text: string): boolean {
  return REQUESTS.some((word: string): boolean => {
    let at: number = text.indexOf(word);
    while (at >= 0) {
      if (at === 0 || (text.charAt(at - 1) !== '不' && text.charAt(at - 1) !== '没')) { return true; }
      at = text.indexOf(word, at + word.length);
    }
    return false;
  });
}

/** Where the last of these words ends in `text`, or -1. */
function lastEnd(text: string, words: string[]): number {
  let end: number = -1;
  words.forEach((word: string): void => {
    const at: number = text.lastIndexOf(word);
    if (at >= 0 && at + word.length > end) { end = at + word.length; }
  });
  return end;
}

/**
 * The part of a sentence that asks for a change: all of it, or what follows a question or a problem when a request
 * follows it (RustDesk 黑屏了帮我关掉隐私模式), or null when it only asks or describes (音频打开了吗, 我打开了音频但是没
 * 声音, 关闭隐私模式后黑屏了, H265 和 H264 哪个好).
 */
function requestPart(sentence: string): string | null {
  const asked: number = lastEnd(sentence, ASKS);
  const complained: number = lastEnd(sentence, COMPLAINS);
  if (asked >= 0 || complained >= 0) {
    const tail: string = sentence.slice(Math.max(asked, complained));
    // After a problem what follows is read as it is (黑屏了把隐私模式关了, 一直卡住从现在开始编码用 H264): a description
    // with no change in it proposes nothing anyway. After a question only a plain request counts (为什么这么卡先把色深调到
    // 16 位).
    if (complained > asked) { return onlyFiller(tail, PARTICLES.concat(['？', '?'])) ? null : tail; }
    return hasRequest(tail) || tail.indexOf('先把') >= 0 || tail.indexOf('先给我') >= 0 ? tail : null;
  }
  // 选 H265 还是 H264 好.
  if (/还是.+(好|合适|更好)$/.test(sentence)) { return null; }
  // 关掉 RDP 音频好吗, 把色深改成 16 位行吗: a polite request.
  if (POLITE_ENDINGS.test(sentence) && TURN_ON.concat(TURN_OFF, CHANGE_TO, ['改', '换', '调', '设']).some((word: string): boolean =>
    sentence.indexOf(word) >= 0)) { return sentence; }
  // 呢 asks only at the end (然后呢 in the middle of a request goes on).
  const asks: boolean = MAYBE_ASKS.some((word: string): boolean =>
    word === '呢' ? /呢[？?]?$/.test(sentence) : sentence.indexOf(word) >= 0);
  return asks && !hasRequest(sentence) ? null : sentence;
}

/**
 * The clause's verbs with single-character 开 / 关 added where one stands right next to a setting (关 RDP 音频, RDP 音频关,
 * 先关 RDP 音频再开剪贴板) and is not part of a word (打开, 相关, 离开, 开始).
 */
function withSingleVerbs(clause: string, verbs: AiVerb[], named: AiSpan[]): AiVerb[] {
  const all: AiVerb[] = verbs.slice();
  for (let at = 0; at < clause.length; at++) {
    const ch: string = clause.charAt(at);
    if (ch !== '开' && ch !== '关') { continue; }
    if (verbs.some((verb: AiVerb): boolean => at >= verb.at && at < verb.at + verb.length)) { continue; }
    if (at > 0 && NOT_SINGLE_BEFORE.indexOf(clause.charAt(at - 1)) >= 0) { continue; }
    if (named.some((span: AiSpan): boolean => at >= span.start && at < span.end)) { continue; }
    const next: number = skipWords(clause, at + 1, BEFORE_FILLER);
    const before: boolean = named.some((span: AiSpan): boolean => span.start === next);
    const follows: number = skipWords(clause, at + 1, NAMES.concat(CONNECTORS));
    const after: boolean = named.some((span: AiSpan): boolean => span.end <= at &&
      onlyFiller(clause.slice(span.end, at), AFTER_FILLER)) &&
      (onlyFiller(clause.slice(at + 1), PARTICLES) || named.some((span: AiSpan): boolean => span.start === follows) ||
        verbs.some((verb: AiVerb): boolean => verb.at === follows));
    if (!before && !after) { continue; }
    // 别给我开 RDP 音频, 这次先不开驱动器映射.
    const negation: AiNegation | null = negationOf(clause, at, ch);
    if (negation !== null && !all.some((verb: AiVerb): boolean => negation.start < verb.at + verb.length && verb.at <= at)) {
      all.push(new AiVerb(negation.start, at + 1 - negation.start, ch !== '开', true, false));
    } else {
      all.push(new AiVerb(at, 1, ch === '开', true, false));
    }
  }
  all.sort((a: AiVerb, b: AiVerb): number => a.at - b.at);
  return all;
}

/**
 * Whether a clause is a plain request with only its verb in it (帮我关掉吧, 剪贴板也关掉): what is left once the settings
 * and verbs are taken out is request words and particles. 不要紧, 我没打开过, 同事说要关掉 are not.
 */
function plainRequest(clause: string, verbs: AiVerb[], spans: AiSpan[], protocols: string[]): boolean {
  if (verbs.length === 0 || verbs.some((verb: AiVerb): boolean => verb.refuses)) { return false; }
  let rest: string = clause;
  spans.concat(verbs.map((verb: AiVerb): AiSpan => new AiSpan(verb.at, verb.at + verb.length)))
    .sort((a: AiSpan, b: AiSpan): number => b.start - a.start).forEach((span: AiSpan): void => {
      rest = rest.slice(0, Math.max(0, span.start)) + rest.slice(Math.max(span.start, span.end));
    });
  protocols.forEach((protocol: string): void => { rest = rest.split(protocol).join(''); });
  return onlyFiller(rest, REQUESTS.concat(PARTICLES, BARE_FILLER, FOLLOW_UP_FILLER, AFTER_FILLER, CONNECTORS));
}

/** A setting named in a clause, with the verbs right before and after it, and the way it is turned. */
class AiNamedSwitch {
  spec: AiSettingSpec;
  span: AiSpan;
  before: AiVerb | null = null;
  after: AiVerb | null = null;
  way: string = '';

  constructor(spec: AiSettingSpec, span: AiSpan) {
    this.spec = spec;
    this.span = span;
  }
}

/**
 * Gives each switch named in a clause the verb next to it. A verb between two of them (音频打开剪贴板关闭, 打开音频关掉剪贴板)
 * goes to the one that has no other; with verbs on both sides the one after is where it ends (关闭音频后再打开), unless
 * the one before only refuses (不要把音频打开: off). A switch with none takes the next one's when only 都 / 的 … stand
 * between (音频剪贴板都打开), else the position rules.
 */
function turnSwitches(clause: string, switches: AiNamedSwitch[], verbs: AiVerb[], showVerbs: AiVerb[], named: AiSpan[],
  joined: boolean, carried: string, showCarried: string): void {
  switches.forEach((item: AiNamedSwitch): void => {
    const list: AiVerb[] = isShowSwitch(item.spec) ? showVerbs : verbs;
    item.before = verbBefore(clause, item.span, list);
    item.after = verbAfter(clause, item.span, list, named);
  });
  switches.sort((a: AiNamedSwitch, b: AiNamedSwitch): number => a.span.start - b.span.start);
  for (let k = 0; k + 1 < switches.length; k++) {
    // Switches named by the same words (RDP 和 RustDesk 的诊断信息) share their verbs.
    let m: number = k + 1;
    while (m < switches.length && switches[m].span.start === switches[k].span.start) { m++; }
    if (m >= switches.length) { break; }
    const left: AiNamedSwitch = switches[k];
    const right: AiNamedSwitch = switches[m];
    if (left.after === null || right.before === null || left.after.at !== right.before.at) { continue; }
    const toRight: boolean = left.before !== null || right.after === null;
    for (let j = k; j < m; j++) { if (toRight) { switches[j].after = null; } }
    if (!toRight) {
      for (let j = m; j < switches.length && switches[j].span.start === right.span.start; j++) { switches[j].before = null; }
    }
  }
  switches.forEach((item: AiNamedSwitch): void => {
    const before: AiVerb | null = item.before;
    const after: AiVerb | null = item.after;
    if (after !== null) { item.way = (before !== null && before.refuses ? !after.on : after.on) ? 'on' : 'off'; }
    else if (before !== null) { item.way = before.on ? 'on' : 'off'; }
  });
  for (let k = switches.length - 2; k >= 0; k--) {
    const next: AiNamedSwitch = switches[k + 1];
    if (switches[k].way === '' && next.way !== '' && switches[k].span.end <= next.span.start &&
      onlyFiller(clause.slice(switches[k].span.end, next.span.start), LIST_FILLER)) {
      switches[k].way = next.way;
    }
  }
  // 打开音频和剪贴板关闭驱动器: after 和, a switch starting the clause with no verb of its own is turned as the clause
  // before was.
  if (joined) {
    switches.forEach((item: AiNamedSwitch): void => {
      const way: string = isShowSwitch(item.spec) && showCarried !== '' ? showCarried : carried;
      // …unless a verb after it is its own, with nothing else named after that verb (剪贴板也关掉啦).
      if (item.way === '' && way !== '' && onlyFiller(clause.slice(0, item.span.start), BEFORE_FILLER) &&
        trailingVerb(item.span, isShowSwitch(item.spec) ? showVerbs : verbs, named) === null) { item.way = way; }
    });
  }
  switches.forEach((item: AiNamedSwitch): void => {
    if (item.way === '') { item.way = toggleWay(item.span, isShowSwitch(item.spec) ? showVerbs : verbs, named); }
  });
}

/**
 * Setting changes the user asked for in plain words ("把 RustDesk 编码改成 H265，画质优先", "关闭 RDP 音频和剪贴板"),
 * read locally so a request always gets its one-tap buttons even when the model only describes the steps. Clauses
 * carry the protocol and the on/off verb forward ("画质优先" after a RustDesk clause is RustDesk's); a sentence that
 * asks or complains proposes nothing; a later change of mind wins (打开 RDP 音频，算了还是关掉吧).
 */
export function diagnosticAiSettingIntents(question: string): DiagnosticAiSettingProposal[] {
  return settingIntents(question, true);
}

/** The switches a sentence names (for a request right after a question about them: RDP 音频怎么关？帮我关掉吧). */
function switchesNamed(sentence: string, protocolContext: string): AiSettingSpec[] {
  const named: string[] = PROTOCOLS.filter((p: string): boolean => sentence.indexOf(p) >= 0);
  const protocols: string[] = named.length > 0 ? named : protocolContext !== '' ? [protocolContext] : [];
  return SETTINGS.filter((spec: AiSettingSpec): boolean => {
    const protocol: string = protocolOf(spec.id);
    if (protocol !== '' && protocols.length > 0 && protocols.indexOf(protocol) < 0) { return false; }
    return switchValue(spec, true) !== null && subjectSpan(spec, sentence) !== null;
  });
}

function settingIntents(question: string, gate: boolean): DiagnosticAiSettingProposal[] {
  const found: DiagnosticAiSettingProposal[] = [];
  const propose = (spec: AiSettingSpec, value: string): void => {
    const at: number = found.findIndex((p: DiagnosticAiSettingProposal): boolean => p.settingId === spec.id);
    if (at >= 0) { found.splice(at, 1); }
    const current: string | null = diagnosticAiSettingCurrent(spec.id);
    found.push({ settingId: spec.id, currentValue: current ?? '', proposedValue: value, reason: '按你的要求修改',
      evidenceRefs: [], risk: 'low', requiresUserConfirmation: true, rollbackValue: current ?? '' });
  };
  let protocolContext: string = '';
  // The way the last clause with a verb turned things (…和剪贴板 follows it); 显示 / 隐藏 only for the 显示… switches.
  let verbContext: string = '';
  let showContext: string = '';
  // RDP 和 RustDesk 都关掉音频: protocols named alone go on to the next clause.
  let pendingProtocols: string[] = [];
  // RDP 音频和剪贴板都关了: switches named on their own, without a verb, wait for the next clause's.
  let pending: AiSettingSpec[] = [];
  // The switches the last clause turned, for a change of mind after them (also in the next sentence: 不对，关掉).
  let lastTurned: AiSettingSpec[] = [];
  let mindChanging: boolean = false;
  // What the last clause proposed, for a protocol named after it (把诊断信息显示出来，RDP 的).
  let lastProposed: string[] = [];
  // A question just asked: the switches it named and the values it would set, for a request right after it (帮我关掉吧).
  let askedSwitches: AiSettingSpec[] = [];
  let askedValues: DiagnosticAiSettingProposal[] = [];
  // 温和 is a value, not 温 and 和. A question mark ends a sentence and stays with it. Long input is cut: a request is a
  // sentence or two.
  // 1. … 2. …, （1）… (2)…, [1]…: a list marker starts a sentence; a number said as a value (色深改成 16、, H.265) does not.
  const listed: string = question.slice(0, 2000).replace(/(^|[^\d.a-zA-Z成到为深])[(（[]?\d{1,2}[.、)）\]：:](?!\d)/g, '$1\u0002')
    .replace(/[①②③④⑤⑥⑦⑧⑨⑩]/g, '\u0002');
  const sentences: string[] = listed.split('温和').join('\u0001').split('？').join('？\u0002')
    .split('?').join('?\u0002').split(/[\u0002，,。；;！!\n]/)
    .map((part: string): string => compact(part.split('\u0001').join('温和'))).filter((part: string): boolean => part.length > 0);
  sentences.forEach((whole: string): void => {
    // A question or a problem is for the assistant; its protocol still says what the next sentence is about.
    const asked: string | null = gate ? requestPart(whole) : whole;
    const head: string = asked === null ? whole : whole.slice(0, whole.length - asked.length);
    const headProtocols: string[] = PROTOCOLS.filter((p: string): boolean => head.indexOf(p) >= 0);
    if (headProtocols.length > 0) { protocolContext = headProtocols[0]; }
    if (asked === null) {
      pending = [];
      // Only a question is something a request after it can be about; a problem described is not (复制失败，不要紧).
      const isQuestion: boolean = lastEnd(whole, ASKS) >= lastEnd(whole, COMPLAINS) ||
        QUESTION_WORDS.some((word: string): boolean => whole.indexOf(word) >= 0);
      if (!isQuestion) { askedSwitches = []; askedValues = []; return; }
      askedSwitches = switchesNamed(whole, protocolContext);
      askedValues = settingIntents(whole, false).filter((proposal: DiagnosticAiSettingProposal): boolean => {
        const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(proposal.settingId);
        return spec !== undefined && switchValue(spec, true) === null;
      });
      return;
    }
    const followsQuestion: boolean = askedSwitches.length > 0 || askedValues.length > 0;
    const questionSwitches: AiSettingSpec[] = askedSwitches;
    const questionValues: DiagnosticAiSettingProposal[] = askedValues;
    askedSwitches = [];
    askedValues = [];
    const sentence: string = asked;
    const clauses: string[] = sentence.split('温和').join('\u0001').split(/、|并且|然后|同时|还有|以及|和/)
      .map((part: string): string => part.split('\u0001').join('温和')).filter((part: string): boolean => part.length > 0);
    clauses.forEach((clause: string, index: number): void => {
      const named: string[] = PROTOCOLS.filter((p: string): boolean => clause.indexOf(p) >= 0);
      if (named.length > 0) { protocolContext = named[0]; }
      // 剪贴板留着, 先不要动 RDP 剪贴板: nothing to change here.
      if (NO_CHANGE.some((word: string): boolean => clause.indexOf(word) >= 0)) { return; }
      const listed: string[] = named.concat(pendingProtocols.filter((p: string): boolean => named.indexOf(p) < 0));
      const protocols: string[] = listed.length > 0 ? listed : protocolContext !== '' ? [protocolContext] : [];
      const candidates: AiSettingSpec[] = SETTINGS.filter((spec: AiSettingSpec): boolean => {
        const protocol: string = protocolOf(spec.id);
        if (protocol !== '' && protocols.length > 0 && protocols.indexOf(protocol) < 0) { return false; }
        return !(protocol === '' && named.length > 0 && spec.id.indexOf('ui.') !== 0 && spec.id.indexOf('remote.') !== 0);
      });
      const namedSpans: AiSpan[] = [];
      const namedSpecs: AiSettingSpec[] = [];
      const spanOf: Map<string, AiSpan> = new Map<string, AiSpan>();
      candidates.forEach((spec: AiSettingSpec): void => {
        const span: AiSpan | null = subjectSpan(spec, clause);
        if (span !== null) { namedSpans.push(span); namedSpecs.push(spec); spanOf.set(spec.id, span); }
      });
      const verbs: AiVerb[] = withSingleVerbs(clause, clauseVerbs(clause, TURN_ON, TURN_OFF), namedSpans);
      const asking: boolean = QUESTION_WORDS.some((word: string): boolean => clause.indexOf(word) >= 0);
      const offNext = (span: AiSpan): boolean => {
        const before: AiVerb | null = verbBefore(clause, span, verbs);
        const after: AiVerb | null = verbAfter(clause, span, verbs, []);
        return (after !== null && !after.on) || (after === null && before !== null && !before.on);
      };
      const showVerbs: AiVerb[] = asking ? verbs :
        withSingleVerbs(clause, clauseVerbs(clause, TURN_ON.concat(SHOW), TURN_OFF.concat(HIDE)), namedSpans);
      const switches: AiNamedSwitch[] = [];
      namedSpecs.forEach((spec: AiSettingSpec): void => {
        const span: AiSpan | undefined = spanOf.get(spec.id);
        if (span !== undefined && switchValue(spec, true) !== null) { switches.push(new AiNamedSwitch(spec, span)); }
      });
      turnSwitches(clause, switches, verbs, showVerbs, namedSpans, index > 0, verbContext, showContext);
      // Switches waiting from the clauses before take this one's way: its first switch's, else where it ends.
      const pendingVerbs: AiVerb[] = pending.length > 0 && isShowSwitch(pending[0]) ? showVerbs : verbs;
      if (pending.length > 0 && pendingVerbs.length > 0 && !plainRequest(clause, pendingVerbs, namedSpans, named)) {
        // RustDesk 隐私模式，我没打开过: the next clause with a verb says something else about it. One without (剪贴板、)
        // is another item of the list.
        pending = [];
      }
      if (pending.length > 0) {
        pending = pending.filter((spec: AiSettingSpec): boolean => {
          const first: AiNamedSwitch | undefined = switches.find((item: AiNamedSwitch): boolean => item.way !== '' &&
            isShowSwitch(item.spec) === isShowSwitch(spec));
          const list: AiVerb[] = isShowSwitch(spec) ? showVerbs : verbs;
          const way: string = first !== undefined ? first.way : list.length > 0 ? (list[list.length - 1].on ? 'on' : 'off') : '';
          if (way === '') { return true; }
          const value: string | null = switchValue(spec, way === 'on');
          if (value !== null) { propose(spec, value); }
          return false;
        });
      }
      const bare: boolean = bareClause(clause, namedSpans, named);
      // 帮我关掉吧 / 帮我改一下 right after a question: what the question was about.
      if (followsQuestion && index === 0 && namedSpecs.length === 0) {
        if (plainRequest(clause, verbs, [], named)) {
          const way: boolean = verbs[verbs.length - 1].on;
          questionSwitches.forEach((spec: AiSettingSpec): void => {
            const value: string | null = switchValue(spec, way);
            if (value !== null) { propose(spec, value); }
          });
        }
        if (REQUESTS.concat(CHANGE_TO, ['改', '换', '调', '设']).some((word: string): boolean => clause.indexOf(word) >= 0)) {
          questionValues.forEach((proposal: DiagnosticAiSettingProposal): void => {
            const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(proposal.settingId);
            if (spec === undefined) { return; }
            // 哪个好？先给我换成 H265: the value the request names itself.
            const own: AiSettingChoice | null = namedChoice(spec, clause, true);
            propose(spec, own !== null ? own.value : proposal.proposedValue);
          });
        }
      }
      const changing: boolean = CHANGE_OF_MIND.some((word: string): boolean => clause.indexOf(word) >= 0);
      if (namedSpecs.length === 0 && verbs.length === 0 && changing) { mindChanging = true; return; }
      if (namedSpecs.length === 0 && verbs.length > 0 && lastTurned.length > 0 && (changing || mindChanging)) {
        const way: boolean = verbs[verbs.length - 1].on;
        lastTurned.forEach((spec: AiSettingSpec): void => {
          const value: string | null = switchValue(spec, way);
          if (value !== null) { propose(spec, value); }
        });
      }
      mindChanging = false;
      // 把诊断信息显示出来，RDP 的: a protocol named after the change narrows it.
      if (named.length > 0 && namedSpecs.length === 0 && showVerbs.length === 0 && lastProposed.length > 0 &&
        bareClause(clause, [], named) && lastProposed.some((id: string): boolean => named.indexOf(protocolOf(id)) >= 0)) {
        lastProposed.forEach((id: string): void => {
          const protocol: string = protocolOf(id);
          const at: number = found.findIndex((p: DiagnosticAiSettingProposal): boolean => p.settingId === id);
          if (protocol !== '' && named.indexOf(protocol) < 0 && at >= 0) { found.splice(at, 1); }
        });
        return;
      }
      // A clause's changes are proposed in the catalog's order, as they always were.
      const values: Map<string, string> = new Map<string, string>();
      switches.forEach((item: AiNamedSwitch): void => {
        let way: string = item.way;
        // Only a clause that is just names (剪贴板也一样) is turned as the one before; 剪贴板开开 has a verb of its own.
        if (way === '' && bare) { way = isShowSwitch(item.spec) && showContext !== '' ? showContext : verbContext; }
        if (way === '') {
          if (bare) { pending.push(item.spec); }
          return;
        }
        const value: string | null = switchValue(item.spec, way === 'on');
        if (value !== null) { values.set(item.spec.id, value); }
      });
      candidates.forEach((spec: AiSettingSpec): void => {
        if (switchValue(spec, true) !== null) { return; }
        const span: AiSpan | undefined = spanOf.get(spec.id);
        let choice: AiSettingChoice | null = namedChoice(spec, clause, span !== undefined);
        if (choice === null && span !== undefined) { choice = otherOfRefused(spec, clause); }
        // 发送按钮光晕关掉, 展开动画关闭: a setting with an 关闭 / 不显示 value takes it when turned off.
        if (choice === null && span !== undefined && offNext(span)) {
          const off: AiSettingChoice | undefined = spec.choices.find((item: AiSettingChoice): boolean =>
            OFF_LABELS.indexOf(item.label) >= 0 || item.label === '不显示');
          choice = off !== undefined ? off : null;
        }
        if (choice === null) { return; }
        if (span === undefined && claimedByNamed(compact(choice.label), spec, namedSpecs)) { return; }
        values.set(spec.id, choice.value);
      });
      SETTINGS.forEach((spec: AiSettingSpec): void => {
        const value: string | undefined = values.get(spec.id);
        if (value !== undefined) { propose(spec, value); }
      });
      if (values.size > 0) { lastProposed = Array.from(values.keys()); }
      const turned: AiSettingSpec[] = switches.filter((item: AiNamedSwitch): boolean => values.has(item.spec.id))
        .map((item: AiNamedSwitch): AiSettingSpec => item.spec);
      if (turned.length > 0) { lastTurned = turned; }
      // 麻烦你 RDP 音频怎么关？帮我关掉吧: switches named without a way are what a request right after is about.
      const unturned: AiSettingSpec[] = switches.filter((item: AiNamedSwitch): boolean => !values.has(item.spec.id) &&
        pending.indexOf(item.spec) < 0).map((item: AiNamedSwitch): AiSettingSpec => item.spec);
      if (unturned.length > 0 && index === clauses.length - 1) { askedSwitches = unturned; }
      // Protocols named in an otherwise empty clause (RDP，RustDesk，音频关掉) carry on; one said in passing does not.
      const verbSpans: AiSpan[] = showVerbs.map((verb: AiVerb): AiSpan => new AiSpan(verb.at, verb.at + verb.length));
      pendingProtocols = namedSpans.length === 0 && bareClause(clause, verbSpans, named) ? listed : [];
      if (verbs.length > 0) { verbContext = verbs[verbs.length - 1].on ? 'on' : 'off'; }
      if (!asking && showVerbs.length > 0) { showContext = showVerbs[showVerbs.length - 1].on ? 'on' : 'off'; }
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
