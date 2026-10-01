import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  applyRemotePortraitDisplayPreferenceUpdate,
  decodeRemotePortraitDisplayPreferences,
  defaultRemotePortraitDisplayPreferences,
  MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY,
  MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY,
  normalizeRemotePortraitDisplayMode,
  RemotePortraitDisplayPreferences,
  RemotePortraitDisplayPreferencePresence,
  RemotePortraitDisplayPreferenceUpdate,
  RemotePortraitDisplayMode,
  REMOTE_PORTRAIT_DISPLAY_ENCODED_KEY,
  REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION,
  REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION_KEY,
  REMOTE_PORTRAIT_DISPLAY_REVISION_KEY,
  RDP_PORTRAIT_DISPLAY_ENABLED_KEY,
  RDP_PORTRAIT_DISPLAY_MODE_KEY,
  RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY,
  RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY,
  VNC_PORTRAIT_DISPLAY_ENABLED_KEY,
  VNC_PORTRAIT_DISPLAY_MODE_KEY,
  migrateRemotePortraitDisplayPreferences
} from './RemotePortraitDisplayPreferencePolicy';

const PREFS_NAME: string = 'RemoteDesktopAppPrefs';

export interface RemotePortraitDisplaySnapshot {
  values: RemotePortraitDisplayPreferences;
  revision: number;
}

function finiteRevision(value: Object): number {
  return typeof value === 'number' && Number.isSafeInteger(value as number) &&
    (value as number) >= 0 ? value as number : 0;
}

function readValues(prefs: preferences.Preferences): RemotePortraitDisplayPreferences {
  const encoded: string = prefs.getSync(REMOTE_PORTRAIT_DISPLAY_ENCODED_KEY, '') as string;
  const decoded: RemotePortraitDisplayPreferences = decodeRemotePortraitDisplayPreferences(encoded);
  const hasEncoded: boolean = encoded.trim().length > 0;
  const current: RemotePortraitDisplayPreferences = {
    rdp: {
      enabled: prefs.getSync(RDP_PORTRAIT_DISPLAY_ENABLED_KEY, hasEncoded ? decoded.rdp.enabled : false) as boolean,
      mode: normalizeRemotePortraitDisplayMode(
        prefs.getSync(RDP_PORTRAIT_DISPLAY_MODE_KEY, hasEncoded ? decoded.rdp.mode : 'default') as string)
    },
    rustdesk: {
      enabled: prefs.getSync(RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY, hasEncoded ? decoded.rustdesk.enabled : false) as boolean,
      mode: normalizeRemotePortraitDisplayMode(
        prefs.getSync(RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY, hasEncoded ? decoded.rustdesk.mode : 'default') as string)
    },
    vnc: {
      enabled: prefs.getSync(VNC_PORTRAIT_DISPLAY_ENABLED_KEY, hasEncoded ? decoded.vnc.enabled : false) as boolean,
      mode: normalizeRemotePortraitDisplayMode(
        prefs.getSync(VNC_PORTRAIT_DISPLAY_MODE_KEY, hasEncoded ? decoded.vnc.mode : 'default') as string)
    },
    moonlight: {
      enabled: prefs.getSync(MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY, hasEncoded ? decoded.moonlight.enabled : false) as boolean,
      mode: normalizeRemotePortraitDisplayMode(
        prefs.getSync(MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY, hasEncoded ? decoded.moonlight.mode : 'default') as string)
    }
  };
  return current;
}

function presence(prefs: preferences.Preferences): RemotePortraitDisplayPreferencePresence {
  return {
    rdpEnabled: prefs.hasSync(RDP_PORTRAIT_DISPLAY_ENABLED_KEY),
    rdpMode: prefs.hasSync(RDP_PORTRAIT_DISPLAY_MODE_KEY),
    rustdeskEnabled: prefs.hasSync(RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY),
    rustdeskMode: prefs.hasSync(RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY),
    vncEnabled: prefs.hasSync(VNC_PORTRAIT_DISPLAY_ENABLED_KEY),
    vncMode: prefs.hasSync(VNC_PORTRAIT_DISPLAY_MODE_KEY),
    moonlightEnabled: prefs.hasSync(MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY),
    moonlightMode: prefs.hasSync(MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY)
  };
}

function encoded(values: RemotePortraitDisplayPreferences): string {
  return JSON.stringify(values);
}

function writeValues(prefs: preferences.Preferences,
  values: RemotePortraitDisplayPreferences): void {
  prefs.putSync(RDP_PORTRAIT_DISPLAY_ENABLED_KEY, values.rdp.enabled);
  prefs.putSync(RDP_PORTRAIT_DISPLAY_MODE_KEY, values.rdp.mode);
  prefs.putSync(RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY, values.rustdesk.enabled);
  prefs.putSync(RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY, values.rustdesk.mode);
  prefs.putSync(VNC_PORTRAIT_DISPLAY_ENABLED_KEY, values.vnc.enabled);
  prefs.putSync(VNC_PORTRAIT_DISPLAY_MODE_KEY, values.vnc.mode);
  prefs.putSync(MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY, values.moonlight.enabled);
  prefs.putSync(MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY, values.moonlight.mode);
  prefs.putSync(REMOTE_PORTRAIT_DISPLAY_ENCODED_KEY, encoded(values));
  prefs.putSync(REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION_KEY,
    REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION);
}

