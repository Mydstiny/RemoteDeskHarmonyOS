import {
  isValidSshTerminalFontSize,
  isValidSshTerminalForegroundColor,
  isValidSshTerminalLineSpacing,
  SshTerminalAppearance
} from '../../SshSettingsPolicy';

export type SshTerminalFontFamily = 'monospace' | 'HarmonyOS Sans SC' | 'Menlo' | 'JetBrains Mono';
export type SshTerminalFontWeight = 'normal' | 'bold';
export type SshTerminalCursorStyle = 'block' | 'bar' | 'underline';
export type SshTerminalBellStyle = 'none' | 'visual' | 'sound';
export type SshTerminalAccessoryDensity = 'comfortable' | 'compact';

export interface SshTerminalProfileSettingsV1 {
  foregroundColor: string | null;
  backgroundColor: string | null;
  palette: string[] | null;
  fontFamily: SshTerminalFontFamily | null;
  fontSize: number | null;
  lineSpacing: number | null;
  fontWeight: SshTerminalFontWeight | null;
  cursorStyle: SshTerminalCursorStyle | null;
  cursorBlink: boolean | null;
  scrollback: number | null;
  bellStyle: SshTerminalBellStyle | null;
  linkHandling: boolean | null;
  copyOnSelect: boolean | null;
  rightClickPaste: boolean | null;
  bracketedPaste: boolean | null;
  mouseReporting: boolean | null;
  accessoryKeys: string[] | null;
  accessoryDensity: SshTerminalAccessoryDensity | null;
  captureGlobalShortcuts: boolean | null;
}

export interface SshTerminalProfileV1 {
  schemaVersion: 1;
  id: string;
  name: string;
  settings: SshTerminalProfileSettingsV1;
  updatedAtMs: number;
}

export interface SshTerminalHostProfileAssignmentV1 {
  hostId: string;
  profileId: string;
}

export interface SshTerminalProfileDocumentV1 {
  schemaVersion: 1;
  globalProfileId: string;
  profiles: SshTerminalProfileV1[];
  hostAssignments: SshTerminalHostProfileAssignmentV1[];
}

export interface SshTerminalResolvedProfile {
  foregroundColor: string;
  backgroundColor: string;
  palette: string[];
  fontFamily: SshTerminalFontFamily;
  fontSize: number;
  lineSpacing: number;
  fontWeight: SshTerminalFontWeight;
  cursorStyle: SshTerminalCursorStyle;
  cursorBlink: boolean;
  scrollback: number;
  bellStyle: SshTerminalBellStyle;
  linkHandling: boolean;
  copyOnSelect: boolean;
  rightClickPaste: boolean;
  bracketedPaste: boolean;
  mouseReporting: boolean;
  accessoryKeys: string[];
  accessoryDensity: SshTerminalAccessoryDensity;
  captureGlobalShortcuts: boolean;
  appliedProfileIds: string[];
}

export const SSH_TERMINAL_PROFILE_SCHEMA_VERSION: number = 1;
export const SSH_TERMINAL_PROFILE_MAX_PROFILES: number = 64;
export const SSH_TERMINAL_PROFILE_MAX_HOST_ASSIGNMENTS: number = 256;
export const SSH_TERMINAL_PROFILE_SCROLLBACK_MIN: number = 1000;
export const SSH_TERMINAL_PROFILE_SCROLLBACK_MAX: number = 100000;
export const SSH_TERMINAL_PROFILE_LEGACY_ID: string = 'legacy-global';

export function sshTerminalSessionProfileScopeKey(hostId: string,
  sessionGeneration: number): string {
  const normalizedHostId: string = hostId.trim();
  if (normalizedHostId.length === 0 || !Number.isFinite(sessionGeneration) ||
    sessionGeneration <= 0) { return ''; }
  return normalizedHostId + ':generation:' + Math.floor(sessionGeneration).toString();
}

const DEFAULT_PALETTE: string[] = [
  '#0D0D0D', '#CD3131', '#0DBC79', '#E5E510',
  '#2472C8', '#BC3FBC', '#11A8CD', '#E5E5E5',
  '#666666', '#F14C4C', '#23D18B', '#F5F543',
  '#3B8EEA', '#D670D6', '#29B8DB', '#FFFFFF'
];

