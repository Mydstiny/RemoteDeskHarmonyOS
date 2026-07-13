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
}

export interface SshEncodedKey {
  sequence: string;
  consume: boolean;
  refocusAfterTab: boolean;
}

const ESC: string = '\u001b';
const DEL: string = '\u007f';

function isModifierPrintable(code?: number): boolean {
  if (code === undefined) { return false; }
  return code >= 0x20 && code <= 0x7E;
}

function isPrintableUnicode(code?: number): boolean {
  if (code === undefined) { return false; }
  return code >= 0x21 && code <= 0x7E;
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

export function encodeSpecialKey(keyCode: number, modifiers: TerminalModifierState): string {
  if (keyCode === KeyCode.KEYCODE_DPAD_UP) { return csiFinal('A', modifiers); }
  if (keyCode === KeyCode.KEYCODE_DPAD_DOWN) { return csiFinal('B', modifiers); }
  if (keyCode === KeyCode.KEYCODE_DPAD_RIGHT) { return csiFinal('C', modifiers); }
  if (keyCode === KeyCode.KEYCODE_DPAD_LEFT) { return csiFinal('D', modifiers); }
  if (keyCode === KeyCode.KEYCODE_MOVE_HOME) { return csiFinal('H', modifiers); }
  if (keyCode === KeyCode.KEYCODE_MOVE_END) { return csiFinal('F', modifiers); }
  if (keyCode === KeyCode.KEYCODE_PAGE_UP) { return csiTilde(5, modifiers); }
  if (keyCode === KeyCode.KEYCODE_PAGE_DOWN) { return csiTilde(6, modifiers); }
  if (keyCode === KeyCode.KEYCODE_INSERT) { return csiTilde(2, modifiers); }
  if (keyCode === KeyCode.KEYCODE_FORWARD_DEL) { return csiTilde(3, modifiers); }
  if (keyCode === KeyCode.KEYCODE_TAB) { return modifiers.shift ? ESC + '[Z' : '\t'; }
  if (keyCode === KeyCode.KEYCODE_ENTER || keyCode === KeyCode.KEYCODE_NUMPAD_ENTER) { return '\r'; }
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
    return String.fromCharCode(48 + keyCode - KeyCode.KEYCODE_NUMPAD_0);
  }
  switch (keyCode) {
    case KeyCode.KEYCODE_NUMPAD_DIVIDE: return '/';
    case KeyCode.KEYCODE_NUMPAD_MULTIPLY: return '*';
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT: return '-';
    case KeyCode.KEYCODE_NUMPAD_ADD: return '+';
    case KeyCode.KEYCODE_NUMPAD_DOT: return '.';
    case KeyCode.KEYCODE_NUMPAD_COMMA: return ',';
    case KeyCode.KEYCODE_NUMPAD_EQUALS: return '=';
    case KeyCode.KEYCODE_NUMPAD_LEFT_PAREN: return '(';
    case KeyCode.KEYCODE_NUMPAD_RIGHT_PAREN: return ')';
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
  const special: string = encodeSpecialKey(input.keyCode, modifiers);
  if (special.length > 0) {
    return specialResult(special, input.keyCode === KeyCode.KEYCODE_TAB);
  }
  const unicode: number | undefined = input.unicode;
  if (isPrintableUnicode(unicode) && unicode !== undefined) {
    return specialResult(encodeTextInput(String.fromCharCode(unicode), modifiers));
  }
  const fallback: string = keyCodeToBasePrintable(input.keyCode);
  if (fallback.length > 0 && (input.ctrl || input.alt || input.shift)) {
    return specialResult(encodeTextInput(fallback, modifiers));
  }
  return { sequence: '', consume: false, refocusAfterTab: false };
}
