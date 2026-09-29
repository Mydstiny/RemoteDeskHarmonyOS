import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ProFeature, proFeatures } from './ProFeatureCatalog';

const PRO_FEATURE_VISIBILITY_KEY: string = 'proFeatureVisibilityV1';

/** User controlled catalog visibility. Missing ids stay visible so new Pro features are safe by default. */
export class ProFeatureVisibility {
  private static instance: ProFeatureVisibility | null = null;
  private values: Record<string, boolean> = {};
  private loaded: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): ProFeatureVisibility {
    if (ProFeatureVisibility.instance === null) {
      ProFeatureVisibility.instance = new ProFeatureVisibility();
    }
    return ProFeatureVisibility.instance;
  }

  load(context: common.UIAbilityContext): void {
    if (this.loaded) { return; }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: 'RemoteDesktopAppPrefs' });
      const raw: string = prefs.getSync(PRO_FEATURE_VISIBILITY_KEY, '{}') as string;
      const parsed: Record<string, boolean> = JSON.parse(raw) as Record<string, boolean>;
      if (parsed !== null && typeof parsed === 'object') {
        Object.keys(parsed).forEach((id: string): void => {
          if (typeof parsed[id] === 'boolean') { this.values[id] = parsed[id]; }
        });
      }
    } catch (_error) {
      this.values = {};
    }
    this.loaded = true;
    this.publish();
  }

  // Fail closed before the app has loaded preferences. Once loaded, missing
  // ids are visible so newly catalogued Pro features remain discoverable.
  isVisible(id: string): boolean { return this.loaded && this.values[id] !== false; }

  setVisible(context: common.UIAbilityContext, id: string, visible: boolean): boolean {
    this.load(context);
    const previous: boolean | undefined = this.values[id];
    this.values[id] = visible;
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(PRO_FEATURE_VISIBILITY_KEY, JSON.stringify(this.values));
      prefs.flushSync();
      this.publish();
      return true;
    } catch (_error) {
      this.values[id] = previous === undefined ? true : previous;
      return false;
    }
  }

  proCatalog(): ProFeature[] {
    return proFeatures().filter((feature: ProFeature): boolean => feature.requiredEntitlementId.length > 0);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    listener();
    return (): void => {
      this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
    };
  }

  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* A closing surface cannot block other owners. */ }
    });
  }
}
