/**
 * VNC-only physical keyboard normalization.
 *
 * HarmonyOS has exposed both the Harmony key-code table and the Android
 * compatibility table for external keyboards.  VNC sends the value straight
 * to the RFB KeySym mapper, so normalize those input variants here instead of
 * making the native protocol layer guess which platform generated an event.
 * The policy is deliberately VNC-specific; RDP and RustDesk keep their own
 * input contracts.
 */

const VNC_KEYCODE_DPAD_UP: number = 2012;
const VNC_KEYCODE_DPAD_DOWN: number = 2013;
const VNC_KEYCODE_DPAD_LEFT: number = 2014;
const VNC_KEYCODE_DPAD_RIGHT: number = 2015;
const VNC_KEYCODE_ALT_LEFT: number = 2045;
const VNC_KEYCODE_ALT_RIGHT: number = 2046;
const VNC_KEYCODE_SHIFT_LEFT: number = 2047;
const VNC_KEYCODE_SHIFT_RIGHT: number = 2048;
const VNC_KEYCODE_TAB: number = 2049;
const VNC_KEYCODE_SPACE: number = 2050;
const VNC_KEYCODE_ENTER: number = 2054;
const VNC_KEYCODE_BACKSPACE: number = 2055;
const VNC_KEYCODE_PAGE_UP: number = 2068;
const VNC_KEYCODE_PAGE_DOWN: number = 2069;
const VNC_KEYCODE_ESCAPE: number = 2070;
const VNC_KEYCODE_DELETE: number = 2071;
const VNC_KEYCODE_CTRL_LEFT: number = 2072;
const VNC_KEYCODE_CTRL_RIGHT: number = 2073;
const VNC_KEYCODE_CAPS_LOCK: number = 2074;
const VNC_KEYCODE_SCROLL_LOCK: number = 2075;
const VNC_KEYCODE_META_LEFT: number = 2076;
const VNC_KEYCODE_META_RIGHT: number = 2077;
const VNC_KEYCODE_FN: number = 2078;
const VNC_KEYCODE_PRINT_SCREEN: number = 2079;
const VNC_KEYCODE_PAUSE: number = 2080;
const VNC_KEYCODE_MENU: number = 2067;
const VNC_KEYCODE_HOME: number = 2081;
const VNC_KEYCODE_END: number = 2082;
const VNC_KEYCODE_INSERT: number = 2083;
const VNC_KEYCODE_0: number = 2000;
const VNC_KEYCODE_A: number = 2017;
const VNC_KEYCODE_COMMA: number = 2043;
const VNC_KEYCODE_PERIOD: number = 2044;
const VNC_KEYCODE_GRAVE: number = 2056;
const VNC_KEYCODE_MINUS: number = 2057;
const VNC_KEYCODE_EQUALS: number = 2058;
const VNC_KEYCODE_LEFT_BRACKET: number = 2059;
const VNC_KEYCODE_RIGHT_BRACKET: number = 2060;
const VNC_KEYCODE_BACKSLASH: number = 2061;
const VNC_KEYCODE_SEMICOLON: number = 2062;
const VNC_KEYCODE_APOSTROPHE: number = 2063;
const VNC_KEYCODE_SLASH: number = 2064;
const VNC_KEYCODE_AT: number = 2065;
const VNC_KEYCODE_PLUS: number = 2066;
const VNC_KEYCODE_F1: number = 2090;
const VNC_KEYCODE_NUMPAD_0: number = 2103;
const VNC_KEYCODE_NUMPAD_DIVIDE: number = 2113;
const VNC_KEYCODE_NUMPAD_MULTIPLY: number = 2114;
const VNC_KEYCODE_NUMPAD_SUBTRACT: number = 2115;
const VNC_KEYCODE_NUMPAD_ADD: number = 2116;
const VNC_KEYCODE_NUMPAD_DOT: number = 2117;
const VNC_KEYCODE_NUMPAD_COMMA: number = 2118;
const VNC_KEYCODE_NUMPAD_ENTER: number = 2119;
const VNC_KEYCODE_NUMPAD_EQUALS: number = 2120;
const VNC_KEYCODE_NUMPAD_LEFT_PAREN: number = 2121;
const VNC_KEYCODE_NUMPAD_RIGHT_PAREN: number = 2122;