const DEFAULT_ACCESSORY_KEYS: string[] = [
  'ESC', 'CTRL', 'ALT', 'TAB', 'LEFT', 'UP', 'DOWN', 'RIGHT'
];

const ALLOWED_ACCESSORY_KEYS: string[] = [
  'ESC', 'CTRL', 'ALT', 'SHIFT', 'TAB', 'LEFT', 'UP', 'DOWN', 'RIGHT',
  'HOME', 'END', 'PGUP', 'PGDN'
];

function cloneStrings(values: string[]): string[] {
  return values.map((value: string): string => value);
}

export function emptySshTerminalProfileSettings(): SshTerminalProfileSettingsV1 {
  return {
    foregroundColor: null,
    backgroundColor: null,
    palette: null,
    fontFamily: null,
    fontSize: null,
    lineSpacing: null,
    fontWeight: null,
    cursorStyle: null,
    cursorBlink: null,
    scrollback: null,
    bellStyle: null,
    linkHandling: null,
    copyOnSelect: null,
    rightClickPaste: null,
    bracketedPaste: null,
    mouseReporting: null,
    accessoryKeys: null,
    accessoryDensity: null,
    captureGlobalShortcuts: null
  };
}

export function defaultSshTerminalResolvedProfile(): SshTerminalResolvedProfile {
  return {
    foregroundColor: '#33FF33',
    backgroundColor: '#0D0D0D',
    palette: cloneStrings(DEFAULT_PALETTE),
    fontFamily: 'monospace',
    fontSize: 18,
    lineSpacing: 1.12,
    fontWeight: 'normal',
    cursorStyle: 'bar',
    cursorBlink: true,
    scrollback: 10000,
    bellStyle: 'none',
    linkHandling: false,
    copyOnSelect: false,
    rightClickPaste: false,
    bracketedPaste: true,
    mouseReporting: true,
    accessoryKeys: cloneStrings(DEFAULT_ACCESSORY_KEYS),
    accessoryDensity: 'comfortable',
    captureGlobalShortcuts: false,
    appliedProfileIds: []
  };
}

export function emptySshTerminalProfileDocument(): SshTerminalProfileDocumentV1 {
  return { schemaVersion: 1, globalProfileId: '', profiles: [], hostAssignments: [] };
}

function validId(value: string): boolean {
  const normalized: string = value.trim();
  return normalized.length > 0 && normalized.length <= 96 &&
    !/[^A-Za-z0-9._:-]/.test(normalized);
}

function validName(value: string): boolean {
  const normalized: string = value.trim();
  return normalized.length > 0 && normalized.length <= 64 &&
    normalized.indexOf('\n') < 0 && normalized.indexOf('\r') < 0;
}

function validColor(value: string): boolean {
  return isValidSshTerminalForegroundColor(value);
}

function validPalette(values: string[]): boolean {
  if (values.length !== 16) { return false; }
  for (let index: number = 0; index < values.length; index++) {
    if (typeof values[index] !== 'string' || !validColor(values[index])) { return false; }
  }
  return true;
}

function validFontFamily(value: string): boolean {
  return value === 'monospace' || value === 'HarmonyOS Sans SC' ||
    value === 'Menlo' || value === 'JetBrains Mono';
}

function validFontWeight(value: string): boolean {
  return value === 'normal' || value === 'bold';
}

function validCursorStyle(value: string): boolean {
  return value === 'block' || value === 'bar' || value === 'underline';
}

function validBellStyle(value: string): boolean {
  return value === 'none' || value === 'visual' || value === 'sound';
}

function validAccessoryDensity(value: string): boolean {
  return value === 'comfortable' || value === 'compact';
}

function validAccessoryKeys(values: string[]): boolean {
  if (values.length === 0 || values.length > ALLOWED_ACCESSORY_KEYS.length) { return false; }
  const used: Set<string> = new Set<string>();
  for (let index: number = 0; index < values.length; index++) {
    const value: string = values[index];
    if (typeof value !== 'string' || ALLOWED_ACCESSORY_KEYS.indexOf(value) < 0 ||
      used.has(value)) { return false; }
    used.add(value);
  }
  return true;
}

function optionalString(value: Object | null | undefined,
  validator: (value: string) => boolean): string | null | undefined {
  if (value === undefined || value === null) { return null; }
  return typeof value === 'string' && validator(value as string) ? value as string : undefined;
}

