import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  CLOUD_SYNC_SELECTION_PREFERENCE_KEY,
  effectiveCloudSyncTables,
  normalizeCloudSyncSelection,
  runtimeAdmittedCloudSyncSelection
} from './CloudSyncSelectionPolicy';

const PREFS_NAME: string = 'RemoteDesktopAppPrefs';

export class CloudSyncSelectionStore {
  private static instance: CloudSyncSelectionStore;
  private selected: string[] = CLOUD_SYNC_SELECTION_DEFAULT.slice();
  private scopeId: string = 'device-local';
  private runtimeUnavailable: string[] = [];

  static getInstance(): CloudSyncSelectionStore {
    if (!CloudSyncSelectionStore.instance) { CloudSyncSelectionStore.instance = new CloudSyncSelectionStore(); }
    return CloudSyncSelectionStore.instance;
  }

  init(context: common.Context, scopeId: string = 'device-local'): void {
    this.scopeId = scopeId.trim().length > 0 ? scopeId.trim() : 'device-local';
    this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice();
    this.runtimeUnavailable = [];
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored = prefs.getSync(this.preferenceKey(), '') as string;
      if (stored.length === 0) { return; }
      const parsed = JSON.parse(stored) as string[];
      if (Array.isArray(parsed)) { this.selected = normalizeCloudSyncSelection(parsed); }
    } catch (_e) { this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice(); }
  }

  /** Selection visible to the transfer coordinator after runtime admission. */
  selectedBusinessTables(): string[] {
    return runtimeAdmittedCloudSyncSelection(
      this.selected, this.runtimeUnavailable);
  }

  /** Durable user intent, including an optional table awaiting registration. */
  persistedSelectedBusinessTables(): string[] { return this.selected.slice(); }

  effectiveTables(): string[] {
    return effectiveCloudSyncTables(this.selectedBusinessTables());
  }

  setRuntimeTableAvailable(table: string, available: boolean): void {
    const normalized: string = table.trim();
    if (normalized === '') { return; }
    const index: number = this.runtimeUnavailable.indexOf(normalized);
    if (available && index >= 0) { this.runtimeUnavailable.splice(index, 1); }
    else if (!available && index < 0) { this.runtimeUnavailable.push(normalized); }
  }

  replaceSelectedBusinessTables(
    context: common.Context, tables: string[]
  ): boolean {
    const previous: string[] = this.selected.slice();
    this.selected = normalizeCloudSyncSelection(tables);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
      prefs.flushSync();
      return true;
    } catch (_e) {
      // A lifecycle transition must never observe a selection that was not
      // durably committed. Restore both memory and Preferences best-effort.
      this.selected = previous;
      try {
        const prefs = preferences.getPreferencesSync(
          context, { name: PREFS_NAME });
        prefs.putSync(
          this.preferenceKey(), JSON.stringify(previous));
        prefs.flushSync();
      } catch (_restoreError) {}
      return false;
    }
  }

  private preferenceKey(): string {
    return CLOUD_SYNC_SELECTION_PREFERENCE_KEY + ':' + this.scopeId;
  }
}
