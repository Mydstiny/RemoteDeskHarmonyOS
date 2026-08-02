import {
  defaultRemoteShortcutContext,
  formatRemoteShortcut,
  RemoteKeyboardLayout,
  RemoteShortcutAction,
  RemoteShortcutChord,
  RemoteShortcutContext,
  RemoteShortcutId,
  RemoteShortcutKind,
  RemoteShortcutKey,
  RemoteShortcutProtocol
} from './RemoteShortcutCatalog';

export {
  RemoteKeyboardLayout,
  RemoteShortcutAction,
  RemoteShortcutContext,
  RemoteShortcutId
} from './RemoteShortcutCatalog';

export const REMOTE_SHORTCUT_CTRL_KEYCODE: number = 2072;
export const REMOTE_SHORTCUT_COMMAND_KEYCODE: number = 2076;
export const REMOTE_SHORTCUT_C_KEYCODE: number = 2019;
export const REMOTE_SHORTCUT_X_KEYCODE: number = 2040;
export const REMOTE_SHORTCUT_V_KEYCODE: number = 2038;
export const SSH_CTRL_C_BYTE: number = 0x03;
export const SSH_CTRL_V_BYTE: number = 0x16;
export const SSH_CTRL_X_BYTE: number = 0x18;
export const SSH_PASTE_MAX_BYTES: number = 256 * 1024;

function legacyStorageToken(value: string): string {
  return value.trim().replace(/[^A-Za-z0-9._-]/g, '_');
}

function hexCodeUnit(code: number): string {
  const raw: string = code.toString(16);
  return '0000'.substring(0, Math.max(0, 4 - raw.length)) + raw;
}

/**
 * Length-preserving UTF-16 code-unit encoding.  Unlike the old replacement
 * token, `a/b`, `a_b`, and Unicode host/account ids can never collide.
 */
function storageToken(value: string): string {
  const trimmed: string = value.trim();
  let encoded: string = 'u' + trimmed.length.toString(16) + '_';
  for (let index = 0; index < trimmed.length; index++) {
    encoded += hexCodeUnit(trimmed.charCodeAt(index));
  }
  return encoded;
}

function legacyStorageTokenIsUnambiguous(value: string): boolean {
  const trimmed: string = value.trim();
  return trimmed.length > 0 && legacyStorageToken(trimmed) === trimmed;
}

/**
 * VNC keyboard choices are owned by the account/profile and host.  The active
 * connection generation is only an ephemeral override fence; it is not the
 * durable preference identity.
 */
export function vncShortcutHostStorageKey(hostId: string, ownerId: string = 'local'): string {
  return 'vncShortcutLayout:v3:' + storageToken(ownerId) + ':' + storageToken(hostId);
}

export function vncShortcutSessionStorageKey(hostId: string, generation: number,
  ownerId: string = 'local'): string {
  return 'vncShortcutSessionLayout:v3:' + storageToken(ownerId) + ':' + storageToken(hostId) +
    ':' + generation.toString();
}

export function vncShortcutMigrationStorageKey(hostId: string, ownerId: string = 'local'): string {
  return 'vncShortcutLayoutMigrated:v3:' + storageToken(ownerId) + ':' + storageToken(hostId);
}

/** Read-only compatibility key for pre-v3 Preferences data. */
export function vncShortcutLegacyHostStorageKey(hostId: string,
  ownerId: string = 'local'): string {
  return 'vncShortcutLayout:v2:' + legacyStorageToken(ownerId) + ':' + legacyStorageToken(hostId);
}

/** A legacy value is migratable only when its host and owner are both proven. */
export function vncShortcutLegacyMigrationAllowed(hostId: string, ownerId: string,
  legacyHostId: string, legacyOwnerId: string): boolean {
  return hostId.trim().length > 0 && ownerId.trim().length > 0 &&
    legacyHostId.trim() === hostId.trim() && legacyOwnerId.trim() === ownerId.trim() &&
    legacyStorageTokenIsUnambiguous(hostId) && legacyStorageTokenIsUnambiguous(ownerId);
}

function normalized(value: string | undefined): string {
  return (value ?? '').trim().toLowerCase();
}

function platformLayout(value: string | undefined): RemoteKeyboardLayout {
  const candidate: string = normalized(value);
  if (candidate === 'macos' || candidate === 'mac' || candidate === 'darwin' || candidate === 'osx') {
    return 'command';
  }
  if (candidate === 'windows' || candidate === 'windows10' || candidate === 'windows11' ||
    candidate === 'win' || candidate === 'linux' || candidate === 'ubuntu' || candidate === 'unix') {
    return 'ctrl';
  }
  return 'unknown';
}

function explicitLayout(value: string | undefined): RemoteKeyboardLayout {
  const candidate: string = normalized(value);
  if (candidate === 'command' || candidate === 'macos' || candidate === 'mac') { return 'command'; }
  if (candidate === 'ctrl' || candidate === 'control' || candidate === 'windows' || candidate === 'linux') {
    return 'ctrl';
  }
  return 'unknown';
}

