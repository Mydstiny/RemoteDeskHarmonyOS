/** Pure command-registry and ranking policy for the SSH workbench. */

export type SshCommandCategory = 'host' | 'session' | 'action';

export type SshCommandDanger = 'none' | 'confirm' | 'danger';

export type SshCommandActionKind =
  | 'open_host'
  | 'activate_session'
  | 'new_session'
  | 'open_terminal_search'
  | 'open_terminal_profile'
  | 'open_productivity'
  | 'open_sftp'
  | 'open_transfer_center'
  | 'open_forwarding'
  | 'close_active_tab'
  | 'toggle_active_tab_pin'
  | 'show_all_tabs';

export interface SshCommandDescriptor {
  id: string;
  title: string;
  subtitle: string;
  keywords: Array<string>;
  category: SshCommandCategory;
  danger: SshCommandDanger;
  enabled: boolean;
  action: SshCommandActionKind;
  targetId: string;
  shortcut: string;
}

export interface SshCommandHostRef {
  hostId: string;
  label: string;
  opened: boolean;
  available: boolean;
}

export interface SshCommandSessionRef {
  tabId: string;
  hostId: string;
  label: string;
  stateLabel: string;
  active: boolean;
  pinned: boolean;
}

export interface SshCommandCapabilities {
  searchAvailable: boolean;
  profileAvailable: boolean;
  sftpAvailable: boolean;
  transferCenterAvailable: boolean;
  forwardingAvailable: boolean;
  productivityAvailable?: boolean;
  closeAvailable: boolean;
  activePinned: boolean;
}

export interface SshCommandExecutionFence {
  pageGeneration: number;
  bindingGeneration: number;
  hostId: string;
  sessionGeneration: number;
  workbenchEnabled: boolean;
  modalActive: boolean;
}

interface RankedSshCommand {
  command: SshCommandDescriptor;
  score: number;
  sourceIndex: number;
}

const SSH_COMMAND_QUERY_MAX_CHARS: number = 256;
const SSH_COMMAND_RESULT_MAX: number = 120;

function normalizedText(value: string): string {
  return value.trim().toLowerCase();
}

