export const SSH_SETTINGS_SCHEMA_VERSION: number = 1;
export const SSH_SETTINGS_SCHEMA_VERSION_KEY: string = 'sshSettingsSchemaVersion';
export const SSH_TERMINAL_FOREGROUND_COLOR_KEY: string = 'sshTerminalForegroundColor';
export const SSH_TERMINAL_FONT_SIZE_KEY: string = 'sshTerminalFontSize';

// Legacy aliases stay writable for one compatibility cycle so an older build
// can still read a preference saved by the current build.
export const SSH_LEGACY_FOREGROUND_COLOR_KEY: string = 'terminalFgColor';
export const SSH_LEGACY_FONT_SIZE_KEY: string = 'terminalFontSize';

export const SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR: string = '#33FF33';
export const SSH_DEFAULT_TERMINAL_FONT_SIZE: number = 18;
export const SSH_TERMINAL_FONT_SIZE_MIN: number = 12;
export const SSH_TERMINAL_FONT_SIZE_MAX: number = 32;

export interface SshTerminalAppearance {
  foregroundColor: string;
  fontSize: number;
}

function isHexDigit(value: string): boolean {
  const code: number = value.charCodeAt(0);
  return (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 70) ||
    (code >= 97 && code <= 102);
}

export function isValidSshTerminalForegroundColor(value: string): boolean {
  const normalized: string = value.trim();
  if (normalized.length !== 7 || normalized.charAt(0) !== '#') { return false; }
  for (let i = 1; i < normalized.length; i++) {
    if (!isHexDigit(normalized.charAt(i))) { return false; }
  }
  return true;
}

export function normalizeSshTerminalForegroundColor(value: string): string {
  if (!isValidSshTerminalForegroundColor(value)) {
    return SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR;
  }
  return value.trim().toUpperCase();
}

export function isValidSshTerminalFontSize(value: number): boolean {
  return Number.isFinite(value) && value >= SSH_TERMINAL_FONT_SIZE_MIN &&
    value <= SSH_TERMINAL_FONT_SIZE_MAX;
}

export function normalizeSshTerminalFontSize(value: number): number {
  if (!isValidSshTerminalFontSize(value)) { return SSH_DEFAULT_TERMINAL_FONT_SIZE; }
  return Math.floor(value);
}

export function chooseSshTerminalForegroundColor(
  preferred: string,
  legacy: string,
  fallback: string
): string {
  if (isValidSshTerminalForegroundColor(preferred)) {
    return normalizeSshTerminalForegroundColor(preferred);
  }
  if (isValidSshTerminalForegroundColor(legacy)) {
    return normalizeSshTerminalForegroundColor(legacy);
  }
  return normalizeSshTerminalForegroundColor(fallback);
}

export function chooseSshTerminalFontSize(preferred: number, legacy: number, fallback: number): number {
  if (isValidSshTerminalFontSize(preferred)) { return normalizeSshTerminalFontSize(preferred); }
  if (isValidSshTerminalFontSize(legacy)) { return normalizeSshTerminalFontSize(legacy); }
  return normalizeSshTerminalFontSize(fallback);
}

export function defaultSshTerminalAppearance(): SshTerminalAppearance {
  return {
    foregroundColor: SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR,
    fontSize: SSH_DEFAULT_TERMINAL_FONT_SIZE
  };
}

export function resolveSshTerminalAppearance(
  preferredColor: string,
  legacyColor: string,
  preferredFontSize: number,
  legacyFontSize: number
): SshTerminalAppearance {
  const defaults: SshTerminalAppearance = defaultSshTerminalAppearance();
  return {
    foregroundColor: chooseSshTerminalForegroundColor(
      preferredColor, legacyColor, defaults.foregroundColor),
    fontSize: chooseSshTerminalFontSize(
      preferredFontSize, legacyFontSize, defaults.fontSize)
  };
}

export function isSshTerminalAppearanceKey(key: string): boolean {
  return key === SSH_TERMINAL_FOREGROUND_COLOR_KEY ||
    key === SSH_TERMINAL_FONT_SIZE_KEY ||
    key === SSH_LEGACY_FOREGROUND_COLOR_KEY ||
    key === SSH_LEGACY_FONT_SIZE_KEY;
}

export function hasSshTerminalAppearanceCloudSettings(
  settings: Record<string, string | number | boolean>
): boolean {
  return typeof settings[SSH_TERMINAL_FOREGROUND_COLOR_KEY] === 'string' ||
    typeof settings[SSH_TERMINAL_FONT_SIZE_KEY] === 'number' ||
    typeof settings[SSH_LEGACY_FOREGROUND_COLOR_KEY] === 'string' ||
    typeof settings[SSH_LEGACY_FONT_SIZE_KEY] === 'number';
}

/** Resolve a partial cloud patch without allowing invalid values to replace a valid local value. */
export function resolveSshTerminalAppearanceFromCloudSettings(
  settings: Record<string, string | number | boolean>,
  fallback: SshTerminalAppearance
): SshTerminalAppearance {
  const current: SshTerminalAppearance = resolveSshTerminalAppearance(
    fallback.foregroundColor, '', fallback.fontSize, 0);
  const preferredColor: string = typeof settings[SSH_TERMINAL_FOREGROUND_COLOR_KEY] === 'string'
    ? settings[SSH_TERMINAL_FOREGROUND_COLOR_KEY] as string : '';
  const legacyColor: string = typeof settings[SSH_LEGACY_FOREGROUND_COLOR_KEY] === 'string'
    ? settings[SSH_LEGACY_FOREGROUND_COLOR_KEY] as string : '';
  const preferredFontSize: number = typeof settings[SSH_TERMINAL_FONT_SIZE_KEY] === 'number'
    ? settings[SSH_TERMINAL_FONT_SIZE_KEY] as number : 0;
  const legacyFontSize: number = typeof settings[SSH_LEGACY_FONT_SIZE_KEY] === 'number'
    ? settings[SSH_LEGACY_FONT_SIZE_KEY] as number : 0;
  return {
    foregroundColor: preferredColor !== '' || legacyColor !== ''
      ? chooseSshTerminalForegroundColor(preferredColor, legacyColor, current.foregroundColor)
      : current.foregroundColor,
    fontSize: preferredFontSize !== 0 || legacyFontSize !== 0
      ? chooseSshTerminalFontSize(preferredFontSize, legacyFontSize, current.fontSize)
      : current.fontSize
  };
}
