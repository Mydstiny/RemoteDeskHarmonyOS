import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { settings } from '@kit.BasicServicesKit';
import { inputMethod, InputMethodSubtype } from '@kit.IMEKit';
import {
  decodeRemoteCustomShortcuts,
  encodeRemoteCustomShortcuts,
  RemoteCustomShortcut,
  REMOTE_CUSTOM_SHORTCUT_STORAGE_KEY
} from './RemoteCustomShortcutPolicy';
import {
  defaultRemoteKeyboardPreferences,
  normalizeRemoteKeyboardPreferences,
  normalizeRemoteShortcutPlatform,
  RemoteKeyboardPreferences,
  RemoteShortcutPlatform,
  REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY,
  REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY,
  REMOTE_KEYBOARD_PREFERENCES_NAME,
  REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY,
  REMOTE_KEYBOARD_SIMPLE_MODE_KEY
} from './RemoteKeyboardSettingsPolicy';
import {
  decodeHarmonyShortcutBlockingPreferences,
  defaultHarmonyShortcutBlockingPreferences,
  encodeHarmonyShortcutBlockingPreferences,
  HarmonyShortcutBlockingPreferences,
  HarmonyShortcutDeviceClass,
  HarmonyShortcutProtocol,
  HarmonyShortcutStorageTransactionPort,
  mutateHarmonyShortcutBlockingPreferences,
  HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY
} from './HarmonyShortcutBlockingPolicy';

export interface RemoteSystemInputMethodInfo {
  bundleName: string;
  inputMethodId: string;
  label: string;
  current: boolean;
  enabled: boolean;
  subtypeSummary: string;
}
export interface RemoteSystemInputMethodSnapshot {
  available: boolean;
  currentLabel: string;
  currentSubtype: string;
  methods: Array<RemoteSystemInputMethodInfo>;
  error: string;
}

function inputMethodKey(method: inputMethod.InputMethodProperty): string {
  return method.name + ':' + method.id;
}

function inputMethodLabel(method: inputMethod.InputMethodProperty): string {
  const label: string = method.label ?? '';
  return label.trim().length > 0 ? label.trim() : method.name;
}

function subtypeLabel(subtype: InputMethodSubtype): string {
  const label: string = subtype.label ?? '';
  if (label.trim().length > 0) { return label.trim(); }
  if (subtype.locale.trim().length > 0) { return subtype.locale.trim(); }
  if (subtype.language.trim().length > 0) { return subtype.language.trim(); }
  return subtype.name;
}

function emptySystemSnapshot(error: string = ''): RemoteSystemInputMethodSnapshot {
  return {
    available: false,
    currentLabel: '',
    currentSubtype: '',
    methods: [],
    error
  };
}

class HarmonyShortcutPreferencesPort implements HarmonyShortcutStorageTransactionPort {
  private readonly values: preferences.Preferences;

  constructor(values: preferences.Preferences) {
    this.values = values;
  }

  has(key: string): boolean { return this.values.hasSync(key); }

  get(key: string, fallback: string): string {
    return this.values.getSync(key, fallback) as string;
  }

  put(key: string, value: string): void { this.values.putSync(key, value); }

  delete(key: string): void { this.values.deleteSync(key); }

  flush(): void { this.values.flushSync(); }

  publish(key: string, value: string): void {
    AppStorage.setOrCreate<string>(key, value);
  }
}

export class RemoteKeyboardSettingsService {
  private static instance: RemoteKeyboardSettingsService | null = null;
  private appContext: common.Context | null = null;

  static getInstance(): RemoteKeyboardSettingsService {
    if (RemoteKeyboardSettingsService.instance === null) {
      RemoteKeyboardSettingsService.instance = new RemoteKeyboardSettingsService();
    }
    return RemoteKeyboardSettingsService.instance;
  }

