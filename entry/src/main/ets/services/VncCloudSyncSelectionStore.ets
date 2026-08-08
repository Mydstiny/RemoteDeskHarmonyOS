import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  VNC_CLOUD_SYNC_SELECTION_DEFAULT,
  VNC_CLOUD_SYNC_SELECTION_KEY,
  VncCloudSyncScope,
  hasVncCloudSyncBusinessSelection,
  isVncRecordTypeSelected,
  normalizeVncCloudSyncSelection,
  vncSecretSyncAllowed,
  vncSyncNeedsCrypto
} from './VncCloudSyncSelectionPolicy';
import { VncRecordType } from '../model/VncRecord';

const PREFS_NAME: string = 'RemoteDesktopVncPrefs';

/**
 * Compatibility storage for the retired VNC logical selector. Runtime
 * selection is always the complete VNC record set; the ordinary physical-table
 * selector is the only cloud-transfer switch.
 */
export class VncCloudSyncSelectionStore {
  private static instance: VncCloudSyncSelectionStore;
  private selected: VncCloudSyncScope[] = VNC_CLOUD_SYNC_SELECTION_DEFAULT.slice();
  private scopeId: string = 'device-local';

  static getInstance(): VncCloudSyncSelectionStore {
    if (!VncCloudSyncSelectionStore.instance) {
      VncCloudSyncSelectionStore.instance = new VncCloudSyncSelectionStore();
    }
    return VncCloudSyncSelectionStore.instance;
  }

  init(context: common.Context, scopeId: string = 'device-local'): void {
    this.scopeId = scopeId.trim().length > 0 ? scopeId.trim() : 'device-local';
    this.selected = VNC_CLOUD_SYNC_SELECTION_DEFAULT.slice();
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored: string = prefs.getSync(this.preferenceKey(), '') as string;
      if (stored !== '') {
        const parsed: string[] = JSON.parse(stored) as string[];
        if (Array.isArray(parsed)) {
          this.selected = normalizeVncCloudSyncSelection(parsed);
        }
      }
      // Best-effort canonicalization retires empty/partial legacy values. A
      // Preferences failure cannot disable VNC records in memory or login.
      prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
      prefs.flushSync();
    } catch (_e) {
      this.selected = VNC_CLOUD_SYNC_SELECTION_DEFAULT.slice();
    }
  }

  selectedScopes(): VncCloudSyncScope[] { return this.selected.slice(); }

  hasSelection(): boolean { return hasVncCloudSyncBusinessSelection(this.selected); }

  isRecordTypeSelected(recordType: VncRecordType): boolean {
    return isVncRecordTypeSelected(recordType, this.selected);
  }

  secretsAllowed(cryptoReady: boolean = false): boolean {
    return vncSecretSyncAllowed(this.selected, cryptoReady);
  }

  needsCrypto(cryptoConfigured: boolean = true): boolean {
    return vncSyncNeedsCrypto(this.selected, cryptoConfigured);
  }

  /** Stage a scope change in memory without touching durable Preferences. */
  stageSelectedScopes(scopes: string[]): void {
    this.selected = normalizeVncCloudSyncSelection(scopes);
  }

  /** Persist the already-staged scope after its RDB projection succeeds. */
  persistSelectedScopes(context: common.Context): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      prefs.putSync(this.preferenceKey(), JSON.stringify(this.selected));
      prefs.flushSync();
      return true;
    } catch (_e) {
      return false;
    }
  }

  replaceSelectedScopes(context: common.Context, scopes: string[]): boolean {
    const previous: VncCloudSyncScope[] = this.selected.slice();
    const next: VncCloudSyncScope[] = normalizeVncCloudSyncSelection(scopes);
    this.selected = next;
    if (this.persistSelectedScopes(context)) { return true; }
    // Runtime still retains the complete physical-table projection. Preserve
    // the prior value only for API compatibility if durable Preferences fail.
    this.selected = previous;
    this.persistSelectedScopes(context);
    return false;
  }

  private preferenceKey(): string {
    return VNC_CLOUD_SYNC_SELECTION_KEY + ':' + this.scopeId;
  }
}
