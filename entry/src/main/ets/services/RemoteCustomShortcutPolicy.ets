export type RemoteCustomShortcutKeyGroup =
  'letters' | 'digits' | 'symbols' | 'functions' | 'directions' | 'navigation' | 'system' | 'numpad';

/**
 * One saved custom action. `keyCodes` is the first step (kept for v1 callers); `steps` holds the
 * whole sequence (1-4 combinations sent in order) and `name` an optional user label.
 */
export interface RemoteCustomShortcut {
  id: string;
  label: string;
  keyCodes: Array<number>;
  name?: string;
  steps?: Array<Array<number>>;
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

export interface RemoteCustomShortcutEditorLayout {
  columns: number;
  cardPadding: number;
  itemGap: number;
  itemHeight: number;
}

interface RemoteCustomShortcutEnvelope {
  version: number;
  items: Array<RemoteCustomShortcut>;
}

export const REMOTE_CUSTOM_SHORTCUT_MAX_COUNT: number = 32;
export const REMOTE_CUSTOM_SHORTCUT_MAX_STEPS: number = 4;
export const REMOTE_CUSTOM_SHORTCUT_NAME_MAX: number = 16;
/** Pause between the steps of a sequence so the remote sees separate chords. */
export const REMOTE_CUSTOM_SHORTCUT_STEP_GAP_MS: number = 80;
export const REMOTE_CUSTOM_SHORTCUT_GROUPS: Array<RemoteCustomShortcutKeyGroup> =
  ['letters', 'digits', 'symbols', 'functions', 'directions', 'navigation', 'system', 'numpad'];
/** Groups whose keys may be sent alone; typing keys (letters, digits, symbols) need a modifier. */
const STANDALONE_GROUPS: Array<RemoteCustomShortcutKeyGroup> =
  ['functions', 'directions', 'navigation', 'system', 'numpad'];
export const REMOTE_CUSTOM_SHORTCUT_STORAGE_KEY: string = 'remoteCustomShortcuts:v1';

const CTRL: number = 2072;
const ALT: number = 2045;
const SHIFT: number = 2047;
const WIN: number = 2076;
const MODIFIERS: Array<number> = [CTRL, ALT, SHIFT, WIN];

/**
 * Resolve from the live sheet viewport so phones in landscape, split-screen
 * Pads, and resizable PC windows do not inherit a device-name-sized editor.
 */
export function remoteCustomShortcutEditorLayout(viewportWidth: number,
  viewportHeight: number): RemoteCustomShortcutEditorLayout {
  const width: number = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 360;
  const height: number = Number.isFinite(viewportHeight) && viewportHeight > 0 ? viewportHeight : 640;
  let columns: number = 6;
  if (width < 330) {
    columns = 3;
  } else if (width < 460) {
    columns = 4;
  } else if (width < 680) {
    columns = 5;
  }
  const compactHeight: boolean = height < 460;
  return {
    columns: columns,
    cardPadding: width < 460 || compactHeight ? 10 : 14,
    itemGap: width < 330 || compactHeight ? 3 : 4,
    itemHeight: compactHeight ? 28 : 30
  };
}

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
  group: RemoteCustomShortcutKeyGroup,
  platform: string = 'windows'
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
    const extendedCount: number = platform.trim().toLowerCase() === 'macos' ? 8 : 12;
    for (let index = 0; index < extendedCount; index++) {
      pushOption(result, 'F' + (index + 13).toString(), 2816 + index);
    }
    return result;
  }
  if (group === 'directions') {
    pushOption(result, '↑', 2012);
    pushOption(result, '↓', 2013);
    pushOption(result, '←', 2014);
    pushOption(result, '→', 2015);
    return result;
  }
  if (group === 'system') {
    pushOption(result, 'PrtSc', 2079);
    pushOption(result, 'Menu', 2067);
    pushOption(result, 'CapsLock', 2074);
    pushOption(result, 'NumLock', 2102);
    pushOption(result, 'ScrLk', 2075);
    return result;
  }
  if (group === 'numpad') {
    for (let index = 0; index < 10; index++) {
      pushOption(result, 'Num' + index.toString(), 2103 + index);
    }
    pushOption(result, 'Num÷', 2113);
    pushOption(result, 'Num×', 2114);
    pushOption(result, 'Num−', 2115);
    pushOption(result, 'Num+', 2116);
    pushOption(result, 'Num.', 2117);
    pushOption(result, 'NumEnter', 2119);
    return result;
  }
  pushOption(result, 'Esc', 2070);
  pushOption(result, 'Tab', 2049);
  pushOption(result, 'Enter', 2054);
  pushOption(result, 'Space', 2050);
  pushOption(result, 'Del', 2071);
  pushOption(result, 'Backspace', 2055);
  pushOption(result, 'Home', 2081);
  pushOption(result, 'End', 2082);
  pushOption(result, 'PgUp', 2068);
  pushOption(result, 'PgDn', 2069);
  pushOption(result, 'Insert', 2083);
  return result;
}