function optionalBoolean(value: Object | null | undefined): boolean | null | undefined {
  if (value === undefined || value === null) { return null; }
  return typeof value === 'boolean' ? value as boolean : undefined;
}

/** Strict field validation plus whitelist reconstruction. */
export function normalizeSshTerminalProfileSettings(
  source: SshTerminalProfileSettingsV1
): SshTerminalProfileSettingsV1 | null {
  if (source === null || source === undefined || typeof source !== 'object') { return null; }
  const result: SshTerminalProfileSettingsV1 = emptySshTerminalProfileSettings();
  const foreground: string | null | undefined = optionalString(
    source.foregroundColor, validColor);
  const background: string | null | undefined = optionalString(
    source.backgroundColor, validColor);
  const fontFamily: string | null | undefined = optionalString(
    source.fontFamily, validFontFamily);
  const fontWeight: string | null | undefined = optionalString(
    source.fontWeight, validFontWeight);
  const cursorStyle: string | null | undefined = optionalString(
    source.cursorStyle, validCursorStyle);
  const bellStyle: string | null | undefined = optionalString(
    source.bellStyle, validBellStyle);
  const density: string | null | undefined = optionalString(
    source.accessoryDensity, validAccessoryDensity);
  if (foreground === undefined || background === undefined || fontFamily === undefined ||
    fontWeight === undefined || cursorStyle === undefined || bellStyle === undefined ||
    density === undefined) { return null; }
  result.foregroundColor = foreground;
  result.backgroundColor = background;
  result.fontFamily = fontFamily as SshTerminalFontFamily | null;
  result.fontWeight = fontWeight as SshTerminalFontWeight | null;
  result.cursorStyle = cursorStyle as SshTerminalCursorStyle | null;
  result.bellStyle = bellStyle as SshTerminalBellStyle | null;
  result.accessoryDensity = density as SshTerminalAccessoryDensity | null;
  if (source.palette !== undefined && source.palette !== null) {
    if (!Array.isArray(source.palette) || !validPalette(source.palette)) { return null; }
    result.palette = cloneStrings(source.palette);
  }
  if (source.fontSize !== undefined && source.fontSize !== null) {
    if (typeof source.fontSize !== 'number' || !isValidSshTerminalFontSize(source.fontSize)) {
      return null;
    }
    result.fontSize = Math.floor(source.fontSize);
  }
  if (source.lineSpacing !== undefined && source.lineSpacing !== null) {
    if (typeof source.lineSpacing !== 'number' ||
      !isValidSshTerminalLineSpacing(source.lineSpacing)) { return null; }
    result.lineSpacing = Math.round(source.lineSpacing * 100) / 100;
  }
  if (source.scrollback !== undefined && source.scrollback !== null) {
    if (typeof source.scrollback !== 'number' || !Number.isInteger(source.scrollback) ||
      source.scrollback < SSH_TERMINAL_PROFILE_SCROLLBACK_MIN ||
      source.scrollback > SSH_TERMINAL_PROFILE_SCROLLBACK_MAX) { return null; }
    result.scrollback = source.scrollback;
  }
  const cursorBlink: boolean | null | undefined = optionalBoolean(source.cursorBlink);
  const linkHandling: boolean | null | undefined = optionalBoolean(source.linkHandling);
  const copyOnSelect: boolean | null | undefined = optionalBoolean(source.copyOnSelect);
  const rightClickPaste: boolean | null | undefined = optionalBoolean(source.rightClickPaste);
  const bracketedPaste: boolean | null | undefined = optionalBoolean(source.bracketedPaste);
  const mouseReporting: boolean | null | undefined = optionalBoolean(source.mouseReporting);
  const capture: boolean | null | undefined = optionalBoolean(source.captureGlobalShortcuts);
  if (cursorBlink === undefined || linkHandling === undefined || copyOnSelect === undefined ||
    rightClickPaste === undefined || bracketedPaste === undefined ||
    mouseReporting === undefined || capture === undefined) { return null; }
  result.cursorBlink = cursorBlink;
  result.linkHandling = linkHandling;
  result.copyOnSelect = copyOnSelect;
  result.rightClickPaste = rightClickPaste;
  result.bracketedPaste = bracketedPaste;
  result.mouseReporting = mouseReporting;
  result.captureGlobalShortcuts = capture;
  if (source.accessoryKeys !== undefined && source.accessoryKeys !== null) {
    if (!Array.isArray(source.accessoryKeys) || !validAccessoryKeys(source.accessoryKeys)) {
      return null;
    }
    result.accessoryKeys = cloneStrings(source.accessoryKeys);
  }
  return result;
}

