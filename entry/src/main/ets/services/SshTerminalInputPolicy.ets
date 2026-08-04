/**
 * SSH 终端输入编码策略。
 *
 * 页面层只负责采集 ArkUI 事件；这里统一决定最终发送给远端 PTY 的字节序列。
 */
import { KeyCode } from '@kit.InputKit';

export interface TerminalModifierState {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
}

export interface SshPhysicalKeyInput extends TerminalModifierState {
  keyCode: number;
  unicode?: number;
  capsLock?: boolean;
  /** AltGraph is already a composed printable character, not ESC+Ctrl text. */
  altGraph?: boolean;
  /** Only true when the caller positively identified a hardware device. */
  allowKeyCodeFallback?: boolean;
  applicationCursorKeys?: boolean;
  applicationKeypad?: boolean;
}

export interface SshEncodedKey {
  sequence: string;
  consume: boolean;
  refocusAfterTab: boolean;
}

/**
 * ArkUI TextInput callback state. onWill* may be followed by local
 * composition changes, but only onDid* may produce remote terminal bytes.
 */
export interface SshImeCallbackState {
  pendingInsert: string | null;
  pendingDelete: string | null;
  /** Last committed value observed by the hidden TextInput. */
  shadowValue: string;
  /** True while onChange is reporting an IME pre-edit/candidate value. */
  previewActive: boolean;
  /** resetKeyboardBuffer() may itself trigger one empty onChange callback. */
  ignoreNextEmptyChange: boolean;
  /** A system-IME onDid callback may be followed by one duplicate onChange. */
  lastCommittedValue: string;
}

export interface SshImeChangeDecision {
  updateShadow: boolean;
  sendRemote: boolean;
  resetLocal: boolean;
  /** Committed text discovered through the non-system-IME fallback path. */
  remoteInsert: string;
  /** Text removed through the non-system-IME fallback path. */
  remoteDelete: string;
}

interface SshImeTextChange {
  inserted: string;
  deleted: string;
}

export function createSshImeCallbackState(): SshImeCallbackState {
  return {
    pendingInsert: null,
    pendingDelete: null,
    shadowValue: '',
    previewActive: false,
    ignoreNextEmptyChange: false,
    lastCommittedValue: ''
  };
}

/** Reset the hidden editor shadow after a committed terminal event. */
export function resetSshImeShadow(state: SshImeCallbackState, committedValue: string = ''): void {
  state.pendingInsert = null;
  state.pendingDelete = null;
  state.shadowValue = '';
  state.previewActive = false;
  state.ignoreNextEmptyChange = true;
  state.lastCommittedValue = committedValue;
}

export function recordSshImeWillInsert(
  state: SshImeCallbackState,
  insertValue: string
): boolean {
  state.ignoreNextEmptyChange = false;
  state.lastCommittedValue = '';
  state.pendingInsert = insertValue;
  state.pendingDelete = null;
  // Let the IME keep its pre-edit/candidate buffer local. Nothing is sent yet.
  return true;
}

export function consumeSshImeDidInsert(
  state: SshImeCallbackState,
  insertValue: string
): string {
  if (state.pendingInsert === null) { return ''; }
  state.pendingInsert = null;
  state.shadowValue = '';
  state.previewActive = false;
  state.ignoreNextEmptyChange = true;
  state.lastCommittedValue = insertValue;
  return insertValue;
}

export function recordSshImeWillDelete(
  state: SshImeCallbackState,
  deleteValue: string
): boolean {
  state.ignoreNextEmptyChange = false;
  state.lastCommittedValue = '';
  state.pendingDelete = deleteValue;
  state.pendingInsert = null;
  return true;
}

export function consumeSshImeDidDelete(
  state: SshImeCallbackState,
  deleteValue: string
): string | null {
  if (state.pendingDelete === null) { return null; }
  state.pendingDelete = null;
  state.shadowValue = '';
  state.previewActive = false;
  state.ignoreNextEmptyChange = true;
  state.lastCommittedValue = '';
  return deleteValue;
}