/** RustDesk authority order: connected peer info, pre-connect Pro hint, session choice. */
export function resolveRustDeskKeyboardLayout(peerInfoPlatform: string | undefined,
  proHintPlatform: string | undefined, sessionChoice: string | undefined,
  isPreconnect: boolean): RemoteKeyboardLayout {
  const peer: RemoteKeyboardLayout = platformLayout(peerInfoPlatform);
  if (peer !== 'unknown') { return peer; }
  if (isPreconnect) {
    const pro: RemoteKeyboardLayout = platformLayout(proHintPlatform);
    if (pro !== 'unknown') { return pro; }
  }
  const selected: RemoteKeyboardLayout = explicitLayout(sessionChoice);
  return selected;
}

/**
 * VNC records from before the layout field are deliberately migrated to a
 * visible Ctrl choice. The UI must never silently display a guessed macOS key.
 */
export function migrateVncKeyboardLayout(raw: string | undefined): RemoteKeyboardLayout {
  const result: RemoteKeyboardLayout = explicitLayout(raw);
  return result === 'command' ? 'command' : 'ctrl';
}

function vncLayout(context: RemoteShortcutContext): RemoteKeyboardLayout {
  const session: RemoteKeyboardLayout = explicitLayout(context.sessionLayout);
  if (session !== 'unknown') { return session; }
  const host: RemoteKeyboardLayout = explicitLayout(context.hostLayout);
  if (host !== 'unknown') { return host; }
  // Unknown VNC layouts are intentionally explicit Ctrl, not an inferred OS.
  return 'ctrl';
}

function layoutForContext(context: RemoteShortcutContext): RemoteKeyboardLayout {
  if (context.protocol === 'rdp' || context.protocol === 'ssh') { return 'ctrl'; }
  if (context.protocol === 'vnc') { return vncLayout(context); }
  return resolveRustDeskKeyboardLayout(
    context.peerInfoPlatform ?? context.remotePlatform,
    context.proHintPlatform,
    context.sessionChoice ?? context.sessionLayout,
    context.isPreconnect === true
  );
}

function keyForId(id: RemoteShortcutId): RemoteShortcutKey | null {
  if (id === 'copy' || id === 'terminalCtrlC') { return 'C'; }
  if (id === 'cut' || id === 'terminalCtrlX') { return 'X'; }
  if (id === 'pasteShortcut' || id === 'terminalCtrlV') { return 'V'; }
  return null;
}

function baseAction(id: RemoteShortcutId, label: string, kind: RemoteShortcutKind,
  layout: RemoteKeyboardLayout, enabled: boolean, reason: string,
  chord: RemoteShortcutChord | null = null, terminalByte: number = -1,
  subtitle: string = '', keyCodes: Array<number> = []): RemoteShortcutAction {
  const display: string = subtitle.length > 0 ? subtitle : formatRemoteShortcut(chord, layout);
  return {
    id,
    label,
    subtitle: display,
    accessibilityText: display.length > 0 ? label + '，' + display : label,
    kind,
    chord,
    terminalByte,
    layout,
    enabled,
    reason,
    keyCodes
  };
}

function connectionReason(context: RemoteShortcutContext): string {
  if (!context.connected || context.sessionId <= 0 || context.generation <= 0) {
    return '会话已断开或输入代代号已过期';
  }
  if (context.browseMode === true) { return '浏览模式已启用，远端输入已暂停'; }
  if (context.viewOnly) { return '只读会话已禁用远端输入'; }
  if (!context.canSendKeys) { return '当前会话不具备按键发送能力'; }
  return '';
}

function canSendRemoteKeys(context: RemoteShortcutContext): boolean {
  return connectionReason(context).length === 0;
}

function canSendText(context: RemoteShortcutContext): boolean {
  return context.connected && context.sessionId > 0 && context.generation > 0 &&
    context.canSendText && !context.viewOnly && context.browseMode !== true;
}

function localCopyEnabled(context: RemoteShortcutContext): boolean {
  return context.connected && context.sessionId > 0 && context.generation > 0;
}

function localPasteReason(context: RemoteShortcutContext): string {
  if (!canSendText(context)) {
    return connectionReason(context) || '当前会话不具备终端文本发送能力';
  }
  const bytes: number = context.pasteTextBytes ?? 0;
  if (bytes > SSH_PASTE_MAX_BYTES) { return '文本超过 256KB 上限'; }
  if (!context.clipboardEnabled) { return '剪贴板能力未启用'; }
  return '';
}

function remoteAction(id: RemoteShortcutId, label: string, layout: RemoteKeyboardLayout,
  context: RemoteShortcutContext): RemoteShortcutAction {
  const key: RemoteShortcutKey = keyForId(id) as RemoteShortcutKey;
  const modifier: 'ctrl' | 'command' = layout === 'command' ? 'command' : 'ctrl';
  const chord: RemoteShortcutChord = { modifier, key };
  let enabled: boolean = canSendRemoteKeys(context);
  let reason: string = connectionReason(context);
  return baseAction(id, label, 'remote-chord', layout, enabled, reason, chord);
}

