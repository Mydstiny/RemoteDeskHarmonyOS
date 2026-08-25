import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MOONLIGHT_CLOUD_TABLE } from '../model/MoonlightRecord';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  CLOUD_SYNC_SELECTION_PREFERENCE_KEY,
  effectiveCloudSyncTables,
  normalizeCloudSyncSelection,
  runtimeAdmittedCloudSyncSelection,
  upgradeLegacyCloudSyncSelection
} from './CloudSyncSelectionPolicy';

const PREFS_NAME: string = 'RemoteDesktopAppPrefs';
const MOONLIGHT_AUTO_ENABLE_MIGRATION_KEY: string =
  'moonlightCloudTableAutoEnableV1';
const MOONLIGHT_EXPLICIT_DISABLE_KEY: string =
  'moonlightCloudTableExplicitlyDisabledV1';

export class CloudSyncSelectionStore {
  private static instance: CloudSyncSelectionStore;
  private selected: string[] = CLOUD_SYNC_SELECTION_DEFAULT.slice();
  private scopeId: string = 'device-local';
  private runtimeUnavailable: string[] = [];
  private moonlightExplicitlyDisabled: boolean = false;

  static getInstance(): CloudSyncSelectionStore {
    if (!CloudSyncSelectionStore.instance) { CloudSyncSelectionStore.instance = new CloudSyncSelectionStore(); }
    return CloudSyncSelectionStore.instance;
  }

  init(context: common.Context, scopeId: string = 'device-local'): void {
    this.scopeId = scopeId.trim().length > 0 ? scopeId.trim() : 'device-local';
    this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice();
    this.runtimeUnavailable = [];
    this.moonlightExplicitlyDisabled = false;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored = prefs.getSync(this.preferenceKey(), '') as string;
      let storedSelection: string[] = [];
      if (stored.length > 0) {
        const parsed = JSON.parse(stored) as string[];
        if (Array.isArray(parsed)) {
          storedSelection = normalizeCloudSyncSelection(parsed);
        }
      }
      const migrationKey: string = this.moonlightMigrationKey();
      const migrated: boolean =
        (prefs.getSync(migrationKey, '') as string) === '1';
      this.moonlightExplicitlyDisabled =
        (prefs.getSync(this.moonlightExplicitDisableKey(), '') as string) ===
          '1';
      this.selected = this.moonlightExplicitlyDisabled ?
        storedSelection.filter((table: string): boolean =>
          table !== MOONLIGHT_CLOUD_TABLE) :
        upgradeLegacyCloudSyncSelection(storedSelection, migrated);
      const selectionChanged: boolean =
        storedSelection.join(',') !== this.selected.join(',');
      if (!migrated || selectionChanged) {
        // Best effort only. Runtime immediately uses the complete upgraded
        // selection; a Preferences failure is retried on the next activation
        // and must never invalidate the account RDB or legacy cloud tables.
        try {
          prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
          prefs.putSync(migrationKey, '1');
          prefs.flushSync();
        } catch (_migrationError) {}
      }
    } catch (_e) { this.selected = CLOUD_SYNC_SELECTION_DEFAULT.slice(); }
  }

  /** Selection visible to the transfer coordinator after runtime admission. */
  selectedBusinessTables(): string[] {
    return runtimeAdmittedCloudSyncSelection(
      this.selected, this.runtimeUnavailable);
  }

  /** Durable user intent, including an optional table awaiting registration. */
  persistedSelectedBusinessTables(): string[] { return this.selected.slice(); }

  moonlightCloudTableExplicitlyDisabled(): boolean {
    return this.moonlightExplicitlyDisabled;
  }

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
    const normalized: string[] = normalizeCloudSyncSelection(tables);
    // Ordinary core-table edits can never silently turn Moonlight off. A
    // previously explicit whole-category stop is preserved until a caller
    // explicitly includes Moonlight again.
    const explicitlyReenabled: boolean =
      normalized.indexOf(MOONLIGHT_CLOUD_TABLE) >= 0;
    const nextExplicitlyDisabled: boolean =
      this.moonlightExplicitlyDisabled && !explicitlyReenabled;
    const next: string[] = nextExplicitlyDisabled ?
      normalized.filter((table: string): boolean =>
        table !== MOONLIGHT_CLOUD_TABLE) :
      upgradeLegacyCloudSyncSelection(normalized, true);
    return this.persistSelection(
      context, next, nextExplicitlyDisabled);
  }

  explicitlyDisableMoonlightCloudTable(
    context: common.Context
  ): boolean {
    const next: string[] = this.selected.filter(
      (table: string): boolean => table !== MOONLIGHT_CLOUD_TABLE);
    return this.persistSelection(context, next, true);
  }

  private persistSelection(
    context: common.Context,
    next: string[],
    moonlightExplicitlyDisabled: boolean
  ): boolean {
    const previous: string[] = this.selected.slice();
    const previousExplicitlyDisabled: boolean =
      this.moonlightExplicitlyDisabled;
    this.selected = normalizeCloudSyncSelection(next);
    this.moonlightExplicitlyDisabled = moonlightExplicitlyDisabled;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
      // Any explicit post-upgrade edit, including the destructive Moonlight
      // stop flow, is newer than the compatibility migration and must not be
      // mistaken for a pre-Moonlight preference on the next process start.
      prefs.putSync(this.moonlightMigrationKey(), '1');
      prefs.putSync(this.moonlightExplicitDisableKey(),
        this.moonlightExplicitlyDisabled ? '1' : '0');
      prefs.flushSync();
      return true;
    } catch (_e) {
      // A lifecycle transition must never observe a selection that was not
      // durably committed. Restore both memory and Preferences best-effort.
      this.selected = previous;
      this.moonlightExplicitlyDisabled = previousExplicitlyDisabled;
      try {
        const prefs = preferences.getPreferencesSync(
          context, { name: PREFS_NAME });
        prefs.putSync(
          this.preferenceKey(), JSON.stringify(previous));
        prefs.putSync(this.moonlightMigrationKey(), '1');
        prefs.putSync(this.moonlightExplicitDisableKey(),
          previousExplicitlyDisabled ? '1' : '0');
        prefs.flushSync();
      } catch (_restoreError) {}
      return false;
    }
  }

  private preferenceKey(): string {
    return CLOUD_SYNC_SELECTION_PREFERENCE_KEY + ':' + this.scopeId;
  }

  private moonlightMigrationKey(): string {
    return MOONLIGHT_AUTO_ENABLE_MIGRATION_KEY + ':' + this.scopeId;
  }

  private moonlightExplicitDisableKey(): string {
    return MOONLIGHT_EXPLICIT_DISABLE_KEY + ':' + this.scopeId;
  }
}
