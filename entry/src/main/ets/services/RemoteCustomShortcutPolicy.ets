export type RemoteCustomShortcutKeyGroup =
  'letters' | 'digits' | 'symbols' | 'functions' | 'navigation';

export interface RemoteCustomShortcut {
  id: string;
  label: string;
  keyCodes: Array<number>;
}

export interface RemoteCustomShortcutKeyOption {
  label: string;
  keyCode: number;
}

export interface RemoteCustomShortcutUpdate {
  accepted: boolean;
  reason: string;
  shortcuts: Array<RemoteCustomShortcut>;
}

interface RemoteCustomShortcutEnvelope {
  version: number;
  items: Array<RemoteCustomShortcut>;
}

export const REMOTE_CUSTOM_SHORTCUT_MAX_COUNT: number = 32;
export const REMOTE_CUSTOM_SHORTCUT_STORAGE_KEY: string = 'remoteCustomShortcuts:v1';

const CTRL: number = 2072;
const ALT: number = 2045;
const SHIFT: number = 2047;
const WIN: number = 2076;
const MODIFIERS: Array<number> = [CTRL, ALT, SHIFT, WIN];

function modifierLabel(keyCode: number): string {
  if (keyCode === CTRL) { return 'Ctrl'; }
  if (keyCode === ALT) { return 'Alt'; }
  if (keyCode === SHIFT) { return 'Shift'; }
  if (keyCode === WIN) { return 'Win'; }
  return '';
}

function platformModifierLabel(keyCode: number, platform: string): string {
  const macOS: boolean = platform.trim().toLowerCase() === 'macos';
  if (keyCode === ALT && macOS) { return 'Option'; }
  if (keyCode === WIN && macOS) { return 'Cmd'; }
  return modifierLabel(keyCode);
}

function pushOption(target: Array<RemoteCustomShortcutKeyOption>, label: string,
  keyCode: number): void {
  target.push({ label: label, keyCode: keyCode });
}

export function remoteCustomShortcutKeyOptions(
  group: RemoteCustomShortcutKeyGroup
): Array<RemoteCustomShortcutKeyOption> {
  const result: Array<RemoteCustomShortcutKeyOption> = [];
  if (group === 'letters') {
    for (let index = 0; index < 26; index++) {
      pushOption(result, String.fromCharCode(65 + index), 2017 + index);
    }
    return result;
  }
  if (group === 'digits') {
    for (let index = 0; index < 10; index++) {
      pushOption(result, index.toString(), 2000 + index);
    }
    return result;
  }
  if (group === 'symbols') {
    pushOption(result, ',', 2043);
    pushOption(result, '.', 2044);
    pushOption(result, '`', 2056);
    pushOption(result, '-', 2057);
    pushOption(result, '=', 2058);
    pushOption(result, '[', 2059);
    pushOption(result, ']', 2060);
    pushOption(result, '\\', 2061);
    pushOption(result, ';', 2062);
    pushOption(result, '\'', 2063);
    pushOption(result, '/', 2064);
    return result;
  }
  if (group === 'functions') {
    for (let index = 0; index < 12; index++) {
      pushOption(result, 'F' + (index + 1).toString(), 2090 + index);
    }
    return result;
  }
  pushOption(result, 'Esc', 2070);
  pushOption(result, 'Tab', 2049);
  pushOption(result, 'Enter', 2054);
  pushOption(result, 'Space', 2050);
  pushOption(result, 'Del', 2071);
  pushOption(result, 'Backspace', 2055);
  pushOption(result, '↑', 2012);
  pushOption(result, '↓', 2013);
  pushOption(result, '←', 2014);
  pushOption(result, '→', 2015);
  pushOption(result, 'Home', 2081);
  pushOption(result, 'End', 2082);
  pushOption(result, 'PgUp', 2068);
  pushOption(result, 'PgDn', 2069);
  pushOption(result, 'Insert', 2083);
  return result;
}

export function remoteCustomShortcutKeyGroupForKeyCode(
  keyCode: number
): RemoteCustomShortcutKeyGroup {
  const groups: Array<RemoteCustomShortcutKeyGroup> =
    ['letters', 'digits', 'symbols', 'functions', 'navigation'];
  for (let groupIndex: number = 0; groupIndex < groups.length; groupIndex++) {
    const options: Array<RemoteCustomShortcutKeyOption> =
      remoteCustomShortcutKeyOptions(groups[groupIndex]);
    for (let optionIndex: number = 0; optionIndex < options.length; optionIndex++) {
      if (options[optionIndex].keyCode === keyCode) { return groups[groupIndex]; }
    }
  }
  return 'navigation';
}

function actionLabel(keyCode: number): string {
  const groups: Array<RemoteCustomShortcutKeyGroup> =
    ['letters', 'digits', 'symbols', 'functions', 'navigation'];
  for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    const options: Array<RemoteCustomShortcutKeyOption> =
      remoteCustomShortcutKeyOptions(groups[groupIndex]);
    for (let optionIndex = 0; optionIndex < options.length; optionIndex++) {
      if (options[optionIndex].keyCode === keyCode) {
        return options[optionIndex].label;
      }
    }
  }
  return '';
}

function normalizedKeyCodes(keyCodes: Array<number>): Array<number> {
  if (keyCodes.length < 2 || keyCodes.length > 5) { return []; }
  const result: Array<number> = [];
  for (let modifierIndex = 0; modifierIndex < MODIFIERS.length; modifierIndex++) {
    if (keyCodes.indexOf(MODIFIERS[modifierIndex]) >= 0) {
      result.push(MODIFIERS[modifierIndex]);
    }
  }
  const action: number = keyCodes[keyCodes.length - 1];
  if (result.length === 0 || actionLabel(action).length === 0 ||
    MODIFIERS.indexOf(action) >= 0) {
    return [];
  }
  for (let index = 0; index < keyCodes.length - 1; index++) {
    if (MODIFIERS.indexOf(keyCodes[index]) < 0) { return []; }
  }
  result.push(action);
  return result;
}

