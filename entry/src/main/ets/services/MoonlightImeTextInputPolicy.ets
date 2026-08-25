/**
 * Maps committed on-screen-keyboard ASCII to ordinary Moonlight key strokes.
 *
 * Sunshine accepts UTF-8 text packets on every platform, but its macOS input
 * backend currently discards them. Printable US-layout characters have an
 * exact, portable keyboard representation, so use that lane and reserve UTF-8
 * packets for text which cannot be represented by one ordinary key stroke.
 */

export interface MoonlightImeKeyStroke {
  keyCode: number;
  shift: boolean;
}

const KEYCODE_0: number = 2000;
const KEYCODE_A: number = 2017;
const KEYCODE_COMMA: number = 2043;
const KEYCODE_PERIOD: number = 2044;
const KEYCODE_TAB: number = 2049;
const KEYCODE_SPACE: number = 2050;
const KEYCODE_ENTER: number = 2054;
const KEYCODE_GRAVE: number = 2056;
const KEYCODE_MINUS: number = 2057;
const KEYCODE_EQUALS: number = 2058;
const KEYCODE_LEFT_BRACKET: number = 2059;
const KEYCODE_RIGHT_BRACKET: number = 2060;
const KEYCODE_BACKSLASH: number = 2061;
const KEYCODE_SEMICOLON: number = 2062;
const KEYCODE_APOSTROPHE: number = 2063;
const KEYCODE_SLASH: number = 2064;

function stroke(keyCode: number, shift: boolean = false): MoonlightImeKeyStroke {
  return { keyCode: keyCode, shift: shift };
}

export function moonlightImeAsciiKeyStroke(
  character: string
): MoonlightImeKeyStroke | null {
  if (character.length !== 1) { return null; }
  const code: number = character.charCodeAt(0);
  if (code >= 48 && code <= 57) { return stroke(KEYCODE_0 + code - 48); }
  if (code >= 97 && code <= 122) { return stroke(KEYCODE_A + code - 97); }
  if (code >= 65 && code <= 90) { return stroke(KEYCODE_A + code - 65, true); }
  switch (character) {
    case '\t': return stroke(KEYCODE_TAB);
    case '\r':
    case '\n': return stroke(KEYCODE_ENTER);
    case ' ': return stroke(KEYCODE_SPACE);
    case ',': return stroke(KEYCODE_COMMA);
    case '.': return stroke(KEYCODE_PERIOD);
    case '`': return stroke(KEYCODE_GRAVE);
    case '-': return stroke(KEYCODE_MINUS);
    case '=': return stroke(KEYCODE_EQUALS);
    case '[': return stroke(KEYCODE_LEFT_BRACKET);
    case ']': return stroke(KEYCODE_RIGHT_BRACKET);
    case '\\': return stroke(KEYCODE_BACKSLASH);
    case ';': return stroke(KEYCODE_SEMICOLON);
    case "'": return stroke(KEYCODE_APOSTROPHE);
    case '/': return stroke(KEYCODE_SLASH);
    case '<': return stroke(KEYCODE_COMMA, true);
    case '>': return stroke(KEYCODE_PERIOD, true);
    case '~': return stroke(KEYCODE_GRAVE, true);
    case '_': return stroke(KEYCODE_MINUS, true);
    case '+': return stroke(KEYCODE_EQUALS, true);
    case '{': return stroke(KEYCODE_LEFT_BRACKET, true);
    case '}': return stroke(KEYCODE_RIGHT_BRACKET, true);
    case '|': return stroke(KEYCODE_BACKSLASH, true);
    case ':': return stroke(KEYCODE_SEMICOLON, true);
    case '"': return stroke(KEYCODE_APOSTROPHE, true);
    case '?': return stroke(KEYCODE_SLASH, true);
    case '!': return stroke(KEYCODE_0 + 1, true);
    case '@': return stroke(KEYCODE_0 + 2, true);
    case '#': return stroke(KEYCODE_0 + 3, true);
    case '$': return stroke(KEYCODE_0 + 4, true);
    case '%': return stroke(KEYCODE_0 + 5, true);
    case '^': return stroke(KEYCODE_0 + 6, true);
    case '&': return stroke(KEYCODE_0 + 7, true);
    case '*': return stroke(KEYCODE_0 + 8, true);
    case '(': return stroke(KEYCODE_0 + 9, true);
    case ')': return stroke(KEYCODE_0, true);
    default: return null;
  }
}