export interface VncPhysicalKeyEventHint {
  unicode: number;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
}

/**
 * A modifier Down/Up event is the authoritative physical state. Some PC
 * TextArea/onKeyPreIme paths return a false modifier snapshot on the following
 * printable event even though the key is still held. Preserve the explicit
 * hold while still accepting either ArkUI spelling as positive evidence.
 */
export function resolveVncPhysicalModifierState(
  reportedPressed: boolean,
  legacyReportedPressed: boolean,
  explicitlyHeld: boolean
): boolean {
  return reportedPressed || legacyReportedPressed || explicitlyHeld;
}

interface VncPhysicalKeyBinding {
  deviceId: number;
  rawKeyCode: number;
  canonicalKeyCode: number;
}

/**
 * Keeps a physical key's down/up mapping stable even when ArkUI omits or
 * changes keyText on the release event. Preview calls never mutate state, so
 * onKeyPreIme can inspect an event before the forwarding handler consumes it.
 */
export class VncPhysicalKeyBindingTracker {
  private bindings: Array<VncPhysicalKeyBinding> = [];

  resolve(deviceId: number, rawKeyCode: number, action: 'down' | 'up',
    candidateKeyCode: number, commit: boolean): number {
    const index: number = this.bindingIndex(deviceId, rawKeyCode);
    if (index >= 0) {
      const canonicalKeyCode: number = this.bindings[index].canonicalKeyCode;
      if (commit && action === 'up') {
        this.bindings.splice(index, 1);
      }
      return canonicalKeyCode;
    }
    if (commit && action === 'down') {
      this.bindings.push({
        deviceId: deviceId,
        rawKeyCode: rawKeyCode,
        canonicalKeyCode: candidateKeyCode
      });
    }
    return candidateKeyCode;
  }

  clear(): void {
    this.bindings = [];
  }

  private bindingIndex(deviceId: number, rawKeyCode: number): number {
    for (let index = 0; index < this.bindings.length; index++) {
      const binding: VncPhysicalKeyBinding = this.bindings[index];
      if (binding.deviceId === deviceId && binding.rawKeyCode === rawKeyCode) {
        return index;
      }
    }
    return -1;
  }
}

