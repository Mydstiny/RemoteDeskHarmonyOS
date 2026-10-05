import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { PasskeyUnlock } from './ProPasskeyKeys';

/** Metadata of one passkey held by this device. The private key itself lives only in HUKS under `alias`. */
export interface PasskeyRecord {
  owner: string;
  id: string;          // credential ID, base64url
  rpId: string;
  userId: string;      // user handle, base64url
  userName: string;
  displayName: string;
  alias: string;
  unlock: PasskeyUnlock;
  signCount: number;
  createdAt: number;
  lastUsedAt: number;
}

const PREFERENCE_KEY: string = 'proPasskeysV1';
const MAX_RECORDS: number = 100;

function valid(item: Object): boolean {
  if (item === null || typeof item !== 'object' || Array.isArray(item)) { return false; }
  const r = item as Record<string, Object>;
  return typeof r['owner'] === 'string' && typeof r['id'] === 'string' && typeof r['rpId'] === 'string' &&
    typeof r['userId'] === 'string' && typeof r['userName'] === 'string' && typeof r['displayName'] === 'string' &&
    typeof r['alias'] === 'string' && (r['unlock'] === 'biometric' || r['unlock'] === 'pin') &&
    typeof r['signCount'] === 'number' && typeof r['createdAt'] === 'number' && typeof r['lastUsedAt'] === 'number';
}

/** Passkeys of this device, per account scope. Local only: never synced, exported or written into host rows. */
export class ProPasskeyStore {
  private static store(context: common.Context): preferences.Preferences | null {
    try { return preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' }); }
    catch (_error) { return null; }
  }

  private static readAll(context: common.Context): PasskeyRecord[] {
    const store = ProPasskeyStore.store(context);
    if (store === null) { return []; }
    try {
      const parsed: Object = JSON.parse(store.getSync(PREFERENCE_KEY, '[]') as string) as Object;
      return Array.isArray(parsed) ? (parsed as Object[]).filter(valid).map((item: Object): PasskeyRecord =>
        item as PasskeyRecord) : [];
    } catch (_error) {
      return [];
    }
  }

  private static writeAll(context: common.Context, records: PasskeyRecord[]): void {
    const store = ProPasskeyStore.store(context);
    if (store === null) { throw new Error('PASSKEY_STORE_UNAVAILABLE'); }
    try {
      store.putSync(PREFERENCE_KEY, JSON.stringify(records.slice(Math.max(0, records.length - MAX_RECORDS))));
      store.flushSync();
    } catch (_error) {
      throw new Error('PASSKEY_STORE_UNAVAILABLE');
    }
  }

  static list(context: common.Context, owner: string): PasskeyRecord[] {
    return ProPasskeyStore.readAll(context).filter((record: PasskeyRecord): boolean => record.owner === owner)
      .sort((a: PasskeyRecord, b: PasskeyRecord): number => b.lastUsedAt - a.lastUsedAt);
  }

  static forRp(context: common.Context, owner: string, rpId: string): PasskeyRecord[] {
    return ProPasskeyStore.list(context, owner).filter((record: PasskeyRecord): boolean => record.rpId === rpId);
  }

  static save(context: common.Context, record: PasskeyRecord): void {
    const records = ProPasskeyStore.readAll(context).filter((item: PasskeyRecord): boolean =>
      !(item.owner === record.owner && item.id === record.id));
    records.push(record);
    ProPasskeyStore.writeAll(context, records);
  }

  static remove(context: common.Context, owner: string, id: string): PasskeyRecord | null {
    const records = ProPasskeyStore.readAll(context);
    const found = records.find((item: PasskeyRecord): boolean => item.owner === owner && item.id === id);
    if (found === undefined) { return null; }
    ProPasskeyStore.writeAll(context, records.filter((item: PasskeyRecord): boolean => item !== found));
    return found;
  }
}