function utilityActions(layout: RemoteKeyboardLayout,
  context: RemoteShortcutContext): Array<RemoteShortcutAction> {
  // These are Windows utility sequences. A macOS/Command remote must not show
  // a misleading Win/Alt catalog entry; C/X/V remain available above.
  if (layout === 'command') { return []; }
  const enabled: boolean = canSendRemoteKeys(context);
  const reason: string = connectionReason(context);
  return [
    baseAction('altTab', '窗口切换', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Alt+Tab', [2045, 2049]),
    baseAction('altF4', '关闭窗口', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Alt+F4', [2045, 2093]),
    baseAction('winRun', '运行', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Win+R', [2076, 2034]),
    baseAction('winDesktop', '显示桌面', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Win+D', [2076, 2020]),
    baseAction('ctrlShiftEsc', '任务管理器', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Ctrl+Shift+Esc', [2072, 2047, 2070]),
    baseAction('winExplorer', '文件资源管理器', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Win+E', [2076, 2021]),
    baseAction('ctrlAltDel', '安全序列', 'remote-chord', 'ctrl', enabled, reason,
      null, -1, 'Ctrl+Alt+Del', [2072, 2045, 2071])
  ];
}

export function remoteShortcutActionsForContext(context: RemoteShortcutContext): Array<RemoteShortcutAction> {
  const layout: RemoteKeyboardLayout = layoutForContext(context);
  if (context.protocol === 'ssh') {
    const terminalEnabled: boolean = canSendText(context);
    const terminalReason: string = terminalEnabled ? '' : connectionReason(context);
    const pasteReason: string = localPasteReason(context);
    return [
      baseAction('terminalCtrlC', '中断', 'terminal-byte', 'ctrl', terminalEnabled, terminalReason,
        null, SSH_CTRL_C_BYTE, 'Ctrl+C · 0x03'),
      baseAction('terminalCtrlV', '终端 Ctrl+V', 'terminal-byte', 'ctrl', terminalEnabled, terminalReason,
        null, SSH_CTRL_V_BYTE, 'Ctrl+V · 0x16'),
      baseAction('terminalCtrlX', '终端 Ctrl+X', 'terminal-byte', 'ctrl', terminalEnabled, terminalReason,
        null, SSH_CTRL_X_BYTE, 'Ctrl+X · 0x18'),
      baseAction('terminalCopySelection', '复制选区', 'local', 'ctrl', localCopyEnabled(context), '', null, -1, '本地剪贴板'),
      baseAction('pasteLocalText', '粘贴本地文本', 'local-text', 'ctrl', pasteReason.length === 0, pasteReason,
        null, -1, context.bracketedPaste === true ? '≤256KB · bracketed paste' : '≤256KB')
    ];
  }
  const actions: Array<RemoteShortcutAction> = [
    remoteAction('copy', '复制', layout, context),
    remoteAction('cut', '剪切', layout, context),
    remoteAction('pasteShortcut', '粘贴快捷键', layout, context)
  ];
  const pasteReason: string = localPasteReason(context);
  actions.push(baseAction('pasteLocalText', '粘贴本地文本', 'local-text', layout,
    pasteReason.length === 0, pasteReason, null, -1,
    context.bracketedPaste === true ? '≤256KB · bracketed paste' : '≤256KB'));
  const utilities: Array<RemoteShortcutAction> = utilityActions(layout, context);
  for (let index = 0; index < utilities.length; index++) {
    actions.push(utilities[index]);
  }
  return actions;
}

export function resolveShortcutAction(id: string, context: RemoteShortcutContext): RemoteShortcutAction {
  const actions: Array<RemoteShortcutAction> = remoteShortcutActionsForContext(context);
  for (let index = 0; index < actions.length; index++) {
    if (actions[index].id === id) { return actions[index]; }
  }
  const fallbackContext: RemoteShortcutContext = context.protocol === 'ssh' ?
    context : defaultRemoteShortcutContext(context.protocol);
  return baseAction('copy', '不可用快捷键', 'local', layoutForContext(fallbackContext), false,
    '当前协议没有该语义动作');
}

export function remoteShortcutKeyCodes(action: RemoteShortcutAction): Array<number> {
  if (action.keyCodes.length > 0) { return action.keyCodes.slice(0); }
  if (action.chord === null) { return []; }
  const modifier: number = action.chord.modifier === 'command' ?
    REMOTE_SHORTCUT_COMMAND_KEYCODE : REMOTE_SHORTCUT_CTRL_KEYCODE;
  let key: number = REMOTE_SHORTCUT_C_KEYCODE;
  if (action.chord.key === 'X') { key = REMOTE_SHORTCUT_X_KEYCODE; }
  if (action.chord.key === 'V') { key = REMOTE_SHORTCUT_V_KEYCODE; }
  return [modifier, key];
}
