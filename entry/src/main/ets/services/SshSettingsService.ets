import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CloudStore } from './CloudStore';
import {
  cloudUserSettingIsSyncable,
  CloudUserSettingValue
} from './CloudSyncSettingsPolicy';
import {
  SSH_LEGACY_FONT_SIZE_KEY,
  SSH_LEGACY_FOREGROUND_COLOR_KEY,
  SSH_LEGACY_LINE_SPACING_KEY,
  SSH_SETTINGS_SCHEMA_VERSION,
  SSH_SETTINGS_SCHEMA_VERSION_KEY,
  SSH_SESSION_LOCALE_KEY,
  SSH_TERMINAL_FONT_SIZE_KEY,
  SSH_TERMINAL_FOREGROUND_COLOR_KEY,
  SSH_TERMINAL_LINE_SPACING_KEY,
  SshTerminalAppearance,
  defaultSshTerminalAppearance,
  hasSshTerminalAppearanceCloudSettings,
  normalizeSshSessionLocale,
  sshSessionLocalePreferenceKey,
  normalizeSshTerminalLineSpacing,
  normalizeSshTerminalFontSize,
  normalizeSshTerminalForegroundColor,
  resolveSshTerminalAppearance,
  resolveSshTerminalAppearanceFromCloudSettings
} from './SshSettingsPolicy';

const SSH_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';

/** Owns global SSH terminal/session preferences without owning host trust data. */
export class SshSettingsService {
  private static instance: SshSettingsService;
  private values: SshTerminalAppearance = defaultSshTerminalAppearance();
  private sessionLocale: string = '';
  private context: common.Context | null = null;
  private initialized: boolean = false;

  static getInstance(): SshSettingsService {
    if (!SshSettingsService.instance) {
      SshSettingsService.instance = new SshSettingsService();
    }
    return SshSettingsService.instance;
  }

