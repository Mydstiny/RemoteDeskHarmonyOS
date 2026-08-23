import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AutomaticGuideRuntimeSessionRegistry,
  GUIDE_ALWAYS_VISIBLE_STORAGE_KEY,
  isAutomaticGuideMarkerKey
} from './GuideVisibilityPolicy';

const GUIDE_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';

/** Persists automatic-guide choices locally; guide state never enters cloud sync. */
export class GuideVisibilityService {
  private static instance: GuideVisibilityService | null = null;
  private runtimeSessionRegistry: AutomaticGuideRuntimeSessionRegistry =
    new AutomaticGuideRuntimeSessionRegistry();

  static getInstance(): GuideVisibilityService {
    if (GuideVisibilityService.instance === null) {
      GuideVisibilityService.instance = new GuideVisibilityService();
    }
    return GuideVisibilityService.instance;
  }

  init(context: common.Context): boolean {
    let alwaysVisible: boolean = false;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: GUIDE_PREFERENCES_NAME });
      alwaysVisible = prefs.getSync(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY, false) as boolean;
    } catch (_error) {
      alwaysVisible = false;
    }
    AppStorage.setOrCreate<boolean>(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY, alwaysVisible);
    return alwaysVisible;
  }

  isAlwaysVisible(): boolean {
    return AppStorage.get<boolean>(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY) ?? false;
  }

  setAlwaysVisible(context: common.Context, value: boolean): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: GUIDE_PREFERENCES_NAME });
      prefs.putSync(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY, value);
      prefs.flushSync();
      AppStorage.setOrCreate<boolean>(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY, value);
      return true;
    } catch (_error) {
      return false;
    }
  }

  wasShown(context: common.Context, markerKey: string): boolean {
    if (!isAutomaticGuideMarkerKey(markerKey)) { return true; }
    const runtimeValue: boolean | undefined = AppStorage.get<boolean>(markerKey);
    if (runtimeValue !== undefined) { return runtimeValue; }
    let shown: boolean = false;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: GUIDE_PREFERENCES_NAME });
      shown = prefs.getSync(markerKey, false) as boolean;
    } catch (_error) {
      shown = false;
    }
    AppStorage.setOrCreate<boolean>(markerKey, shown);
    return shown;
  }

  markShown(context: common.Context, markerKey: string): boolean {
    if (!isAutomaticGuideMarkerKey(markerKey)) { return false; }
    // Prevent repetition in the active process even if durable storage is
    // temporarily unavailable. A later successful session can persist it.
    AppStorage.setOrCreate<boolean>(markerKey, true);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: GUIDE_PREFERENCES_NAME });
      prefs.putSync(markerKey, true);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  wasShownInRuntimeSession(markerKey: string, sessionIdentity: string): boolean {
    // A connected surface without an exact identity must fail closed instead
    // of creating an untracked guide that can repeat after a page rebuild.
    return this.runtimeSessionRegistry.wasShown(markerKey, sessionIdentity);
  }

  markShownInRuntimeSession(markerKey: string, sessionIdentity: string): boolean {
    return this.runtimeSessionRegistry.markShown(markerKey, sessionIdentity);
  }
}