export function remoteCustomShortcutLabel(keyCodes: Array<number>): string {
  const normalized: Array<number> = normalizedKeyCodes(keyCodes);
  if (normalized.length === 0) { return ''; }
  const labels: Array<string> = [];
  for (let index = 0; index < normalized.length - 1; index++) {
    labels.push(modifierLabel(normalized[index]));
  }
  labels.push(actionLabel(normalized[normalized.length - 1]));
  return labels.join(' + ');
}

export function remoteCustomShortcutLabelForPlatform(keyCodes: Array<number>,
  platform: string): string {
  const normalized: Array<number> = normalizedKeyCodes(keyCodes);
  if (normalized.length === 0) { return ''; }
  const labels: Array<string> = [];
  for (let index = 0; index < normalized.length - 1; index++) {
    labels.push(platformModifierLabel(normalized[index], platform));
  }
  labels.push(actionLabel(normalized[normalized.length - 1]));
  return labels.join(' + ');
}

export function createRemoteCustomShortcut(id: string,
  keyCodes: Array<number>): RemoteCustomShortcut | null {
  const normalizedId: string = id.trim();
  const normalized: Array<number> = normalizedKeyCodes(keyCodes);
  const label: string = remoteCustomShortcutLabel(normalized);
  if (normalizedId.length === 0 || normalizedId.length > 80 ||
    !/^[A-Za-z0-9._:-]+$/.test(normalizedId) || label.length === 0) {
    return null;
  }
  return { id: normalizedId, label: label, keyCodes: normalized };
}

function sameKeyCodes(left: Array<number>, right: Array<number>): boolean {
  if (left.length !== right.length) { return false; }
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) { return false; }
  }
  return true;
}

export function upsertRemoteCustomShortcut(current: Array<RemoteCustomShortcut>, id: string,
  keyCodes: Array<number>): RemoteCustomShortcutUpdate {
  const candidate: RemoteCustomShortcut | null = createRemoteCustomShortcut(id, keyCodes);
  if (candidate === null) {
    return { accepted: false, reason: '请选择至少一个修饰键和一个主键', shortcuts: current.slice(0) };
  }
  let existingIndex: number = -1;
  for (let index = 0; index < current.length; index++) {
    if (current[index].id === candidate.id) { existingIndex = index; }
    if (current[index].id !== candidate.id &&
      sameKeyCodes(current[index].keyCodes, candidate.keyCodes)) {
      return { accepted: false, reason: '该组合键已经存在', shortcuts: current.slice(0) };
    }
  }
  if (existingIndex < 0 && current.length >= REMOTE_CUSTOM_SHORTCUT_MAX_COUNT) {
    return { accepted: false, reason: '最多保存 32 个自定义组合键', shortcuts: current.slice(0) };
  }
  const next: Array<RemoteCustomShortcut> = current.slice(0);
  if (existingIndex >= 0) {
    next[existingIndex] = candidate;
  } else {
    next.push(candidate);
  }
  return { accepted: true, reason: '', shortcuts: next };
}

export function removeRemoteCustomShortcut(current: Array<RemoteCustomShortcut>,
  id: string): Array<RemoteCustomShortcut> {
  return current.filter((shortcut: RemoteCustomShortcut): boolean => shortcut.id !== id);
}

export function encodeRemoteCustomShortcuts(shortcuts: Array<RemoteCustomShortcut>): string {
  const validated: Array<RemoteCustomShortcut> = [];
  for (let index = 0; index < shortcuts.length &&
    validated.length < REMOTE_CUSTOM_SHORTCUT_MAX_COUNT; index++) {
    const item: RemoteCustomShortcut | null = createRemoteCustomShortcut(
      shortcuts[index].id, shortcuts[index].keyCodes);
    if (item !== null) { validated.push(item); }
  }
  const envelope: RemoteCustomShortcutEnvelope = { version: 1, items: validated };
  return JSON.stringify(envelope);
}

export function decodeRemoteCustomShortcuts(raw: string): Array<RemoteCustomShortcut> {
  if (raw.trim().length === 0 || raw.length > 16 * 1024) { return []; }
  try {
    const envelope: RemoteCustomShortcutEnvelope =
      JSON.parse(raw) as RemoteCustomShortcutEnvelope;
    if (envelope.version !== 1 || !Array.isArray(envelope.items)) { return []; }
    let result: Array<RemoteCustomShortcut> = [];
    for (let index = 0; index < envelope.items.length &&
      result.length < REMOTE_CUSTOM_SHORTCUT_MAX_COUNT; index++) {
      const source: RemoteCustomShortcut = envelope.items[index];
      if (source === null || source === undefined || typeof source.id !== 'string' ||
        !Array.isArray(source.keyCodes)) { continue; }
      let keyCodesValid: boolean = true;
      for (let keyIndex = 0; keyIndex < source.keyCodes.length; keyIndex++) {
        if (typeof source.keyCodes[keyIndex] !== 'number' ||
          !Number.isFinite(source.keyCodes[keyIndex])) {
          keyCodesValid = false;
          break;
        }
      }
      if (!keyCodesValid) { continue; }
      const update: RemoteCustomShortcutUpdate =
        upsertRemoteCustomShortcut(result, source.id, source.keyCodes);
      if (update.accepted) { result = update.shortcuts; }
    }
    return result;
  } catch (_error) {
    return [];
  }
}