function normalizeAndroidKeyCode(keyCode: number): number {
  if (keyCode >= 29 && keyCode <= 54) {
    return VNC_KEYCODE_A + keyCode - 29;
  }
  if (keyCode >= 7 && keyCode <= 16) {
    return VNC_KEYCODE_0 + keyCode - 7;
  }
  switch (keyCode) {
    case 19: return VNC_KEYCODE_DPAD_UP;
    case 20: return VNC_KEYCODE_DPAD_DOWN;
    case 21: return VNC_KEYCODE_DPAD_LEFT;
    case 22: return VNC_KEYCODE_DPAD_RIGHT;
    case 23: return VNC_KEYCODE_ENTER;
    case 55: return VNC_KEYCODE_COMMA;
    case 56: return VNC_KEYCODE_PERIOD;
    case 57: return VNC_KEYCODE_ALT_LEFT;
    case 58: return VNC_KEYCODE_ALT_RIGHT;
    case 59: return VNC_KEYCODE_SHIFT_LEFT;
    case 60: return VNC_KEYCODE_SHIFT_RIGHT;
    case 61: return VNC_KEYCODE_TAB;
    case 62: return VNC_KEYCODE_SPACE;
    case 66: return VNC_KEYCODE_ENTER;
    case 67: return VNC_KEYCODE_BACKSPACE;
    case 68: return VNC_KEYCODE_GRAVE;
    case 69: return VNC_KEYCODE_MINUS;
    case 70: return VNC_KEYCODE_EQUALS;
    case 71: return VNC_KEYCODE_LEFT_BRACKET;
    case 72: return VNC_KEYCODE_RIGHT_BRACKET;
    case 73: return VNC_KEYCODE_BACKSLASH;
    case 74: return VNC_KEYCODE_SEMICOLON;
    case 75: return VNC_KEYCODE_APOSTROPHE;
    case 76: return VNC_KEYCODE_SLASH;
    case 77: return VNC_KEYCODE_AT;
    case 81: return VNC_KEYCODE_PLUS;
    case 82: return VNC_KEYCODE_MENU;
    case 92: return VNC_KEYCODE_PAGE_UP;
    case 93: return VNC_KEYCODE_PAGE_DOWN;
    case 111: return VNC_KEYCODE_ESCAPE;
    case 112: return VNC_KEYCODE_DELETE;
    case 113: return VNC_KEYCODE_CTRL_LEFT;
    case 114: return VNC_KEYCODE_CTRL_RIGHT;
    case 115: return VNC_KEYCODE_CAPS_LOCK;
    case 116: return VNC_KEYCODE_SCROLL_LOCK;
    case 117: return VNC_KEYCODE_META_LEFT;
    case 118: return VNC_KEYCODE_META_RIGHT;
    case 122: return VNC_KEYCODE_HOME;
    case 123: return VNC_KEYCODE_END;
    case 124: return VNC_KEYCODE_INSERT;
    case 131: return VNC_KEYCODE_F1;
    case 132: return VNC_KEYCODE_F1 + 1;
    case 133: return VNC_KEYCODE_F1 + 2;
    case 134: return VNC_KEYCODE_F1 + 3;
    case 135: return VNC_KEYCODE_F1 + 4;
    case 136: return VNC_KEYCODE_F1 + 5;
    case 137: return VNC_KEYCODE_F1 + 6;
    case 138: return VNC_KEYCODE_F1 + 7;
    case 139: return VNC_KEYCODE_F1 + 8;
    case 140: return VNC_KEYCODE_F1 + 9;
    case 141: return VNC_KEYCODE_F1 + 10;
    case 142: return VNC_KEYCODE_F1 + 11;
    case 144: return VNC_KEYCODE_NUMPAD_0;
    case 145: return VNC_KEYCODE_NUMPAD_0 + 1;
    case 146: return VNC_KEYCODE_NUMPAD_0 + 2;
    case 147: return VNC_KEYCODE_NUMPAD_0 + 3;
    case 148: return VNC_KEYCODE_NUMPAD_0 + 4;
    case 149: return VNC_KEYCODE_NUMPAD_0 + 5;
    case 150: return VNC_KEYCODE_NUMPAD_0 + 6;
    case 151: return VNC_KEYCODE_NUMPAD_0 + 7;
    case 152: return VNC_KEYCODE_NUMPAD_0 + 8;
    case 153: return VNC_KEYCODE_NUMPAD_0 + 9;
    case 154: return VNC_KEYCODE_NUMPAD_DIVIDE;
    case 155: return VNC_KEYCODE_NUMPAD_MULTIPLY;
    case 156: return VNC_KEYCODE_NUMPAD_SUBTRACT;
    case 157: return VNC_KEYCODE_NUMPAD_ADD;
    case 158: return VNC_KEYCODE_NUMPAD_DOT;
    case 159: return VNC_KEYCODE_NUMPAD_COMMA;
    case 160: return VNC_KEYCODE_NUMPAD_ENTER;
    case 161: return VNC_KEYCODE_NUMPAD_EQUALS;
    case 162: return VNC_KEYCODE_NUMPAD_LEFT_PAREN;
    case 163: return VNC_KEYCODE_NUMPAD_RIGHT_PAREN;
    default: return keyCode;
  }
}

/**
 * Returns the canonical Harmony key code consumed by the VNC RFB mapper.
 * Harmony values are idempotent; Android and desktop compatibility values are
 * converted only when they have an unambiguous keyboard meaning.
 */