function textChange(oldValue: string, newValue: string): SshImeTextChange {
  let prefix: number = 0;
  const maxPrefix: number = Math.min(oldValue.length, newValue.length);
  while (prefix < maxPrefix && oldValue.charCodeAt(prefix) === newValue.charCodeAt(prefix)) {
    prefix++;
  }
  let suffix: number = 0;
  const maxSuffix: number = Math.min(oldValue.length - prefix, newValue.length - prefix);
  while (suffix < maxSuffix &&
    oldValue.charCodeAt(oldValue.length - 1 - suffix) ===
    newValue.charCodeAt(newValue.length - 1 - suffix)) {
    suffix++;
  }
  return {
    deleted: oldValue.substring(prefix, oldValue.length - suffix),
    inserted: newValue.substring(prefix, newValue.length - suffix)
  };
}

/**
 * Inspect TextInput changes without duplicating system-IME onDid callbacks.
 * HarmonyOS only guarantees onWill/onDid for system IMEs; for other IMEs a
 * committed value may arrive through onChange with no preview metadata. The
 * stable-shadow diff is the exactly-once fallback for that path.
 */
export function inspectSshImeChange(
  state: SshImeCallbackState,
  value: string,
  previewUnits: number
): SshImeChangeDecision {
  if (state.ignoreNextEmptyChange && value.length === 0) {
    state.ignoreNextEmptyChange = false;
    // resetKeyboardBuffer() can emit an empty onChange before the next real
    // character. Do not carry the old commit ledger across that reset: a
    // legitimate repeated character must not be mistaken for the prior IME
    // callback. A duplicate non-empty callback that arrived before this empty
    // reset is still suppressed by the branch below.
    state.lastCommittedValue = '';
    return { updateShadow: true, sendRemote: false, resetLocal: false,
      remoteInsert: '', remoteDelete: '' };
  }
  if (state.lastCommittedValue.length > 0 && value === state.lastCommittedValue) {
    state.shadowValue = value;
    state.lastCommittedValue = '';
    state.ignoreNextEmptyChange = true;
    return { updateShadow: true, sendRemote: false, resetLocal: false,
      remoteInsert: '', remoteDelete: '' };
  }
  if (previewUnits > 0) {
    state.previewActive = true;
    return { updateShadow: true, sendRemote: false, resetLocal: false,
      remoteInsert: '', remoteDelete: '' };
  }
  if (state.pendingInsert !== null || state.pendingDelete !== null) {
    return { updateShadow: true, sendRemote: false, resetLocal: false,
      remoteInsert: '', remoteDelete: '' };
  }

  const changed = textChange(state.shadowValue, value);
  state.shadowValue = value;
  state.previewActive = false;
  if (changed.inserted.length === 0 && changed.deleted.length === 0) {
    return { updateShadow: true, sendRemote: false, resetLocal: value.length > 0,
      remoteInsert: '', remoteDelete: '' };
  }
  return {
    updateShadow: true,
    sendRemote: true,
    resetLocal: value.length > 0,
    remoteInsert: changed.inserted,
    remoteDelete: changed.deleted
  };
}

const ESC: string = '\u001b';
const DEL: string = '\u007f';

function isModifierPrintable(code?: number): boolean {
  if (code === undefined) { return false; }
  return code >= 0x20 && code <= 0x7E;
}

function isPrintableUnicode(code?: number): boolean {
  if (code === undefined) { return false; }
  // KeyEvent.unicode is a Unicode scalar value. Keep whitespace such as a
  // physical space, but reject controls and surrogate halves. This lets a
  // hardware keyboard submit committed CJK/emoji directly while leaving
  // dead-key/preedit events (which normally have no scalar value) to the IME.
  return code >= 0x20 && code <= 0x10FFFF &&
    !(code >= 0xD800 && code <= 0xDFFF) && code !== 0x7F;
}

function codePointText(code: number): string {
  if (code <= 0xFFFF) { return String.fromCharCode(code); }
  const adjusted: number = code - 0x10000;
  return String.fromCharCode(
    0xD800 + Math.floor(adjusted / 0x400),
    0xDC00 + (adjusted % 0x400)
  );
}