export function cloneSshTerminalProfile(profile: SshTerminalProfileV1): SshTerminalProfileV1 {
  const settings: SshTerminalProfileSettingsV1 =
    normalizeSshTerminalProfileSettings(profile.settings) ?? emptySshTerminalProfileSettings();
  return {
    schemaVersion: 1,
    id: profile.id,
    name: profile.name,
    settings,
    updatedAtMs: profile.updatedAtMs
  };
}

export function normalizeSshTerminalProfile(
  source: SshTerminalProfileV1
): SshTerminalProfileV1 | null {
  if (source === null || source === undefined || typeof source !== 'object' ||
    source.schemaVersion !== 1 || typeof source.id !== 'string' || !validId(source.id) ||
    typeof source.name !== 'string' || !validName(source.name) ||
    typeof source.updatedAtMs !== 'number' || !Number.isFinite(source.updatedAtMs) ||
    source.updatedAtMs < 0) { return null; }
  const settings: SshTerminalProfileSettingsV1 | null =
    normalizeSshTerminalProfileSettings(source.settings);
  if (settings === null) { return null; }
  return {
    schemaVersion: 1,
    id: source.id.trim(),
    name: source.name.trim(),
    settings,
    updatedAtMs: Math.floor(source.updatedAtMs)
  };
}

function applySettings(target: SshTerminalResolvedProfile,
  settings: SshTerminalProfileSettingsV1, profileId: string): void {
  if (settings.foregroundColor !== null) { target.foregroundColor = settings.foregroundColor; }
  if (settings.backgroundColor !== null) { target.backgroundColor = settings.backgroundColor; }
  if (settings.palette !== null) { target.palette = cloneStrings(settings.palette); }
  if (settings.fontFamily !== null) { target.fontFamily = settings.fontFamily; }
  if (settings.fontSize !== null) { target.fontSize = settings.fontSize; }
  if (settings.lineSpacing !== null) { target.lineSpacing = settings.lineSpacing; }
  if (settings.fontWeight !== null) { target.fontWeight = settings.fontWeight; }
  if (settings.cursorStyle !== null) { target.cursorStyle = settings.cursorStyle; }
  if (settings.cursorBlink !== null) { target.cursorBlink = settings.cursorBlink; }
  if (settings.scrollback !== null) { target.scrollback = settings.scrollback; }
  if (settings.bellStyle !== null) { target.bellStyle = settings.bellStyle; }
  if (settings.linkHandling !== null) { target.linkHandling = settings.linkHandling; }
  if (settings.copyOnSelect !== null) { target.copyOnSelect = settings.copyOnSelect; }
  if (settings.rightClickPaste !== null) { target.rightClickPaste = settings.rightClickPaste; }
  if (settings.bracketedPaste !== null) { target.bracketedPaste = settings.bracketedPaste; }
  if (settings.mouseReporting !== null) { target.mouseReporting = settings.mouseReporting; }
  if (settings.accessoryKeys !== null) { target.accessoryKeys = cloneStrings(settings.accessoryKeys); }
  if (settings.accessoryDensity !== null) {
    target.accessoryDensity = settings.accessoryDensity;
  }
  if (settings.captureGlobalShortcuts !== null) {
    target.captureGlobalShortcuts = settings.captureGlobalShortcuts;
  }
  if (profileId.length > 0) { target.appliedProfileIds.push(profileId); }
}

function findProfile(document: SshTerminalProfileDocumentV1,
  profileId: string): SshTerminalProfileV1 | null {
  for (let index: number = 0; index < document.profiles.length; index++) {
    if (document.profiles[index].id === profileId) { return document.profiles[index]; }
  }
  return null;
}