  init(context: common.Context): SshTerminalAppearance {
    this.context = context;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: SSH_PREFERENCES_NAME });
      const storedPreferredColor: Object = prefs.getSync(SSH_TERMINAL_FOREGROUND_COLOR_KEY, '') as Object;
      const storedLegacyColor: Object = prefs.getSync(SSH_LEGACY_FOREGROUND_COLOR_KEY, '') as Object;
      const storedPreferredFontSize: Object = prefs.getSync(SSH_TERMINAL_FONT_SIZE_KEY, 0) as Object;
      const storedLegacyFontSize: Object = prefs.getSync(SSH_LEGACY_FONT_SIZE_KEY, 0) as Object;
      const storedPreferredLineSpacing: Object = prefs.getSync(SSH_TERMINAL_LINE_SPACING_KEY, 0) as Object;
      const storedLegacyLineSpacing: Object = prefs.getSync(SSH_LEGACY_LINE_SPACING_KEY, 0) as Object;
      const storedSessionLocale: Object = prefs.getSync(SSH_SESSION_LOCALE_KEY, '') as Object;
      const preferredColor: string = typeof storedPreferredColor === 'string' ? storedPreferredColor as string : '';
      const legacyColor: string = typeof storedLegacyColor === 'string' ? storedLegacyColor as string : '';
      const preferredFontSize: number = typeof storedPreferredFontSize === 'number'
        ? storedPreferredFontSize as number : 0;
      const legacyFontSize: number = typeof storedLegacyFontSize === 'number'
        ? storedLegacyFontSize as number : 0;
      const preferredLineSpacing: number = typeof storedPreferredLineSpacing === 'number'
        ? storedPreferredLineSpacing as number : 0;
      const legacyLineSpacing: number = typeof storedLegacyLineSpacing === 'number'
        ? storedLegacyLineSpacing as number : 0;
      this.values = resolveSshTerminalAppearance(
        preferredColor, legacyColor, preferredFontSize, legacyFontSize,
        preferredLineSpacing, legacyLineSpacing);
      this.sessionLocale = normalizeSshSessionLocale(
        typeof storedSessionLocale === 'string' ? storedSessionLocale as string : '');
      this.writeRuntimeAndLocal(prefs);
    } catch (_e) {
      this.values = defaultSshTerminalAppearance();
      this.sessionLocale = '';
      this.writeRuntimeAndLocal(null);
    }
    this.initialized = true;
    return this.get();
  }

  get(): SshTerminalAppearance {
    return {
      foregroundColor: this.values.foregroundColor,
      fontSize: this.values.fontSize,
      lineSpacing: this.values.lineSpacing
    };
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  getSshSessionLocale(hostId: string = ''): string {
    const key: string = sshSessionLocalePreferenceKey(hostId);
    const runtimeLocale: Object = AppStorage.get<string>(key) as Object;
    if (typeof runtimeLocale === 'string') {
      return normalizeSshSessionLocale(runtimeLocale as string);
    }
    if (hostId.trim().length === 0) { return this.sessionLocale; }
    try {
      const prefs = this.context === null ? null :
        preferences.getPreferencesSync(this.context, { name: SSH_PREFERENCES_NAME });
      if (prefs === null) { return ''; }
      const storedLocale: Object = prefs.getSync(key, '') as Object;
      const normalized: string = normalizeSshSessionLocale(
        typeof storedLocale === 'string' ? storedLocale as string : '');
      AppStorage.setOrCreate(key, normalized);
      return normalized;
    } catch (_e) {
      return '';
    }
  }

  /** Locale is device-local because available locales are a property of the target server. */
  saveSshSessionLocale(value: string, hostId: string = ''): string {
    const normalized: string = normalizeSshSessionLocale(value);
    if (hostId.trim().length === 0) {
      this.sessionLocale = normalized;
      this.writeRuntimeAndLocal(null);
      return this.sessionLocale;
    }
    const key: string = sshSessionLocalePreferenceKey(hostId);
    AppStorage.setOrCreate(key, normalized);
    try {
      const prefs = this.context === null ? null :
        preferences.getPreferencesSync(this.context, { name: SSH_PREFERENCES_NAME });
      if (prefs !== null) {
        prefs.putSync(key, normalized);
        prefs.flushSync();
      }
    } catch (_e) { /* AppStorage remains authoritative for the active process. */ }
    return normalized;
  }

  saveForegroundColor(value: string): string {
    this.syncValuesFromRuntime();
    this.values.foregroundColor = normalizeSshTerminalForegroundColor(value);
    this.writeRuntimeAndLocal(null);
    this.publishCloudSetting(SSH_TERMINAL_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    this.publishCloudSetting(SSH_LEGACY_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    return this.values.foregroundColor;
  }

  saveFontSize(value: number): number {
    this.syncValuesFromRuntime();
    this.values.fontSize = normalizeSshTerminalFontSize(value);
    this.writeRuntimeAndLocal(null);
    this.publishCloudSetting(SSH_TERMINAL_FONT_SIZE_KEY, this.values.fontSize);
    this.publishCloudSetting(SSH_LEGACY_FONT_SIZE_KEY, this.values.fontSize);
    return this.values.fontSize;
  }

  saveLineSpacing(value: number): number {
    this.syncValuesFromRuntime();
    this.values.lineSpacing = normalizeSshTerminalLineSpacing(value);
    this.writeRuntimeAndLocal(null);
    this.publishCloudSetting(SSH_TERMINAL_LINE_SPACING_KEY, this.values.lineSpacing);
    this.publishCloudSetting(SSH_LEGACY_LINE_SPACING_KEY, this.values.lineSpacing);
    return this.values.lineSpacing;
  }

  /** Apply cloud values with the namespaced key taking precedence over legacy data. */
  applyCloudSettings(settings: Record<string, CloudUserSettingValue>): void {
    if (!hasSshTerminalAppearanceCloudSettings(settings)) { return; }
    this.syncValuesFromRuntime();
    this.values = resolveSshTerminalAppearanceFromCloudSettings(settings, this.values);
    this.writeRuntimeAndLocal(null);
  }

  /** CloudStore can apply a usersettings event before this singleton receives a UI callback. */
  private syncValuesFromRuntime(): void {
    const runtimePreferredColor: Object = AppStorage.get<string>(SSH_TERMINAL_FOREGROUND_COLOR_KEY) as Object;
    const runtimeLegacyColor: Object = AppStorage.get<string>(SSH_LEGACY_FOREGROUND_COLOR_KEY) as Object;
    const runtimePreferredFontSize: Object = AppStorage.get<number>(SSH_TERMINAL_FONT_SIZE_KEY) as Object;
    const runtimeLegacyFontSize: Object = AppStorage.get<number>(SSH_LEGACY_FONT_SIZE_KEY) as Object;
    const runtimePreferredLineSpacing: Object = AppStorage.get<number>(SSH_TERMINAL_LINE_SPACING_KEY) as Object;
    const runtimeLegacyLineSpacing: Object = AppStorage.get<number>(SSH_LEGACY_LINE_SPACING_KEY) as Object;
    this.values = resolveSshTerminalAppearance(
      typeof runtimePreferredColor === 'string' ? runtimePreferredColor as string : '',
      typeof runtimeLegacyColor === 'string' ? runtimeLegacyColor as string : '',
      typeof runtimePreferredFontSize === 'number' ? runtimePreferredFontSize as number : 0,
      typeof runtimeLegacyFontSize === 'number' ? runtimeLegacyFontSize as number : 0,
      typeof runtimePreferredLineSpacing === 'number' ? runtimePreferredLineSpacing as number : 0,
      typeof runtimeLegacyLineSpacing === 'number' ? runtimeLegacyLineSpacing as number : 0
    );
  }

  private writeRuntimeAndLocal(existingPrefs: preferences.Preferences | null): void {
    AppStorage.setOrCreate(SSH_TERMINAL_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    AppStorage.setOrCreate(SSH_TERMINAL_FONT_SIZE_KEY, this.values.fontSize);
    AppStorage.setOrCreate(SSH_TERMINAL_LINE_SPACING_KEY, this.values.lineSpacing);
    AppStorage.setOrCreate(SSH_SESSION_LOCALE_KEY, this.sessionLocale);
    // Keep aliases synchronized for older releases during the migration cycle.
    AppStorage.setOrCreate(SSH_LEGACY_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    AppStorage.setOrCreate(SSH_LEGACY_FONT_SIZE_KEY, this.values.fontSize);
    AppStorage.setOrCreate(SSH_LEGACY_LINE_SPACING_KEY, this.values.lineSpacing);
    try {
      const prefs = existingPrefs ?? (this.context === null ? null :
        preferences.getPreferencesSync(this.context, { name: SSH_PREFERENCES_NAME }));
      if (prefs === null) { return; }
      prefs.putSync(SSH_TERMINAL_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
      prefs.putSync(SSH_TERMINAL_FONT_SIZE_KEY, this.values.fontSize);
      prefs.putSync(SSH_TERMINAL_LINE_SPACING_KEY, this.values.lineSpacing);
      prefs.putSync(SSH_SESSION_LOCALE_KEY, this.sessionLocale);
      prefs.putSync(SSH_LEGACY_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
      prefs.putSync(SSH_LEGACY_FONT_SIZE_KEY, this.values.fontSize);
      prefs.putSync(SSH_LEGACY_LINE_SPACING_KEY, this.values.lineSpacing);
      prefs.putSync(SSH_SETTINGS_SCHEMA_VERSION_KEY, SSH_SETTINGS_SCHEMA_VERSION);
      prefs.flushSync();
    } catch (_e) { /* AppStorage remains usable if local persistence is unavailable. */ }
  }

  private publishCloudSetting(key: string, value: CloudUserSettingValue): void {
    if (!cloudUserSettingIsSyncable(key)) { return; }
    try {
      CloudStore.getInstance().upsertUserSetting(key, value);
    } catch (_e) { /* Cloud sync is best effort and cannot block local SSH use. */ }
  }
}