/** macOS exposes stable Carbon virtual-key codes only through F20. */
export function remoteCustomShortcutKeyAvailableOnPlatform(
  keyCode: number,
  platform: string
): boolean {
  return !(platform.trim().toLowerCase() === 'macos' && keyCode >= 2824 && keyCode <= 2827);
}

export function remoteCustomShortcutAvailableOnPlatform(
  shortcut: RemoteCustomShortcut,
  platform: string
): boolean {
  const steps: Array<Array<number>> = remoteCustomShortcutSteps(shortcut);
  for (let step: number = 0; step < steps.length; step++) {
    for (let index: number = 0; index < steps[step].length; index++) {
      if (!remoteCustomShortcutKeyAvailableOnPlatform(steps[step][index], platform)) {
        return false;
      }
    }
  }
  return true;
}

/** The full sequence of a shortcut; v1 entries are a single step. */
export function remoteCustomShortcutSteps(shortcut: RemoteCustomShortcut): Array<Array<number>> {
  const steps: Array<Array<number>> | undefined = shortcut.steps;
  if (steps !== undefined && steps.length > 0) {
    return steps.map((step: Array<number>): Array<number> => step.slice(0));
  }
  return [shortcut.keyCodes.slice(0)];
}

export function remoteCustomShortcutKeyGroupForKeyCode(
  keyCode: number
): RemoteCustomShortcutKeyGroup {
  const groups: Array<RemoteCustomShortcutKeyGroup> = REMOTE_CUSTOM_SHORTCUT_GROUPS;
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
  const groups: Array<RemoteCustomShortcutKeyGroup> = REMOTE_CUSTOM_SHORTCUT_GROUPS;
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
  if (keyCodes.length < 1 || keyCodes.length > 5) { return []; }
  const result: Array<number> = [];
  for (let modifierIndex = 0; modifierIndex < MODIFIERS.length; modifierIndex++) {
    if (keyCodes.indexOf(MODIFIERS[modifierIndex]) >= 0) {
      result.push(MODIFIERS[modifierIndex]);
    }
  }
  const action: number = keyCodes[keyCodes.length - 1];
  if (actionLabel(action).length === 0 || MODIFIERS.indexOf(action) >= 0 ||
    (result.length === 0 && STANDALONE_GROUPS.indexOf(remoteCustomShortcutKeyGroupForKeyCode(action)) < 0)) {
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

function normalizedName(name: string): string {
  return name.trim().replace(/[\r\n\t]+/g, ' ').slice(0, REMOTE_CUSTOM_SHORTCUT_NAME_MAX);
}

function normalizedSteps(steps: Array<Array<number>>): Array<Array<number>> {
  if (!Array.isArray(steps) || steps.length < 1 || steps.length > REMOTE_CUSTOM_SHORTCUT_MAX_STEPS) { return []; }
  const result: Array<Array<number>> = [];
  for (let index = 0; index < steps.length; index++) {
    if (!Array.isArray(steps[index])) { return []; }
    const step: Array<number> = normalizedKeyCodes(steps[index]);
    if (step.length === 0) { return []; }
    result.push(step);
  }
  return result;
}

/** Label of a whole sequence, e.g. "Ctrl + K → Ctrl + S". */
export function remoteCustomShortcutStepsLabel(steps: Array<Array<number>>, platform: string = 'windows'): string {
  const normalized: Array<Array<number>> = normalizedSteps(steps);
  return normalized.map((step: Array<number>): string =>
    remoteCustomShortcutLabelForPlatform(step, platform)).join(' → ');
}

/** What the session panel shows: the user's name, else the key label. */
export function remoteCustomShortcutDisplayName(shortcut: RemoteCustomShortcut, platform: string = 'windows'): string {
  const name: string = normalizedName(shortcut.name ?? '');
  return name.length > 0 ? name : remoteCustomShortcutStepsLabel(remoteCustomShortcutSteps(shortcut), platform);
}

export function createRemoteCustomShortcutSteps(id: string, name: string,
  steps: Array<Array<number>>): RemoteCustomShortcut | null {
  const normalizedId: string = id.trim();
  const normalized: Array<Array<number>> = normalizedSteps(steps);
  if (normalizedId.length === 0 || normalizedId.length > 80 ||
    !/^[A-Za-z0-9._:-]+$/.test(normalizedId) || normalized.length === 0) {
    return null;
  }
  const label: string = normalized.map((step: Array<number>): string => remoteCustomShortcutLabel(step)).join(' → ');
  return { id: normalizedId, label: label, keyCodes: normalized[0].slice(0), name: normalizedName(name),
    steps: normalized };
}

export function createRemoteCustomShortcut(id: string,
  keyCodes: Array<number>): RemoteCustomShortcut | null {
  return createRemoteCustomShortcutSteps(id, '', [keyCodes]);
}

function sameSteps(left: Array<Array<number>>, right: Array<Array<number>>): boolean {
  if (left.length !== right.length) { return false; }
  for (let step = 0; step < left.length; step++) {
    if (left[step].length !== right[step].length) { return false; }
    for (let index = 0; index < left[step].length; index++) {
      if (left[step][index] !== right[step][index]) { return false; }
    }
  }
  return true;
}

export function upsertRemoteCustomShortcutSteps(current: Array<RemoteCustomShortcut>, id: string,
  name: string, steps: Array<Array<number>>): RemoteCustomShortcutUpdate {
  const candidate: RemoteCustomShortcut | null = createRemoteCustomShortcutSteps(id, name, steps);
  if (candidate === null) {
    return { accepted: false, reason: '每一步都需要一个主键；字母、数字和符号还需要至少一个修饰键',
      shortcuts: current.slice(0) };
  }
  let existingIndex: number = -1;
  for (let index = 0; index < current.length; index++) {
    if (current[index].id === candidate.id) { existingIndex = index; }
    if (current[index].id !== candidate.id &&
      sameSteps(remoteCustomShortcutSteps(current[index]), remoteCustomShortcutSteps(candidate))) {
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

export function upsertRemoteCustomShortcut(current: Array<RemoteCustomShortcut>, id: string,
  keyCodes: Array<number>): RemoteCustomShortcutUpdate {
  const existing: RemoteCustomShortcut | undefined =
    current.find((shortcut: RemoteCustomShortcut): boolean => shortcut.id === id.trim());
  return upsertRemoteCustomShortcutSteps(current, id, existing?.name ?? '', [keyCodes]);
}

/** Move one entry up (delta < 0) or down (delta > 0); the panel shows this order. */
export function moveRemoteCustomShortcut(current: Array<RemoteCustomShortcut>, id: string,
  delta: number): Array<RemoteCustomShortcut> {
  const from: number = current.findIndex((shortcut: RemoteCustomShortcut): boolean => shortcut.id === id);
  const to: number = from + (delta < 0 ? -1 : 1);
  if (from < 0 || to < 0 || to >= current.length) { return current.slice(0); }
  const next: Array<RemoteCustomShortcut> = current.slice(0);
  const moved: RemoteCustomShortcut = next[from];
  next[from] = next[to];
  next[to] = moved;
  return next;
}

export function removeRemoteCustomShortcut(current: Array<RemoteCustomShortcut>,
  id: string): Array<RemoteCustomShortcut> {
  return current.filter((shortcut: RemoteCustomShortcut): boolean => shortcut.id !== id);
}

export function encodeRemoteCustomShortcuts(shortcuts: Array<RemoteCustomShortcut>): string {
  const validated: Array<RemoteCustomShortcut> = [];
  for (let index = 0; index < shortcuts.length &&
    validated.length < REMOTE_CUSTOM_SHORTCUT_MAX_COUNT; index++) {
    const item: RemoteCustomShortcut | null = createRemoteCustomShortcutSteps(
      shortcuts[index].id, shortcuts[index].name ?? '', remoteCustomShortcutSteps(shortcuts[index]));
    if (item !== null) { validated.push(item); }
  }
  const envelope: RemoteCustomShortcutEnvelope = { version: 2, items: validated };
  return JSON.stringify(envelope);
}

function decodedSteps(source: RemoteCustomShortcut, version: number): Array<Array<number>> | null {
  const raw: Object = (version === 2 && Array.isArray(source.steps)) ? source.steps as Object :
    [source.keyCodes] as Object;
  if (!Array.isArray(raw)) { return null; }
  const steps: Array<Array<number>> = [];
  const items: Array<Object> = raw as Array<Object>;
  for (let step = 0; step < items.length; step++) {
    if (!Array.isArray(items[step])) { return null; }
    const codes: Array<Object> = items[step] as Array<Object>;
    for (let index = 0; index < codes.length; index++) {
      if (typeof codes[index] !== 'number' || !Number.isFinite(codes[index] as number)) { return null; }
    }
    steps.push(codes as Array<number>);
  }
  return steps;
}

/** Reads v2 and migrates v1 (single-step, unnamed) entries. */
export function decodeRemoteCustomShortcuts(raw: string): Array<RemoteCustomShortcut> {
  if (raw.trim().length === 0 || raw.length > 16 * 1024) { return []; }
  try {
    const envelope: RemoteCustomShortcutEnvelope =
      JSON.parse(raw) as RemoteCustomShortcutEnvelope;
    if ((envelope.version !== 1 && envelope.version !== 2) || !Array.isArray(envelope.items)) { return []; }
    let result: Array<RemoteCustomShortcut> = [];
    for (let index = 0; index < envelope.items.length &&
      result.length < REMOTE_CUSTOM_SHORTCUT_MAX_COUNT; index++) {
      const source: RemoteCustomShortcut = envelope.items[index];
      if (source === null || source === undefined || typeof source.id !== 'string' ||
        (envelope.version === 1 && !Array.isArray(source.keyCodes))) { continue; }
      const steps: Array<Array<number>> | null = decodedSteps(source, envelope.version);
      if (steps === null) { continue; }
      const name: string = typeof source.name === 'string' ? source.name as string : '';
      const update: RemoteCustomShortcutUpdate =
        upsertRemoteCustomShortcutSteps(result, source.id, name, steps);
      if (update.accepted) { result = update.shortcuts; }
    }
    return result;
  } catch (_error) {
    return [];
  }
}