function applyShift(text: string): string {
  if (text.length !== 1) { return text; }
  const code: number = text.charCodeAt(0);
  if (code >= 97 && code <= 122) { return text.toUpperCase(); }
  switch (text) {
    case '`': return '~';
    case '1': return '!';
    case '2': return '@';
    case '3': return '#';
    case '4': return '$';
    case '5': return '%';
    case '6': return '^';
    case '7': return '&';
    case '8': return '*';
    case '9': return '(';
    case '0': return ')';
    case '-': return '_';
    case '=': return '+';
    case '[': return '{';
    case ']': return '}';
    case '\\': return '|';
    case ';': return ':';
    case '\'': return '"';
    case ',': return '<';
    case '.': return '>';
    case '/': return '?';
    default: return text;
  }
}

function applyControl(text: string): string {
  if (text.length !== 1) { return text; }
  const code: number = text.charCodeAt(0);
  if (code >= 65 && code <= 90) { return String.fromCharCode(code - 64); }
  if (code >= 97 && code <= 122) { return String.fromCharCode(code - 96); }
  if (code === 91) { return ESC; }
  if (code === 92) { return '\u001c'; }
  if (code === 93) { return '\u001d'; }
  if (code === 94) { return '\u001e'; }
  if (code === 95 || code === 45) { return '\u001f'; }
  if (code === 32) { return '\u0000'; }
  return text;
}

function modifierParameter(modifiers: TerminalModifierState): number {
  let value: number = 1;
  if (modifiers.shift) { value += 1; }
  if (modifiers.alt) { value += 2; }
  if (modifiers.ctrl) { value += 4; }
  return value;
}

function csiFinal(finalChar: string, modifiers: TerminalModifierState): string {
  const mod: number = modifierParameter(modifiers);
  if (mod === 1) { return ESC + '[' + finalChar; }
  return ESC + '[1;' + mod.toString() + finalChar;
}

function csiTilde(code: number, modifiers: TerminalModifierState): string {
  const mod: number = modifierParameter(modifiers);
  if (mod === 1) { return ESC + '[' + code.toString() + '~'; }
  return ESC + '[' + code.toString() + ';' + mod.toString() + '~';
}

function csiFunctionFinal(finalChar: string, modifiers: TerminalModifierState): string {
  const mod: number = modifierParameter(modifiers);
  if (mod === 1) { return ESC + 'O' + finalChar; }
  return ESC + '[1;' + mod.toString() + finalChar;
}

function countTextCharacters(text: string): number {
  if (text.length === 0) { return 1; }
  let count: number = 0;
  let index: number = 0;
  while (index < text.length) {
    const code: number = text.charCodeAt(index);
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
      const next: number = text.charCodeAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        index += 2;
        count++;
        continue;
      }
    }
    index++;
    count++;
  }
  return Math.max(1, count);
}

function keyCodeToBasePrintable(keyCode: number): string {
  if (keyCode >= KeyCode.KEYCODE_A && keyCode <= KeyCode.KEYCODE_Z) {
    return String.fromCharCode(97 + keyCode - KeyCode.KEYCODE_A);
  }
  if (keyCode >= KeyCode.KEYCODE_0 && keyCode <= KeyCode.KEYCODE_9) {
    return String.fromCharCode(48 + keyCode - KeyCode.KEYCODE_0);
  }
  switch (keyCode) {
    case KeyCode.KEYCODE_SPACE: return ' ';
    case KeyCode.KEYCODE_GRAVE: return '`';
    case KeyCode.KEYCODE_MINUS: return '-';
    case KeyCode.KEYCODE_EQUALS: return '=';
    case KeyCode.KEYCODE_LEFT_BRACKET: return '[';
    case KeyCode.KEYCODE_RIGHT_BRACKET: return ']';
    case KeyCode.KEYCODE_BACKSLASH: return '\\';
    case KeyCode.KEYCODE_SEMICOLON: return ';';
    case KeyCode.KEYCODE_APOSTROPHE: return '\'';
    case KeyCode.KEYCODE_COMMA: return ',';
    case KeyCode.KEYCODE_PERIOD: return '.';
    case KeyCode.KEYCODE_SLASH: return '/';
    default: return '';
  }
}