function publish(snapshot: RemotePortraitDisplaySnapshot): void {
  const values: RemotePortraitDisplayPreferences = snapshot.values;
  AppStorage.setOrCreate(RDP_PORTRAIT_DISPLAY_ENABLED_KEY, values.rdp.enabled);
  AppStorage.setOrCreate(RDP_PORTRAIT_DISPLAY_MODE_KEY, values.rdp.mode);
  AppStorage.setOrCreate(RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY, values.rustdesk.enabled);
  AppStorage.setOrCreate(RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY, values.rustdesk.mode);
  AppStorage.setOrCreate(VNC_PORTRAIT_DISPLAY_ENABLED_KEY, values.vnc.enabled);
  AppStorage.setOrCreate(VNC_PORTRAIT_DISPLAY_MODE_KEY, values.vnc.mode);
  AppStorage.setOrCreate(MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY, values.moonlight.enabled);
  AppStorage.setOrCreate(MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY, values.moonlight.mode);
  AppStorage.setOrCreate(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, snapshot.revision);
}

function emptyTouched(): RemotePortraitDisplayPreferencePresence {
  return {
    rdpEnabled: false, rdpMode: false, rustdeskEnabled: false, rustdeskMode: false,
    vncEnabled: false, vncMode: false, moonlightEnabled: false, moonlightMode: false
  };
}

export class RemotePortraitDisplayStore {
  private static instance: RemotePortraitDisplayStore | null = null;

  static getInstance(): RemotePortraitDisplayStore {
    if (RemotePortraitDisplayStore.instance === null) {
      RemotePortraitDisplayStore.instance = new RemotePortraitDisplayStore();
    }
    return RemotePortraitDisplayStore.instance;
  }

  load(context: common.Context): RemotePortraitDisplaySnapshot {
    const defaults: RemotePortraitDisplayPreferences = defaultRemotePortraitDisplayPreferences();
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: PREFS_NAME });
      const current: RemotePortraitDisplayPreferences = readValues(prefs);
      const migrated: RemotePortraitDisplayPreferences =
        migrateRemotePortraitDisplayPreferences(current, presence(prefs),
          prefs.getSync(REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION_KEY, 0) as number);
      const revision: number = finiteRevision(
        prefs.getSync(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, 0) as Object);
      const shouldPersist: boolean = !prefs.hasSync(REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION_KEY) ||
        !prefs.hasSync(RDP_PORTRAIT_DISPLAY_ENABLED_KEY) ||
        !prefs.hasSync(RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY) ||
        !prefs.hasSync(VNC_PORTRAIT_DISPLAY_ENABLED_KEY) ||
        !prefs.hasSync(MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY) ||
        JSON.stringify(current) !== JSON.stringify(migrated);
      if (shouldPersist) {
        writeValues(prefs, migrated);
        prefs.putSync(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, revision);
        prefs.flushSync();
      }
      const snapshot: RemotePortraitDisplaySnapshot = { values: migrated, revision };
      publish(snapshot);
      return snapshot;
    } catch (_error) {
      const snapshot: RemotePortraitDisplaySnapshot = { values: defaults, revision: 0 };
      publish(snapshot);
      return snapshot;
    }
  }

  savePatch(context: common.Context,
    update: RemotePortraitDisplayPreferenceUpdate): boolean {
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: PREFS_NAME });
      const previous: RemotePortraitDisplayPreferences = readValues(prefs);
      const current: RemotePortraitDisplayPreferences = applyRemotePortraitDisplayPreferenceUpdate(
        previous, update);
      const previousRevision: number = finiteRevision(
        prefs.getSync(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, 0) as Object);
      const nextRevision: number = previousRevision >= Number.MAX_SAFE_INTEGER ?
        1 : previousRevision + 1;
      try {
        writeValues(prefs, current);
        prefs.putSync(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, nextRevision);
        prefs.flushSync();
      } catch (_writeError) {
        try {
          writeValues(prefs, previous);
          prefs.putSync(REMOTE_PORTRAIT_DISPLAY_REVISION_KEY, previousRevision);
          prefs.flushSync();
        } catch (_rollbackError) {}
        return false;
      }
      publish({ values: current, revision: nextRevision });
      return true;
    } catch (_error) {
      return false;
    }
  }

  setProtocolEnabled(context: common.Context,
    protocol: 'rdp' | 'rustdesk' | 'vnc' | 'moonlight', enabled: boolean): boolean {
    const current: RemotePortraitDisplaySnapshot = this.load(context);
    const values: RemotePortraitDisplayPreferences = JSON.parse(JSON.stringify(current.values)) as RemotePortraitDisplayPreferences;
    const touched: RemotePortraitDisplayPreferencePresence = emptyTouched();
    if (protocol === 'rdp') { values.rdp.enabled = enabled; touched.rdpEnabled = true; }
    if (protocol === 'rustdesk') { values.rustdesk.enabled = enabled; touched.rustdeskEnabled = true; }
    if (protocol === 'vnc') { values.vnc.enabled = enabled; touched.vncEnabled = true; }
    if (protocol === 'moonlight') { values.moonlight.enabled = enabled; touched.moonlightEnabled = true; }
    return this.savePatch(context, { values, touched });
  }

  setProtocolMode(context: common.Context,
    protocol: 'rdp' | 'rustdesk' | 'vnc' | 'moonlight', mode: RemotePortraitDisplayMode): boolean {
    const current: RemotePortraitDisplaySnapshot = this.load(context);
    const values: RemotePortraitDisplayPreferences = JSON.parse(JSON.stringify(current.values)) as RemotePortraitDisplayPreferences;
    const touched: RemotePortraitDisplayPreferencePresence = emptyTouched();
    if (protocol === 'rdp') { values.rdp.mode = mode; touched.rdpMode = true; }
    if (protocol === 'rustdesk') { values.rustdesk.mode = mode; touched.rustdeskMode = true; }
    if (protocol === 'vnc') { values.vnc.mode = mode; touched.vncMode = true; }
    if (protocol === 'moonlight') { values.moonlight.mode = mode; touched.moonlightMode = true; }
    return this.savePatch(context, { values, touched });
  }
}
