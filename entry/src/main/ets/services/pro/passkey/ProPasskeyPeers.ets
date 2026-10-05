import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** A device the user paired with this phone: only its signed requests are shown. */
export interface PasskeyPeer {
  owner: string;
  /** passkeyDeviceId of its public key */
  id: string;
  /** Name shown when it asks; taken from the pairing request the user confirmed */
  name: string;
  /** SPKI, base64url */
  publicKey: string;
  pairedAt: number;
  lastUsedAt: number;
}

const PREFERENCE_KEY: string = 'proPasskeyPeersV1';
const RECEIVE_KEY: string = 'proPasskeyReceiveV1';
const MAX_PEERS: number = 20;

function valid(item: Object): boolean {
  if (item === null || typeof item !== 'object' || Array.isArray(item)) { return false; }
  const r = item as Record<string, Object>;
  return typeof r['owner'] === 'string' && typeof r['id'] === 'string' && typeof r['name'] === 'string' &&
    typeof r['publicKey'] === 'string' && typeof r['pairedAt'] === 'number' && typeof r['lastUsedAt'] === 'number';
}

/** Paired devices and the receive switch, per account scope. Local only: never synced or exported. */
export class ProPasskeyPeers {
  private static store(context: common.Context): preferences.Preferences | null {
    try { return preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' }); }
    catch (_error) { return null; }
  }

  private static readAll(context: common.Context): PasskeyPeer[] {
    const store = ProPasskeyPeers.store(context);
    if (store === null) { return []; }
    try {
      const parsed: Object = JSON.parse(store.getSync(PREFERENCE_KEY, '[]') as string) as Object;
      return Array.isArray(parsed) ? (parsed as Object[]).filter(valid).map((item: Object): PasskeyPeer =>
        item as PasskeyPeer) : [];
    } catch (_error) {
      return [];
    }
  }

  private static writeAll(context: common.Context, peers: PasskeyPeer[]): void {
    const store = ProPasskeyPeers.store(context);
    if (store === null) { throw new Error('PASSKEY_STORE_UNAVAILABLE'); }
    try {
      store.putSync(PREFERENCE_KEY, JSON.stringify(peers));
      store.flushSync();
    } catch (_error) {
      throw new Error('PASSKEY_STORE_UNAVAILABLE');
    }
  }

  static list(context: common.Context, owner: string): PasskeyPeer[] {
    return ProPasskeyPeers.readAll(context).filter((peer: PasskeyPeer): boolean => peer.owner === owner)
      .sort((a: PasskeyPeer, b: PasskeyPeer): number => b.lastUsedAt - a.lastUsedAt);
  }

  static find(context: common.Context, owner: string, id: string): PasskeyPeer | null {
    return ProPasskeyPeers.list(context, owner).find((peer: PasskeyPeer): boolean => peer.id === id) ?? null;
  }

  /** Adds or refreshes a peer; the oldest of this account's peers make room beyond the limit. */
  static save(context: common.Context, peer: PasskeyPeer): void {
    const all = ProPasskeyPeers.readAll(context).filter((item: PasskeyPeer): boolean =>
      !(item.owner === peer.owner && item.id === peer.id));
    const mine = all.filter((item: PasskeyPeer): boolean => item.owner === peer.owner)
      .sort((a: PasskeyPeer, b: PasskeyPeer): number => b.lastUsedAt - a.lastUsedAt).slice(0, MAX_PEERS - 1);
    const others = all.filter((item: PasskeyPeer): boolean => item.owner !== peer.owner);
    ProPasskeyPeers.writeAll(context, others.concat(mine).concat([peer]));
  }

  static remove(context: common.Context, owner: string, id: string): boolean {
    const all = ProPasskeyPeers.readAll(context);
    const kept = all.filter((item: PasskeyPeer): boolean => !(item.owner === owner && item.id === id));
    if (kept.length === all.length) { return false; }
    ProPasskeyPeers.writeAll(context, kept);
    return true;
  }

  static receiving(context: common.Context, owner: string): boolean {
    const store = ProPasskeyPeers.store(context);
    if (store === null || owner === '') { return false; }
    try {
      const parsed: Object = JSON.parse(store.getSync(RECEIVE_KEY, '[]') as string) as Object;
      return Array.isArray(parsed) && (parsed as Object[]).indexOf(owner) >= 0;
    } catch (_error) {
      return false;
    }
  }

  static setReceiving(context: common.Context, owner: string, on: boolean): boolean {
    const store = ProPasskeyPeers.store(context);
    if (store === null || owner === '') { return false; }
    try {
      const parsed: Object = JSON.parse(store.getSync(RECEIVE_KEY, '[]') as string) as Object;
      const owners: string[] = Array.isArray(parsed) ? (parsed as Object[]).filter((item: Object): boolean =>
        typeof item === 'string' && item !== owner).map((item: Object): string => item as string) : [];
      if (on) { owners.push(owner); }
      store.putSync(RECEIVE_KEY, JSON.stringify(owners));
      store.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }
}
