import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREFERENCE_KEY: string = 'rdpSecurityKeyHostsV1';
const MAX_ENTRIES: number = 500;

function entryOf(ownerScopeId: string, hostId: string): string { return ownerScopeId + '|' + hostId; }

function read(store: preferences.Preferences): string[] {
  try {
    const parsed: Object = JSON.parse(store.getSync(PREFERENCE_KEY, '[]') as string) as Object;
    return Array.isArray(parsed) ? (parsed as Object[]).filter((item: Object): boolean =>
      typeof item === 'string' && (item as string).length <= 300).map((item: Object): string => item as string) : [];
  } catch (_error) {
    return [];
  }
}

/**
 * Which RDP hosts redirect a USB security key on this device. Device-local only: never synced, backed up or
 * written into the host row, and keyed by the account scope so another account never inherits the choice.
 */
export class ProRdpSecurityKeyPreference {
  static enabled(context: common.Context, ownerScopeId: string, hostId: string): boolean {
    if (ownerScopeId === '' || hostId === '') { return false; }
    try {
      const store = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      return read(store).indexOf(entryOf(ownerScopeId, hostId)) >= 0;
    } catch (_error) {
      return false;
    }
  }

  static set(context: common.Context, ownerScopeId: string, hostId: string, enabled: boolean): boolean {
    if (ownerScopeId === '' || hostId === '') { return false; }
    try {
      const store = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      const entry = entryOf(ownerScopeId, hostId);
      const next = read(store).filter((item: string): boolean => item !== entry);
      if (enabled) { next.push(entry); }
      store.putSync(PREFERENCE_KEY, JSON.stringify(next.slice(Math.max(0, next.length - MAX_ENTRIES))));
      store.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }
}
