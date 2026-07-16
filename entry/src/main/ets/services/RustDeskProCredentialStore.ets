import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { RustDeskProAccountState } from '../model/RustDeskProModels';

const STORE_NAME: string = 'RustDeskProCredentials';
const ACCOUNTS_KEY: string = 'accounts';

export class RustDeskProCredentialStore {
  private static instance: RustDeskProCredentialStore;
  private context: common.Context | null = null;
  private accounts: RustDeskProAccountState[] = [];
  private loaded: boolean = false;
  private dataChangeListeners: Array<() => void> = [];

  static getInstance(): RustDeskProCredentialStore {
    if (!RustDeskProCredentialStore.instance) {
      RustDeskProCredentialStore.instance = new RustDeskProCredentialStore();
    }
    return RustDeskProCredentialStore.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    if (!this.loaded) { this.load(); }
  }

  onDataChange(callback: () => void): () => void {
    if (this.dataChangeListeners.indexOf(callback) < 0) {
      this.dataChangeListeners.push(callback);
    }
    return (): void => {
      const index = this.dataChangeListeners.indexOf(callback);
      if (index >= 0) { this.dataChangeListeners.splice(index, 1); }
    };
  }

  private emitDataChange(): void {
    const listeners: Array<() => void> = this.dataChangeListeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try { listeners[i](); } catch (_err) { /* 一个页面监听失败不能阻断其他监听 */ }
    }
  }

  private load(): void {
    this.loaded = true;
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      const raw: string = prefs.getSync(ACCOUNTS_KEY, '') as string;
      if (raw.length === 0) { return; }
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return; }
      const rows: Object[] = parsed as Object[];
      for (let i = 0; i < rows.length; i++) {
        if (rows[i] && typeof rows[i] === 'object') {
          const row = rows[i] as Record<string, Object>;
          this.accounts.push(this.fromRecord(row));
        }
      }
    } catch (_err) {
      this.accounts = [];
    }
  }

  private fromRecord(row: Record<string, Object>): RustDeskProAccountState {
    return {
      id: typeof row['id'] === 'string' ? row['id'] as string : '',
      relayId: typeof row['relayId'] === 'string' ? row['relayId'] as string : '',
      serverUrl: typeof row['serverUrl'] === 'string' ? row['serverUrl'] as string : '',
      username: typeof row['username'] === 'string' ? row['username'] as string : '',
      displayName: typeof row['displayName'] === 'string' ? row['displayName'] as string : '',
      userId: typeof row['userId'] === 'string' ? row['userId'] as string : '',
      accessToken: typeof row['accessToken'] === 'string' ? row['accessToken'] as string : '',
      deviceId: typeof row['deviceId'] === 'string' ? row['deviceId'] as string : '',
      deviceUuid: typeof row['deviceUuid'] === 'string' ? row['deviceUuid'] as string : '',
      loginStatus: typeof row['loginStatus'] === 'string' ? row['loginStatus'] as string : 'none',
      lastLoginAt: typeof row['lastLoginAt'] === 'number' ? row['lastLoginAt'] as number : 0,
      lastSyncAt: typeof row['lastSyncAt'] === 'number' ? row['lastSyncAt'] as number : 0,
      lastSyncError: typeof row['lastSyncError'] === 'string' ? row['lastSyncError'] as string : ''
    };
  }

  private persist(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      prefs.putSync(ACCOUNTS_KEY, JSON.stringify(this.accounts));
      prefs.flushSync();
    } catch (_err) {
      // The caller still owns the in-memory state; a later init can retry persistence.
    }
  }

  ensureDeviceIdentity(account: RustDeskProAccountState): RustDeskProAccountState {
    if (account.deviceId.length > 0 && account.deviceUuid.length > 0) { return account; }
    const random = cryptoFramework.createRandom().generateRandomSync(16).data;
    const bytes = new Uint8Array(random);
    let hex: string = '';
    for (let i = 0; i < bytes.length; i++) { hex += bytes[i].toString(16).padStart(2, '0'); }
    account.deviceUuid = hex;
    account.deviceId = 'rdh-' + hex.substring(0, 16);
    return account;
  }

  private clone(account: RustDeskProAccountState): RustDeskProAccountState {
    return {
      id: account.id,
      relayId: account.relayId,
      serverUrl: account.serverUrl,
      username: account.username,
      displayName: account.displayName,
      userId: account.userId,
      accessToken: account.accessToken,
      deviceId: account.deviceId,
      deviceUuid: account.deviceUuid,
      loginStatus: account.loginStatus,
      lastLoginAt: account.lastLoginAt,
      lastSyncAt: account.lastSyncAt,
      lastSyncError: account.lastSyncError
    };
  }

  getAll(): RustDeskProAccountState[] {
    return this.accounts.map((account: RustDeskProAccountState): RustDeskProAccountState => this.clone(account));
  }

  get(id: string): RustDeskProAccountState | undefined {
    const found = this.accounts.find((account: RustDeskProAccountState): boolean => account.id === id);
    return found ? this.clone(found) : undefined;
  }

  save(account: RustDeskProAccountState): void {
    const index = this.accounts.findIndex((item: RustDeskProAccountState): boolean => item.id === account.id);
    if (index >= 0) { this.accounts[index] = this.clone(account); }
    else { this.accounts.push(this.clone(account)); }
    this.persist();
    this.emitDataChange();
  }

  clear(id: string): void {
    this.accounts = this.accounts.filter((account: RustDeskProAccountState): boolean => account.id !== id);
    this.persist();
    this.emitDataChange();
  }
}