  init(context: common.Context): RemoteKeyboardPreferences {
    this.appContext = context;
    const values: RemoteKeyboardPreferences = this.loadPreferences(context);
    this.publish(values);
    this.publishHarmonyShortcutBlocking(this.loadHarmonyShortcutBlocking(context));
    this.applySimpleKeyboardMode(values.simpleKeyboardEnabled);
    return values;
  }

  loadHarmonyShortcutBlocking(
    context?: common.Context
  ): HarmonyShortcutBlockingPreferences {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) {
      return defaultHarmonyShortcutBlockingPreferences();
    }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      return decodeHarmonyShortcutBlockingPreferences(
        prefs.getSync(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, '') as string);
    } catch (_error) {
      return defaultHarmonyShortcutBlockingPreferences();
    }
  }

  setHarmonyShortcutBlockingPreference(
    deviceClass: HarmonyShortcutDeviceClass,
    protocol: HarmonyShortcutProtocol,
    enabled: boolean,
    context?: common.Context
  ): HarmonyShortcutBlockingPreferences | null {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return null; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      return mutateHarmonyShortcutBlockingPreferences(
        new HarmonyShortcutPreferencesPort(prefs), deviceClass, protocol, enabled);
    } catch (_error) {
      return null;
    }
  }

  setHarmonyShortcutDeviceBlocking(
    deviceClass: HarmonyShortcutDeviceClass,
    enabled: boolean,
    context?: common.Context
  ): HarmonyShortcutBlockingPreferences | null {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return null; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      return mutateHarmonyShortcutBlockingPreferences(
        new HarmonyShortcutPreferencesPort(prefs), deviceClass, null, enabled);
    } catch (_error) {
      return null;
    }
  }

  loadPreferences(context?: common.Context): RemoteKeyboardPreferences {
    const defaults: RemoteKeyboardPreferences = defaultRemoteKeyboardPreferences();
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return defaults; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      return normalizeRemoteKeyboardPreferences(
        prefs.getSync(REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY,
          defaults.shortcutPlatform) as string,
        prefs.getSync(REMOTE_KEYBOARD_SIMPLE_MODE_KEY,
          defaults.simpleKeyboardEnabled) as boolean,
        prefs.getSync(REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY,
          defaults.functionKeysVisible) as boolean,
        prefs.getSync(REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY,
          defaults.closePanelAfterShortcut) as boolean
      );
    } catch (_error) {
      return defaults;
    }
  }

  savePreferences(values: RemoteKeyboardPreferences,
    context?: common.Context): boolean {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return false; }
    const normalized: RemoteKeyboardPreferences = normalizeRemoteKeyboardPreferences(
      values.shortcutPlatform,
      values.simpleKeyboardEnabled,
      values.functionKeysVisible,
      values.closePanelAfterShortcut
    );
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      prefs.putSync(REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY, normalized.shortcutPlatform);
      prefs.putSync(REMOTE_KEYBOARD_SIMPLE_MODE_KEY, normalized.simpleKeyboardEnabled);
      prefs.putSync(REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY, normalized.functionKeysVisible);
      prefs.putSync(REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY, normalized.closePanelAfterShortcut);
      prefs.flushSync();
      this.publish(normalized);
      this.applySimpleKeyboardMode(normalized.simpleKeyboardEnabled);
      return true;
    } catch (_error) {
      return false;
    }
  }

  saveShortcutPlatform(platform: RemoteShortcutPlatform,
    context?: common.Context): boolean {
    const current: RemoteKeyboardPreferences = this.loadPreferences(context);
    current.shortcutPlatform = normalizeRemoteShortcutPlatform(platform);
    return this.savePreferences(current, context);
  }

  loadCustomShortcuts(context?: common.Context): Array<RemoteCustomShortcut> {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return []; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      return decodeRemoteCustomShortcuts(
        prefs.getSync(REMOTE_CUSTOM_SHORTCUT_STORAGE_KEY, '') as string);
    } catch (_error) {
      return [];
    }
  }

  saveCustomShortcuts(shortcuts: Array<RemoteCustomShortcut>,
    context?: common.Context): boolean {
    const activeContext: common.Context | null = context ?? this.appContext;
    if (activeContext === null) { return false; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        activeContext, { name: REMOTE_KEYBOARD_PREFERENCES_NAME });
      prefs.putSync(REMOTE_CUSTOM_SHORTCUT_STORAGE_KEY,
        encodeRemoteCustomShortcuts(shortcuts));
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  private publish(values: RemoteKeyboardPreferences): void {
    AppStorage.setOrCreate<string>(REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY,
      values.shortcutPlatform);
    AppStorage.setOrCreate<boolean>(REMOTE_KEYBOARD_SIMPLE_MODE_KEY,
      values.simpleKeyboardEnabled);
    AppStorage.setOrCreate<boolean>(REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY,
      values.functionKeysVisible);
    AppStorage.setOrCreate<boolean>(REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY,
      values.closePanelAfterShortcut);
  }

  private publishHarmonyShortcutBlocking(
    values: HarmonyShortcutBlockingPreferences
  ): void {
    AppStorage.setOrCreate<string>(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY,
      encodeHarmonyShortcutBlockingPreferences(values));
  }

  private applySimpleKeyboardMode(enabled: boolean): void {
    try {
      inputMethod.setSimpleKeyboardEnabled(enabled);
    } catch (_error) {
      // Some form factors do not expose a software keyboard. The preference
      // remains valid and is applied again when a supported window attaches.
    }
  }

  async readSystemInputMethods(): Promise<RemoteSystemInputMethodSnapshot> {
    try {
      const current: inputMethod.InputMethodProperty = inputMethod.getCurrentInputMethod();
      const currentSubtype: InputMethodSubtype = inputMethod.getCurrentInputMethodSubtype();
      const setting: inputMethod.InputMethodSetting = inputMethod.getSetting();
      const enabledMethods: Array<inputMethod.InputMethodProperty> =
        await setting.getInputMethods(true);
      const allMethods: Array<inputMethod.InputMethodProperty> =
        await setting.getAllInputMethods();
      const enabledKeys: Array<string> = enabledMethods.map(
        (method: inputMethod.InputMethodProperty): string => inputMethodKey(method));
      const currentKey: string = inputMethodKey(current);
      const methods: Array<RemoteSystemInputMethodInfo> = [];
      for (let index: number = 0; index < allMethods.length; index++) {
        const method: inputMethod.InputMethodProperty = allMethods[index];
        let subtypeSummary: string = '';
        try {
          const subtypes: Array<InputMethodSubtype> =
            await setting.listInputMethodSubtype(method);
          const labels: Array<string> = subtypes.map(
            (subtype: InputMethodSubtype): string => subtypeLabel(subtype));
          subtypeSummary = labels.join(' · ');
        } catch (_error) {
          subtypeSummary = '';
        }
        methods.push({
          bundleName: method.name,
          inputMethodId: method.id,
          label: inputMethodLabel(method),
          current: inputMethodKey(method) === currentKey,
          enabled: enabledKeys.indexOf(inputMethodKey(method)) >= 0,
          subtypeSummary
        });
      }
      return {
        available: true,
        currentLabel: inputMethodLabel(current),
        currentSubtype: subtypeLabel(currentSubtype),
        methods,
        error: ''
      };
    } catch (error) {
      return emptySystemSnapshot(JSON.stringify(error));
    }
  }

  openSystemInputMethodSettings(context: common.UIAbilityContext): boolean {
    try {
      settings.openInputMethodSettings(context);
      return true;
    } catch (_error) {
      return false;
    }
  }

  openSystemInputMethodDetail(context: common.UIAbilityContext,
    method: RemoteSystemInputMethodInfo): boolean {
    if (method.bundleName.trim().length === 0 ||
      method.inputMethodId.trim().length === 0) { return false; }
    try {
      settings.openInputMethodDetail(context, method.bundleName, method.inputMethodId);
      return true;
    } catch (_error) {
      return false;
    }
  }
}
