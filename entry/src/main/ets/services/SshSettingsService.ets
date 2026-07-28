import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CloudStore } from './CloudStore';
import { CloudUserSettingValue } from './CloudSyncSettingsPolicy';
import {
  SSH_LEGACY_FONT_SIZE_KEY,
  SSH_LEGACY_FOREGROUND_COLOR_KEY,
  SSH_SETTINGS_SCHEMA_VERSION,
  SSH_SETTINGS_SCHEMA_VERSION_KEY,
  SSH_TERMINAL_FONT_SIZE_KEY,
  SSH_TERMINAL_FOREGROUND_COLOR_KEY,
  SshTerminalAppearance,
  defaultSshTerminalAppearance,
  hasSshTerminalAppearanceCloudSettings,
  normalizeSshTerminalFontSize,
  normalizeSshTerminalForegroundColor,
  resolveSshTerminalAppearance,
  resolveSshTerminalAppearanceFromCloudSettings
} from './SshSettingsPolicy';

const SSH_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';

/** Owns the global SSH terminal appearance without owning host trust data. */
export class SshSettingsService {
  private static instance: SshSettingsService;
  private values: SshTerminalAppearance = defaultSshTerminalAppearance();
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
      const preferredColor: string = typeof storedPreferredColor === 'string' ? storedPreferredColor as string : '';
      const legacyColor: string = typeof storedLegacyColor === 'string' ? storedLegacyColor as string : '';
      const preferredFontSize: number = typeof storedPreferredFontSize === 'number'
        ? storedPreferredFontSize as number : 0;
      const legacyFontSize: number = typeof storedLegacyFontSize === 'number'
        ? storedLegacyFontSize as number : 0;
      this.values = resolveSshTerminalAppearance(
        preferredColor, legacyColor, preferredFontSize, legacyFontSize);
      this.writeRuntimeAndLocal(prefs);
    } catch (_e) {
      this.values = defaultSshTerminalAppearance();
      this.writeRuntimeAndLocal(null);
    }
    this.initialized = true;
    return this.get();
  }

  get(): SshTerminalAppearance {
    return {
      foregroundColor: this.values.foregroundColor,
      fontSize: this.values.fontSize
    };
  }

  isInitialized(): boolean {
    return this.initialized;
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
    this.values = resolveSshTerminalAppearance(
      typeof runtimePreferredColor === 'string' ? runtimePreferredColor as string : '',
      typeof runtimeLegacyColor === 'string' ? runtimeLegacyColor as string : '',
      typeof runtimePreferredFontSize === 'number' ? runtimePreferredFontSize as number : 0,
      typeof runtimeLegacyFontSize === 'number' ? runtimeLegacyFontSize as number : 0
    );
  }

  private writeRuntimeAndLocal(existingPrefs: preferences.Preferences | null): void {
    AppStorage.setOrCreate(SSH_TERMINAL_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    AppStorage.setOrCreate(SSH_TERMINAL_FONT_SIZE_KEY, this.values.fontSize);
    // Keep aliases synchronized for older releases during the migration cycle.
    AppStorage.setOrCreate(SSH_LEGACY_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
    AppStorage.setOrCreate(SSH_LEGACY_FONT_SIZE_KEY, this.values.fontSize);
    try {
      const prefs = existingPrefs ?? (this.context === null ? null :
        preferences.getPreferencesSync(this.context, { name: SSH_PREFERENCES_NAME }));
      if (prefs === null) { return; }
      prefs.putSync(SSH_TERMINAL_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
      prefs.putSync(SSH_TERMINAL_FONT_SIZE_KEY, this.values.fontSize);
      prefs.putSync(SSH_LEGACY_FOREGROUND_COLOR_KEY, this.values.foregroundColor);
      prefs.putSync(SSH_LEGACY_FONT_SIZE_KEY, this.values.fontSize);
      prefs.putSync(SSH_SETTINGS_SCHEMA_VERSION_KEY, SSH_SETTINGS_SCHEMA_VERSION);
      prefs.flushSync();
    } catch (_e) { /* AppStorage remains usable if local persistence is unavailable. */ }
  }

  private publishCloudSetting(key: string, value: CloudUserSettingValue): void {
    try {
      CloudStore.getInstance().upsertUserSetting(key, value);
    } catch (_e) { /* Cloud sync is best effort and cannot block local SSH use. */ }
  }
}