export function normalizeVncPhysicalKeyCode(keyCode: number): number {
  const androidNormalized: number = normalizeAndroidKeyCode(keyCode);
  if (androidNormalized !== keyCode) {
    return androidNormalized;
  }

  // Some XComponent/desktop paths report the DOM-style letter and punctuation
  // codes.  These values are not used by the Harmony table for the normal
  // printable path, so retain RustDesk's physical-key compatibility mapping.
  if (keyCode >= 65 && keyCode <= 90) {
    return VNC_KEYCODE_A + keyCode - 65;
  }
  switch (keyCode) {
    case 186: return VNC_KEYCODE_SEMICOLON;
    case 187: return VNC_KEYCODE_EQUALS;
    case 188: return VNC_KEYCODE_COMMA;
    case 189: return VNC_KEYCODE_MINUS;
    case 190: return VNC_KEYCODE_PERIOD;
    case 191: return VNC_KEYCODE_SLASH;
    case 192: return VNC_KEYCODE_GRAVE;
    case 219: return VNC_KEYCODE_LEFT_BRACKET;
    case 220: return VNC_KEYCODE_BACKSLASH;
    case 221: return VNC_KEYCODE_RIGHT_BRACKET;
    case 222: return VNC_KEYCODE_APOSTROPHE;
    default: return keyCode;
  }
}

function namedVncPhysicalKeyCode(keyText: string): number {
  const upper: string = keyText === undefined || keyText === null ? '' : keyText.toUpperCase();
  const withoutPrefix: string = upper.indexOf('KEYCODE_') === 0 ? upper.substring(8) : upper;
  const compact: string = withoutPrefix.split('_').join('').split('-').join('').split(' ').join('');
  for (let functionNumber = 1; functionNumber <= 24; functionNumber++) {
    if (compact === 'F' + functionNumber.toString()) {
      return functionNumber <= 12 ?
        VNC_KEYCODE_F1 + functionNumber - 1 : 2816 + functionNumber - 13;
    }
  }
  switch (compact) {
    case 'SHIFTRIGHT': return VNC_KEYCODE_SHIFT_RIGHT;
    case 'SHIFT':
    case 'SHIFTLEFT': return VNC_KEYCODE_SHIFT_LEFT;
    case 'CTRLRIGHT':
    case 'CONTROLRIGHT': return VNC_KEYCODE_CTRL_RIGHT;
    case 'CTRL':
    case 'CONTROL':
    case 'CTRLLEFT':
    case 'CONTROLLEFT': return VNC_KEYCODE_CTRL_LEFT;
    case 'ALTRIGHT': return VNC_KEYCODE_ALT_RIGHT;
    case 'ALT':
    case 'ALTLEFT': return VNC_KEYCODE_ALT_LEFT;
    case 'METARIGHT':
    case 'WINRIGHT':
    case 'COMMANDRIGHT': return VNC_KEYCODE_META_RIGHT;
    case 'META':
    case 'WIN':
    case 'COMMAND':
    case 'METALEFT':
    case 'WINLEFT':
    case 'COMMANDLEFT': return VNC_KEYCODE_META_LEFT;
    case 'FN': return VNC_KEYCODE_FN;
    case 'PRINTSCREEN':
    case 'SYSRQ': return VNC_KEYCODE_PRINT_SCREEN;
    case 'PAUSE':
    case 'BREAK': return VNC_KEYCODE_PAUSE;
    case 'SPACE': return VNC_KEYCODE_SPACE;
    case 'TAB': return VNC_KEYCODE_TAB;
    case 'ENTER':
    case 'RETURN': return VNC_KEYCODE_ENTER;
    case 'BACKSPACE':
    case 'DEL': return VNC_KEYCODE_BACKSPACE;
    case 'DELETE':
    case 'FORWARDDEL':
    case 'FORWARDDELETE': return VNC_KEYCODE_DELETE;
    case 'CAPSLOCK': return VNC_KEYCODE_CAPS_LOCK;
    case 'SCROLLLOCK': return VNC_KEYCODE_SCROLL_LOCK;
    case 'ESC':
    case 'ESCAPE': return VNC_KEYCODE_ESCAPE;
    case 'PAGEUP': return VNC_KEYCODE_PAGE_UP;
    case 'PAGEDOWN': return VNC_KEYCODE_PAGE_DOWN;
    case 'HOME':
    case 'MOVEHOME': return VNC_KEYCODE_HOME;
    case 'END':
    case 'MOVEEND': return VNC_KEYCODE_END;
    case 'INSERT': return VNC_KEYCODE_INSERT;
    case 'MENU':
    case 'CONTEXTMENU': return VNC_KEYCODE_MENU;
    case 'DPADUP':
    case 'ARROWUP': return VNC_KEYCODE_DPAD_UP;
    case 'DPADDOWN':
    case 'ARROWDOWN': return VNC_KEYCODE_DPAD_DOWN;
    case 'DPADLEFT':
    case 'ARROWLEFT': return VNC_KEYCODE_DPAD_LEFT;
    case 'DPADRIGHT':
    case 'ARROWRIGHT': return VNC_KEYCODE_DPAD_RIGHT;
    default: return -1;
  }
}