function specialResult(sequence: string, refocusAfterTab: boolean = false): SshEncodedKey {
  return { sequence, consume: sequence.length > 0, refocusAfterTab };
}

export function encodeTextInput(text: string, modifiers: TerminalModifierState): string {
  if (text.length === 0) { return ''; }
  let toSend: string = text;
  const printable: boolean = text.length === 1 && isModifierPrintable(text.charCodeAt(0));
  if (!printable) { return toSend; }
  if (modifiers.shift) { toSend = applyShift(toSend); }
  if (modifiers.ctrl) { toSend = applyControl(toSend); }
  if (modifiers.alt) { toSend = ESC + toSend; }
  return toSend;
}

export function encodeSoftDelete(deleteValue: string): string {
  const count: number = countTextCharacters(deleteValue);
  let sequence: string = '';
  for (let i = 0; i < count; i++) {
    sequence += DEL;
  }
  return sequence;
}

export function encodeSpecialKey(
  keyCode: number,
  modifiers: TerminalModifierState,
  applicationCursorKeys: boolean = false,
  applicationKeypad: boolean = false
): string {
  const cursorFinal = (finalChar: string): string => {
    if (applicationCursorKeys && modifierParameter(modifiers) === 1) {
      return ESC + 'O' + finalChar;
    }
    return csiFinal(finalChar, modifiers);
  };
  if (keyCode === KeyCode.KEYCODE_DPAD_UP) { return cursorFinal('A'); }
  if (keyCode === KeyCode.KEYCODE_DPAD_DOWN) { return cursorFinal('B'); }
  if (keyCode === KeyCode.KEYCODE_DPAD_RIGHT) { return cursorFinal('C'); }
  if (keyCode === KeyCode.KEYCODE_DPAD_LEFT) { return cursorFinal('D'); }
  if (keyCode === KeyCode.KEYCODE_MOVE_HOME) { return cursorFinal('H'); }
  if (keyCode === KeyCode.KEYCODE_MOVE_END) { return cursorFinal('F'); }
  if (keyCode === KeyCode.KEYCODE_PAGE_UP) { return csiTilde(5, modifiers); }
  if (keyCode === KeyCode.KEYCODE_PAGE_DOWN) { return csiTilde(6, modifiers); }
  if (keyCode === KeyCode.KEYCODE_INSERT) { return csiTilde(2, modifiers); }
  if (keyCode === KeyCode.KEYCODE_FORWARD_DEL) { return csiTilde(3, modifiers); }
  if (keyCode === KeyCode.KEYCODE_TAB) { return modifiers.shift ? ESC + '[Z' : '\t'; }
  if (keyCode === KeyCode.KEYCODE_ENTER) { return '\r'; }
  if (keyCode === KeyCode.KEYCODE_NUMPAD_ENTER) {
    return applicationKeypad ? ESC + 'OM' : '\r';
  }
  if (keyCode === KeyCode.KEYCODE_ESCAPE) { return ESC; }
  if (keyCode === KeyCode.KEYCODE_F1) { return csiFunctionFinal('P', modifiers); }
  if (keyCode === KeyCode.KEYCODE_F2) { return csiFunctionFinal('Q', modifiers); }
  if (keyCode === KeyCode.KEYCODE_F3) { return csiFunctionFinal('R', modifiers); }
  if (keyCode === KeyCode.KEYCODE_F4) { return csiFunctionFinal('S', modifiers); }
  if (keyCode === KeyCode.KEYCODE_F5) { return csiTilde(15, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F6) { return csiTilde(17, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F7) { return csiTilde(18, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F8) { return csiTilde(19, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F9) { return csiTilde(20, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F10) { return csiTilde(21, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F11) { return csiTilde(23, modifiers); }
  if (keyCode === KeyCode.KEYCODE_F12) { return csiTilde(24, modifiers); }
  if (keyCode >= KeyCode.KEYCODE_NUMPAD_0 && keyCode <= KeyCode.KEYCODE_NUMPAD_9) {
    if (!applicationKeypad) {
      return String.fromCharCode(48 + keyCode - KeyCode.KEYCODE_NUMPAD_0);
    }
    return ESC + 'O' + String.fromCharCode('p'.charCodeAt(0) + keyCode - KeyCode.KEYCODE_NUMPAD_0);
  }
  switch (keyCode) {
    case KeyCode.KEYCODE_NUMPAD_DIVIDE: return applicationKeypad ? ESC + 'Oo' : '/';
    case KeyCode.KEYCODE_NUMPAD_MULTIPLY: return applicationKeypad ? ESC + 'Oj' : '*';
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT: return applicationKeypad ? ESC + 'Om' : '-';
    case KeyCode.KEYCODE_NUMPAD_ADD: return applicationKeypad ? ESC + 'Ok' : '+';
    case KeyCode.KEYCODE_NUMPAD_DOT: return applicationKeypad ? ESC + 'On' : '.';
    case KeyCode.KEYCODE_NUMPAD_COMMA: return applicationKeypad ? ESC + 'Ol' : ',';
    case KeyCode.KEYCODE_NUMPAD_EQUALS: return applicationKeypad ? ESC + 'OX' : '=';
    case KeyCode.KEYCODE_NUMPAD_LEFT_PAREN: return applicationKeypad ? ESC + 'Oq' : '(';
    case KeyCode.KEYCODE_NUMPAD_RIGHT_PAREN: return applicationKeypad ? ESC + 'Or' : ')';
    default: return '';
  }
}

export function encodePhysicalKey(input: SshPhysicalKeyInput): SshEncodedKey {
  const modifiers: TerminalModifierState = { ctrl: input.ctrl, alt: input.alt, shift: input.shift };
  if (input.keyCode === KeyCode.KEYCODE_DEL) {
    return specialResult(DEL);
  }
  if (input.keyCode === KeyCode.KEYCODE_SPACE) {
    return specialResult(encodeTextInput(' ', modifiers));
  }
  const special: string = encodeSpecialKey(
    input.keyCode,
    modifiers,
    input.applicationCursorKeys === true,
    input.applicationKeypad === true
  );
  if (special.length > 0) {
    return specialResult(special, input.keyCode === KeyCode.KEYCODE_TAB);
  }
  const unicode: number | undefined = input.unicode;
  if (isPrintableUnicode(unicode) && unicode !== undefined) {
    const text: string = codePointText(unicode);
    // AltGr is reported as Ctrl+Alt by some keyboards, while `unicode` is
    // already the composed character the user intended (for example `@` or
    // `€`). Sending ESC+Ctrl would produce a different terminal byte stream.
    if (input.altGraph === true) {
      return specialResult(text);
    }
    return specialResult(encodeTextInput(text, modifiers));
  }
  const fallback: string = keyCodeToBasePrintable(input.keyCode);
  if (fallback.length > 0 && input.allowKeyCodeFallback === true) {
    let text: string = fallback;
    const isAsciiLetter: boolean = text.length === 1 &&
      ((text >= 'a' && text <= 'z') || (text >= 'A' && text <= 'Z'));
    if (isAsciiLetter) {
      const upper: boolean = input.shift !== (input.capsLock === true);
      text = upper ? text.toUpperCase() : text.toLowerCase();
    } else if (input.shift) {
      text = applyShift(text);
    }
    if (input.altGraph === true) {
      return specialResult(text);
    }
    // Fallback key-code mapping is also consumed without modifiers. This is
    // important on hardware keyboards/platforms that omit unicode in KeyEvent;
    // otherwise the same key falls through to IME and can be duplicated by
    // onChange.
    const fallbackModifiers: TerminalModifierState = {
      ctrl: input.ctrl,
      alt: input.alt,
      shift: false
    };
    return specialResult(encodeTextInput(text, fallbackModifiers));
  }
  return { sequence: '', consume: false, refocusAfterTab: false };
}
