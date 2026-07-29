import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  CLOUD_SYNC_SELECTION_PREFERENCE_KEY,
  effectiveCloudSyncTables,
  normalizeCloudSyncSelection
} from './CloudSyncSelectionPolicy';

const PREFS_NAME: string = 'RemoteDesktopAppPrefs';

export class CloudSyncSelectionStore {
  private static instance: CloudSyncSelectionStore;
  private selected: string[] = CLOUD_SYNC_SELECTION_DEFAULT.slice();
  private scopeId: string = 'device-local';

  static getInstance(): CloudSyncSelectionStore {
    if (!CloudSyncSelectionStore.instance) { CloudSyncSelectionStore.instance = new CloudSyncSelectionStore(); }
    return CloudSyncSelectionStore.instance;
  }

  init(context: common.Context, scopeId: string = 'device-local'): void {
    this.scopeId = scopeId.trim().length > 0 ? scopeId.trim() : 'device-local';
    this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice();
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored = prefs.getSync(this.preferenceKey(), '') as string;
      if (stored.length === 0) { return; }
      const parsed = JSON.parse(stored) as string[];
      if (Array.isArray(parsed)) { this.selected = normalizeCloudSyncSelection(parsed); }
    } catch (_e) { this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice(); }
  }

  selectedBusinessTables(): string[] { return this.selected.slice(); }

  effectiveTables(): string[] { return effectiveCloudSyncTables(this.selected); }

  replaceSelectedBusinessTables(context: common.Context, tables: string[]): void {
    this.selected = normalizeCloudSyncSelection(tables);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
      prefs.flushSync();
    } catch (_e) { /* memory state remains usable */ }
  }

  private preferenceKey(): string {
    return CLOUD_SYNC_SELECTION_PREFERENCE_KEY + ':' + this.scopeId;
  }
}