function commandIdToken(value: string): string {
  const normalized: string = value.trim();
  if (normalized.length <= 64) { return normalized; }
  let hash: number = 2166136261;
  for (let index: number = 0; index < normalized.length; index++) {
    hash ^= normalized.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return normalized.slice(0, 40) + '-' + hash.toString(16);
}

function textScore(text: string, token: string, exact: number, prefix: number,
  wordPrefix: number, contains: number): number {
  if (text.length === 0 || token.length === 0) { return -1; }
  if (text === token) { return exact; }
  if (text.startsWith(token)) { return prefix; }
  const words: Array<string> = text.split(/\s+/);
  for (let index: number = 0; index < words.length; index++) {
    if (words[index].startsWith(token)) { return wordPrefix; }
  }
  if (text.indexOf(token) >= 0) { return contains; }
  return -1;
}

function tokenScore(command: SshCommandDescriptor, token: string): number {
  let best: number = textScore(normalizedText(command.title), token, 1200, 900, 820, 650);
  const idScore: number = textScore(normalizedText(command.id), token, 1100, 760, 680, 520);
  if (idScore > best) { best = idScore; }
  for (let index: number = 0; index < command.keywords.length; index++) {
    const keywordScore: number = textScore(
      normalizedText(command.keywords[index]), token, 760, 620, 560, 420);
    if (keywordScore > best) { best = keywordScore; }
  }
  const subtitleScore: number = textScore(
    normalizedText(command.subtitle), token, 360, 300, 260, 180);
  if (subtitleScore > best) { best = subtitleScore; }
  return best;
}

function actionCommand(id: string, title: string, subtitle: string, keywords: Array<string>,
  action: SshCommandActionKind, enabled: boolean, shortcut: string = '',
  danger: SshCommandDanger = 'none'): SshCommandDescriptor {
  return {
    id,
    title,
    subtitle,
    keywords,
    category: 'action',
    danger,
    enabled,
    action,
    targetId: '',
    shortcut
  };
}

/**
 * Build the only command list consumed by the Palette. Components must never
 * infer actions from labels or assemble an alternative registry.
 */
export function buildSshCommandRegistry(hosts: Array<SshCommandHostRef>,
  sessions: Array<SshCommandSessionRef>, capabilities: SshCommandCapabilities): Array<SshCommandDescriptor> {
  const commands: Array<SshCommandDescriptor> = [];
  commands.push(actionCommand('ssh.action.new-session', '新建 SSH 会话',
    '选择已保存主机并开始连接', ['new', 'session', 'host', '连接', '主机'],
    'new_session', hosts.length > 0, 'Ctrl/Meta+T'));
  commands.push(actionCommand('ssh.action.search', '搜索当前终端',
    '在当前会话的 scrollback 中查找', ['find', 'search', 'terminal', '查找'],
    'open_terminal_search', capabilities.searchAvailable, 'Ctrl/Meta+F'));
  commands.push(actionCommand('ssh.action.profile', '终端 Profile',
    '选择配色、字体和终端行为', ['profile', 'theme', 'font', '外观', '字体'],
    'open_terminal_profile', capabilities.profileAvailable));
  commands.push(actionCommand('ssh.action.productivity', 'Snippet 与命令历史',
    '打开本地加密的 Snippet、历史和 Shell integration 设置',
    ['snippet', 'history', 'completion', 'productivity', '片段', '历史', '补全'],
    'open_productivity', capabilities.productivityAvailable === true));
  commands.push(actionCommand('ssh.action.sftp', '打开 SFTP',
    '在当前 SSH 会话中浏览和传输文件', ['file', 'transfer', 'sftp', '文件', '传输'],
    'open_sftp', capabilities.sftpAvailable));
  commands.push(actionCommand('ssh.action.transfer-center', 'SSH 传输中心',
    '查看所有主机的上传、下载和待处理任务',
    ['transfer', 'tasks', 'queue', '传输', '任务', '队列'],
    'open_transfer_center', capabilities.transferCenterAvailable));
  commands.push(actionCommand('ssh.action.forwarding', '端口转发',
    '管理本地、远端和动态隧道', ['forward', 'tunnel', 'proxy', '转发', '隧道'],
    'open_forwarding', capabilities.forwardingAvailable));
  commands.push(actionCommand('ssh.action.pin-tab',
    capabilities.activePinned ? '取消固定当前标签' : '固定当前标签',
    '固定标签始终排列在普通标签之前', ['pin', 'tab', '固定', '标签'],
    'toggle_active_tab_pin', capabilities.closeAvailable));
  commands.push(actionCommand('ssh.action.all-tabs', '所有 SSH 标签',
    '打开会话列表并快速切换', ['tabs', 'sessions', 'overflow', '标签', '会话'],
    'show_all_tabs', sessions.length > 0));
  commands.push(actionCommand('ssh.action.close-tab', '断开并关闭当前标签',
    '关闭当前连接；后台传输会保留可恢复记录', ['close', 'disconnect', 'tab', '关闭', '断开'],
    'close_active_tab', capabilities.closeAvailable, 'Ctrl/Meta+W', 'confirm'));

  for (let index: number = 0; index < sessions.length; index++) {
    const session: SshCommandSessionRef = sessions[index];
    const tabToken: string = commandIdToken(session.tabId);
    commands.push({
      id: 'ssh.session.activate.' + tabToken,
      title: session.label.length > 0 ? session.label : 'SSH 会话',
      subtitle: (session.pinned ? '已固定 · ' : '') + session.stateLabel +
        (session.active ? ' · 当前标签' : ''),
      keywords: ['session', 'tab', 'activate', '会话', '标签', session.hostId],
      category: 'session',
      danger: 'none',
      enabled: !session.active,
      action: 'activate_session',
      targetId: session.hostId,
      shortcut: index < 9 ? 'Alt+' + (index + 1).toString() : ''
    });
  }

  for (let index: number = 0; index < hosts.length; index++) {
    const host: SshCommandHostRef = hosts[index];
    const hostToken: string = commandIdToken(host.hostId);
    commands.push({
      id: 'ssh.host.open.' + hostToken,
      title: host.label.length > 0 ? host.label : 'SSH 主机',
      subtitle: host.opened ? '标签已打开，可直接切换' : '已保存的 SSH 主机',
      keywords: ['host', 'connect', 'open', '主机', '连接', host.hostId],
      category: 'host',
      danger: 'none',
      enabled: host.available,
      action: 'open_host',
      targetId: host.hostId,
      shortcut: ''
    });
  }
  return commands;
}

export function rankSshCommands(commands: Array<SshCommandDescriptor>, query: string,
  limit: number = 40): Array<SshCommandDescriptor> {
  const boundedLimit: number = Math.min(SSH_COMMAND_RESULT_MAX,
    Math.max(1, Number.isFinite(limit) ? Math.floor(limit) : 40));
  const normalizedQuery: string = normalizedText(query.slice(0, SSH_COMMAND_QUERY_MAX_CHARS));
  const tokens: Array<string> = normalizedQuery.length === 0 ? [] : normalizedQuery.split(/\s+/);
  const ranked: Array<RankedSshCommand> = [];
  for (let index: number = 0; index < commands.length; index++) {
    const command: SshCommandDescriptor = commands[index];
    let score: number = command.enabled ? 10 : 0;
    let matched: boolean = true;
    for (let tokenIndex: number = 0; tokenIndex < tokens.length; tokenIndex++) {
      const value: number = tokenScore(command, tokens[tokenIndex]);
      if (value < 0) {
        matched = false;
        break;
      }
      score += value;
    }
    if (matched) { ranked.push({ command, score, sourceIndex: index }); }
  }
  ranked.sort((left: RankedSshCommand, right: RankedSshCommand): number => {
    if (left.score !== right.score) { return right.score - left.score; }
    if (left.sourceIndex !== right.sourceIndex) { return left.sourceIndex - right.sourceIndex; }
    if (left.command.id < right.command.id) { return -1; }
    if (left.command.id > right.command.id) { return 1; }
    return 0;
  });
  const result: Array<SshCommandDescriptor> = [];
  for (let index: number = 0; index < ranked.length && result.length < boundedLimit; index++) {
    result.push(ranked[index].command);
  }
  return result;
}

export function findSshCommand(commands: Array<SshCommandDescriptor>,
  commandId: string): SshCommandDescriptor | null {
  const normalizedId: string = commandId.trim();
  if (normalizedId.length === 0) { return null; }
  for (let index: number = 0; index < commands.length; index++) {
    if (commands[index].id === normalizedId) { return commands[index]; }
  }
  return null;
}

export function canExecuteSshCommand(command: SshCommandDescriptor | null): boolean {
  return command !== null && command.id.trim().length > 0 && command.enabled;
}

/** A queued Sheet action may execute only against the exact owner that selected it. */
export function matchesSshCommandExecutionFence(expected: SshCommandExecutionFence,
  current: SshCommandExecutionFence): boolean {
  return expected.workbenchEnabled && current.workbenchEnabled && !current.modalActive &&
    expected.pageGeneration === current.pageGeneration &&
    expected.bindingGeneration === current.bindingGeneration &&
    expected.hostId.trim().length > 0 && expected.hostId === current.hostId &&
    expected.sessionGeneration === current.sessionGeneration;
}
