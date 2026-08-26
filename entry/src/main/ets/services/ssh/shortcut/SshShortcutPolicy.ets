export type SshShortcutKey =
  | 'F'
  | 'F6'
  | 'J'
  | 'T'
  | 'W'
  | 'DIGIT'
  | 'ENTER'
  | 'ESCAPE'
  | 'TAB'
  | 'OTHER';

export type SshShortcutAction =
  | 'none'
  | 'open_terminal_search'
  | 'focus_terminal_search'
  | 'search_next'
  | 'search_previous'
  | 'close_terminal_search'
  | 'open_command_palette'
  | 'open_new_session_picker'
  | 'close_active_tab'
  | 'activate_tab_index'
  | 'focus_next_region'
  | 'focus_previous_region'
  | 'escape_terminal_focus'
  | 'send_to_terminal'
  | 'let_text_editor_handle'
  | 'let_modal_handle';

export interface SshShortcutChord {
  key: SshShortcutKey;
  ctrl: boolean;
  meta: boolean;
  alt: boolean;
  shift: boolean;
  digit?: number;
}

export interface SshShortcutContext {
  modalOpen: boolean;
  searchOpen: boolean;
  textEditorFocused: boolean;
  terminalFocused: boolean;
  terminalSearchEnabled: boolean;
  workspaceShortcutsEnabled?: boolean;
  focusCycleEnabled?: boolean;
  captureGlobalShortcuts?: boolean;
  tabCount?: number;
}

export interface SshShortcutDecision {
  action: SshShortcutAction;
  consume: boolean;
  reason: string;
  tabIndex: number;
}

export interface SshShortcutBinding {
  actionId: string;
  scope: string;
  chord: SshShortcutChord;
}

export interface SshShortcutConflict {
  conflict: boolean;
  actionId: string;
  message: string;
}

function decision(action: SshShortcutAction, consume: boolean,
  reason: string, tabIndex: number = -1): SshShortcutDecision {
  return { action, consume, reason, tabIndex };
}

function primaryModifier(chord: SshShortcutChord): boolean {
  return (chord.ctrl || chord.meta) && !chord.alt;
}

function reservedTerminalEditingChord(chord: SshShortcutChord): boolean {
  if (!primaryModifier(chord) || chord.shift || chord.key === 'F') { return false; }
  return chord.key === 'OTHER';
}

/**
 * Route order is modal > search > text editor > terminal > workspace.
 * OTHER with a primary modifier deliberately remains terminal-owned so
 * Ctrl/Cmd+C/V/A/X/Z/Y and unknown shell shortcuts are never stolen.
 */
export function routeSshShortcut(chord: SshShortcutChord,
  context: SshShortcutContext): SshShortcutDecision {
  if (context.modalOpen) {
    return decision('let_modal_handle', false, '模态层拥有最高快捷键优先级');
  }
  if (context.searchOpen) {
    if (chord.key === 'ESCAPE' && !chord.ctrl && !chord.meta && !chord.alt) {
      return decision('close_terminal_search', true, '关闭当前终端搜索');
    }
    if (chord.key === 'ENTER' && !chord.ctrl && !chord.meta && !chord.alt) {
      return decision(chord.shift ? 'search_previous' : 'search_next', true,
        chord.shift ? '搜索上一项' : '搜索下一项');
    }
    if (chord.key === 'F' && primaryModifier(chord) && !chord.shift) {
      return decision('focus_terminal_search', true, '搜索已打开，聚焦搜索输入');
    }
    return decision('let_text_editor_handle', false, '搜索输入框处理文本和 IME');
  }
  if (context.textEditorFocused) {
    return decision('let_text_editor_handle', false, '文本编辑控件优先');
  }
  const workspaceShortcutsEnabled: boolean = context.workspaceShortcutsEnabled === true;
  if (context.focusCycleEnabled === true && chord.key === 'F6' &&
    !chord.ctrl && !chord.meta && !chord.alt) {
    return decision(chord.shift ? 'focus_previous_region' : 'focus_next_region', true,
      chord.shift ? '反向循环 SSH 工作区焦点区域' : '循环 SSH 工作区焦点区域');
  }
  const workspaceOwnsChord: boolean = workspaceShortcutsEnabled &&
    (!context.terminalFocused || context.captureGlobalShortcuts === true);
  if (workspaceOwnsChord) {
    if (chord.key === 'J' && primaryModifier(chord) && !chord.shift) {
      return decision('open_command_palette', true, '打开 SSH 命令面板');
    }
    if (chord.key === 'T' && primaryModifier(chord) && !chord.shift) {
      return decision('open_new_session_picker', true, '新建 SSH 会话');
    }
    if (chord.key === 'W' && primaryModifier(chord) && !chord.shift) {
      return decision('close_active_tab', true, '请求关闭当前 SSH 标签');
    }
    const digit: number = chord.digit ?? -1;
    const tabCount: number = context.tabCount ?? 0;
    if (chord.key === 'DIGIT' && chord.alt && !chord.ctrl && !chord.meta && !chord.shift &&
      digit >= 1 && digit <= 9 && digit <= tabCount) {
      return decision('activate_tab_index', true, '切换到 SSH 标签 ' + digit.toString(), digit - 1);
    }
  }
  if (context.terminalFocused) {
    if (context.terminalSearchEnabled && chord.key === 'F' &&
      primaryModifier(chord) && !chord.shift) {
      return decision('open_terminal_search', true, '打开当前终端搜索');
    }
    if (chord.key === 'TAB' && chord.shift && !chord.ctrl && !chord.meta && !chord.alt) {
      return decision('escape_terminal_focus', false, '交还应用焦点链');
    }
    if (reservedTerminalEditingChord(chord) || chord.key !== 'OTHER') {
      return decision('send_to_terminal', false, '终端保留按键');
    }
    return decision('send_to_terminal', false, '未知组合默认发送终端');
  }
  return decision('none', false, '当前上下文没有匹配动作');
}

export function normalizeSshShortcutChord(chord: SshShortcutChord): string {
  const parts: Array<string> = [];
  if (chord.ctrl) { parts.push('ctrl'); }
  if (chord.meta) { parts.push('meta'); }
  if (chord.alt) { parts.push('alt'); }
  if (chord.shift) { parts.push('shift'); }
  if (chord.key === 'DIGIT' && chord.digit !== undefined && chord.digit >= 1 && chord.digit <= 9) {
    parts.push(chord.digit.toString());
  } else {
    parts.push(chord.key.toLowerCase());
  }
  return parts.join('+');
}

export function findSshShortcutConflict(bindings: Array<SshShortcutBinding>,
  candidate: SshShortcutBinding): SshShortcutConflict {
  const normalized: string = normalizeSshShortcutChord(candidate.chord);
  for (let index = 0; index < bindings.length; index++) {
    const existing: SshShortcutBinding = bindings[index];
    if (existing.scope === candidate.scope && existing.actionId !== candidate.actionId &&
      normalizeSshShortcutChord(existing.chord) === normalized) {
      return {
        conflict: true,
        actionId: existing.actionId,
        message: '快捷键已被 ' + existing.actionId + ' 使用'
      };
    }
  }
  return { conflict: false, actionId: '', message: '' };
}
