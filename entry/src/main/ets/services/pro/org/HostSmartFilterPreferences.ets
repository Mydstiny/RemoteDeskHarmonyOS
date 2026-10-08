import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HOST_SMART_FILTER_KINDS, parseHostFilterKey } from './HostOrganizationPolicy';

const SMART_FILTER_PREFS_KEY: string = 'proHostSmartFilters';
/** Bumped when the chosen smart chips change so the home bar re-renders. */
export const HOST_SMART_FILTER_REVISION_KEY: string = 'proHostSmartFilterRevision';
const MAX_SMART_FILTERS: number = 24;

/** Device-local choice of which smart chips (recent, online, protocol, subnet, tag …) the home bar shows. */
export class HostSmartFilterPreferences {
  private static instance: HostSmartFilterPreferences | null = null;
  private keys: string[] = HOST_SMART_FILTER_KINDS.slice();
  private loaded: boolean = false;

  static getInstance(): HostSmartFilterPreferences {
    if (HostSmartFilterPreferences.instance === null) {
      HostSmartFilterPreferences.instance = new HostSmartFilterPreferences();
    }
    return HostSmartFilterPreferences.instance;
  }

  load(context: common.Context): void {
    if (this.loaded) { return; }
    this.loaded = true;
    try {
      const raw = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' })
        .getSync(SMART_FILTER_PREFS_KEY, '') as string;
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: string[] = JSON.parse(raw) as string[];
        if (Array.isArray(parsed)) { this.keys = this.clean(parsed); }
      }
    } catch (_error) {
      this.keys = HOST_SMART_FILTER_KINDS.slice();
    }
  }

  list(): string[] { return this.keys.slice(); }
  has(key: string): boolean { return this.keys.indexOf(key) >= 0; }

  toggle(context: common.Context, key: string, on: boolean): void {
    const next: string[] = on ? this.keys.concat([key]) : this.keys.filter((item: string): boolean => item !== key);
    this.keys = this.clean(next);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(SMART_FILTER_PREFS_KEY, JSON.stringify(this.keys));
      prefs.flushSync();
    } catch (_error) {}
    AppStorage.setOrCreate(HOST_SMART_FILTER_REVISION_KEY,
      (AppStorage.get<number>(HOST_SMART_FILTER_REVISION_KEY) ?? 0) + 1);
  }

  private clean(keys: string[]): string[] {
    const result: string[] = [];
    keys.forEach((key: string): void => {
      if (typeof key !== 'string' || key.length > 80) { return; }
      const filter = parseHostFilterKey(key);
      if (filter.kind === 'all' || filter.kind === 'group' || result.indexOf(key) >= 0) { return; }
      if (result.length < MAX_SMART_FILTERS) { result.push(key); }
    });
    return result;
  }
}