/**
 * Normalizes an ArkUI key event when the platform also supplies a key name.
 *
 * A few external-keyboard paths report DOM-style modifier numbers (for
 * example Shift=16) while the Android compatibility table uses the same
 * number for the digit 9.  `keyText` is the only unambiguous discriminator,
 * so prefer the named modifier/control key and fall back to the numeric
 * normalizer for all other VNC input.
 */
export function normalizeVncPhysicalKeyEventCode(keyCode: number, keyText: string,
  hint?: VncPhysicalKeyEventHint): number {
  const namedKeyCode: number = namedVncPhysicalKeyCode(keyText);
  if (namedKeyCode >= 0) {
    return namedKeyCode;
  }
  // Desktop compatibility codes overlap Android digits and controls. The
  // modifier's own Down/Up event can arrive before ArkUI updates the modifier
  // state (and Up arrives after it clears the state), so state=true cannot be
  // required here. A missing key name plus Unicode=0 distinguishes the DOM
  // modifier event from Android's printable 9/*/# keys on the same numbers.
  if (hint !== undefined && hint.unicode <= 0) {
    if (keyCode === 16) { return VNC_KEYCODE_SHIFT_LEFT; }
    if (keyCode === 17) { return VNC_KEYCODE_CTRL_LEFT; }
    if (keyCode === 18) { return VNC_KEYCODE_ALT_LEFT; }
    // Windows VK_L*/VK_R* variants are also exposed by some PC-mode
    // XComponent paths. Their 160..163 range overlaps Android numpad keys,
    // whose printable Unicode is non-zero, so keep the same discriminator.
    if (keyCode === 160) { return VNC_KEYCODE_SHIFT_LEFT; }
    if (keyCode === 161) { return VNC_KEYCODE_SHIFT_RIGHT; }
    if (keyCode === 162) { return VNC_KEYCODE_CTRL_LEFT; }
    if (keyCode === 163) { return VNC_KEYCODE_CTRL_RIGHT; }
    if (keyCode === 164) { return VNC_KEYCODE_ALT_LEFT; }
    if (keyCode === 165) { return VNC_KEYCODE_ALT_RIGHT; }
    // Android raw 113/114 overlap DOM F2/F3. A live Ctrl modifier state is
    // stronger evidence than the unnamed desktop compatibility range.
    if (keyCode === 113 && hint.ctrl) { return VNC_KEYCODE_CTRL_LEFT; }
    if (keyCode === 114 && hint.ctrl) { return VNC_KEYCODE_CTRL_RIGHT; }
    if ((keyCode === 91 || keyCode === 92) && hint.meta) {
      return keyCode === 92 ? VNC_KEYCODE_META_RIGHT : VNC_KEYCODE_META_LEFT;
    }
  }
  // The Windows external-keyboard/XComponent path can omit keyText for the
  // DOM F1..F12 range. Previously those raw values fell into Android's
  // ForwardDelete/Ctrl/CapsLock/Home table, so every function key either did
  // nothing useful or sent the wrong RFB KeySym. Named Android controls and
  // live Ctrl state were resolved above; an unnamed non-printable 112..123
  // event is therefore treated as the desktop function row.
  if (keyCode >= 112 && keyCode <= 123 &&
    (hint === undefined || hint.unicode <= 0)) {
    return VNC_KEYCODE_F1 + keyCode - 112;
  }
  return normalizeVncPhysicalKeyCode(keyCode);
}