export function resolveSshTerminalProfile(document: SshTerminalProfileDocumentV1,
  hostId: string, sessionProfile: SshTerminalProfileV1 | null = null): SshTerminalResolvedProfile {
  const result: SshTerminalResolvedProfile = defaultSshTerminalResolvedProfile();
  const global: SshTerminalProfileV1 | null = findProfile(document, document.globalProfileId);
  if (global !== null) { applySettings(result, global.settings, global.id); }
  const normalizedHostId: string = hostId.trim();
  let hostProfileId: string = '';
  for (let index: number = 0; index < document.hostAssignments.length; index++) {
    if (document.hostAssignments[index].hostId === normalizedHostId) {
      hostProfileId = document.hostAssignments[index].profileId;
      break;
    }
  }
  const hostProfile: SshTerminalProfileV1 | null = findProfile(document, hostProfileId);
  if (hostProfile !== null) { applySettings(result, hostProfile.settings, hostProfile.id); }
  if (sessionProfile !== null) {
    const normalizedSession: SshTerminalProfileV1 | null =
      normalizeSshTerminalProfile(sessionProfile);
    if (normalizedSession !== null) {
      applySettings(result, normalizedSession.settings, normalizedSession.id);
    }
  }
  return result;
}

export function legacySshTerminalProfileDocument(
  appearance: SshTerminalAppearance
): SshTerminalProfileDocumentV1 {
  const settings: SshTerminalProfileSettingsV1 = emptySshTerminalProfileSettings();
  settings.foregroundColor = appearance.foregroundColor;
  settings.fontSize = appearance.fontSize;
  settings.lineSpacing = appearance.lineSpacing;
  const profile: SshTerminalProfileV1 = {
    schemaVersion: 1,
    id: SSH_TERMINAL_PROFILE_LEGACY_ID,
    name: '已迁移的终端外观',
    settings,
    updatedAtMs: 0
  };
  return {
    schemaVersion: 1,
    globalProfileId: profile.id,
    profiles: [profile],
    hostAssignments: []
  };
}

export function decodeSshTerminalProfileDocument(
  raw: string
): SshTerminalProfileDocumentV1 | null {
  if (raw.trim().length === 0) { return emptySshTerminalProfileDocument(); }
  try {
    const source: SshTerminalProfileDocumentV1 =
      JSON.parse(raw) as SshTerminalProfileDocumentV1;
    if (source === null || source === undefined || typeof source !== 'object' ||
      source.schemaVersion !== 1 || typeof source.globalProfileId !== 'string' ||
      !Array.isArray(source.profiles) || !Array.isArray(source.hostAssignments) ||
      source.profiles.length > SSH_TERMINAL_PROFILE_MAX_PROFILES ||
      source.hostAssignments.length > SSH_TERMINAL_PROFILE_MAX_HOST_ASSIGNMENTS) {
      return null;
    }
    const profiles: SshTerminalProfileV1[] = [];
    const profileIds: Set<string> = new Set<string>();
    for (let index: number = 0; index < source.profiles.length; index++) {
      const profile: SshTerminalProfileV1 | null = normalizeSshTerminalProfile(
        source.profiles[index]);
      if (profile === null || profileIds.has(profile.id)) { continue; }
      profiles.push(profile);
      profileIds.add(profile.id);
    }
    const globalProfileId: string = profileIds.has(source.globalProfileId) ?
      source.globalProfileId : '';
    const assignments: SshTerminalHostProfileAssignmentV1[] = [];
    const assignedHosts: Set<string> = new Set<string>();
    for (let index: number = 0; index < source.hostAssignments.length; index++) {
      const item: SshTerminalHostProfileAssignmentV1 = source.hostAssignments[index];
      if (item === null || item === undefined || typeof item !== 'object' ||
        typeof item.hostId !== 'string' || item.hostId.trim().length === 0 ||
        item.hostId.trim().length > 128 || typeof item.profileId !== 'string' ||
        !profileIds.has(item.profileId) || assignedHosts.has(item.hostId.trim())) {
        continue;
      }
      assignments.push({ hostId: item.hostId.trim(), profileId: item.profileId });
      assignedHosts.add(item.hostId.trim());
    }
    return {
      schemaVersion: 1,
      globalProfileId,
      profiles,
      hostAssignments: assignments
    };
  } catch (_err) {
    return null;
  }
}

export function encodeSshTerminalProfileDocument(
  document: SshTerminalProfileDocumentV1
): string | null {
  try {
    const normalized: SshTerminalProfileDocumentV1 | null =
      decodeSshTerminalProfileDocument(JSON.stringify(document));
    return normalized === null ? null : JSON.stringify(normalized);
  } catch (_err) {
    return null;
  }
}
