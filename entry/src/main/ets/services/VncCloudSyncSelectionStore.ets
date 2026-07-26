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

/** VNC-only selection storage. It never reads the ordinary cloud selector. */
export class VncCloudSyncSelectionStore {
  private static instance: VncCloudSyncSelectionStore;
  private selected: VncCloudSyncScope[] = VNC_CLOUD_SYNC_SELECTION_DEFAULT.slice();

  static getInstance(): VncCloudSyncSelectionStore {
    if (!VncCloudSyncSelectionStore.instance) {
      VncCloudSyncSelectionStore.instance = new VncCloudSyncSelectionStore();
    }
    return VncCloudSyncSelectionStore.instance;
  }

  init(context: common.Context): void {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored: string = prefs.getSync(VNC_CLOUD_SYNC_SELECTION_KEY, '') as string;
      if (stored === '') { return; }
      const parsed: string[] = JSON.parse(stored) as string[];
      if (Array.isArray(parsed)) {
        this.selected = normalizeVncCloudSyncSelection(parsed);
      }
    } catch (_e) {
      this.selected = VNC_CLOUD_SYNC_SELECTION_DEFAULT.slice();
    }
  }

  selectedScopes(): VncCloudSyncScope[] { return this.selected.slice(); }

  hasSelection(): boolean { return hasVncCloudSyncBusinessSelection(this.selected); }

  isRecordTypeSelected(recordType: VncRecordType): boolean {
    return isVncRecordTypeSelected(recordType, this.selected);
  }

  secretsAllowed(cryptoReady: boolean): boolean {
    return vncSecretSyncAllowed(this.selected, cryptoReady);
  }

  needsCrypto(): boolean { return vncSyncNeedsCrypto(this.selected); }

  replaceSelectedScopes(context: common.Context, scopes: string[]): void {
    this.selected = normalizeVncCloudSyncSelection(scopes);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      prefs.putSync(VNC_CLOUD_SYNC_SELECTION_KEY, JSON.stringify(this.selected));
      prefs.flushSync();
    } catch (_e) {
      // Keep the in-memory selection usable until the next app start.
    }
  }
}
