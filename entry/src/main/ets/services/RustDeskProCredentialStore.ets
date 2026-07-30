import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import {
  RustDeskProAccountState,
  rustDeskProAccessTokenFingerprint,
  rustDeskProTokenGeneration
} from '../model/RustDeskProModels';
import {
  RustDeskProCredentialMetadata,
  rustDeskProCredentialMetadata
} from './RustDeskProCredentialPolicy';

const STORE_NAME: string = 'RustDeskProCredentials';
const ACCOUNTS_KEY: string = 'accounts';
const TOKEN_ALIAS_DOMAIN: string =
  'RemoteDeskHarmonyOS:rustdesk-pro-token:v1:';
const ASSET_NOT_FOUND_CODE: number = 24000002;
const ASSET_MAX_SECRET_BYTES: number = 1024;

export class RustDeskProCredentialStore {
  private static instance: RustDeskProCredentialStore;
  private context: common.Context | null = null;
  private accounts: RustDeskProAccountState[] = [];
  private loaded: boolean = false;
  private scopeId: string = 'device-local';
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

  bindScope(context: common.Context, scopeId: string): void {
    const normalized: string = scopeId.trim().length > 0 ? scopeId.trim() : 'device-local';
    this.context = context;
    if (this.loaded && this.scopeId === normalized) { return; }
    this.accounts = [];
    this.loaded = false;
    this.scopeId = normalized;
    this.load();
    this.emitDataChange();
  }

  clearMemoryForScopeTransition(): void {
    this.accounts = [];
    this.loaded = false;
    this.emitDataChange();
  }

  /**
   * A Huawei-account scope transition is also a credential revocation
   * boundary. Remove every Asset Store token in the outgoing scope before the
   * metadata/cache can be rebound to another owner.
   */
  clearForScopeTransition(): boolean {
    if (!this.loaded) { this.load(); }
    const accountIds: string[] = [];
    for (let i = 0; i < this.accounts.length; i++) {
      const id: string = this.accounts[i].id.trim();
      if (id !== '' && accountIds.indexOf(id) < 0) {
        accountIds.push(id);
      }
    }
    let removed: boolean = true;
    for (let i = 0; i < accountIds.length; i++) {
      if (!this.removeToken(accountIds[i])) { removed = false; }
    }
    this.accounts = [];
    this.loaded = removed;
    if (!removed) {
      // Keep durable account ids available for a later revocation retry, but
      // never retain a plaintext token in this process.
      this.loaded = false;
      this.emitDataChange();
      return false;
    }
    const persisted: boolean = this.persist();
    if (!persisted) { this.loaded = false; }
    this.emitDataChange();
    return persisted;
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

  private sha256Hex(value: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({
      data: new util.TextEncoder().encode(value)
    });
    const bytes: Uint8Array = md.digestSync().data;
    let result: string = '';
    for (let i = 0; i < bytes.length; i++) {
      result += bytes[i].toString(16).padStart(2, '0');
    }
    return result;
  }

  private tokenAlias(accountId: string): Uint8Array {
    const identity: string =
      this.scopeId + '\u001f' + accountId.trim();
    return new util.TextEncoder().encode(
      TOKEN_ALIAS_DOMAIN + this.sha256Hex(identity));
  }

  private assetErrorCode(error: Object): number {
    if (!error || typeof error !== 'object') { return 0; }
    const record: Record<string, Object> =
      error as Record<string, Object>;
    return typeof record['code'] === 'number'
      ? record['code'] as number : 0;
  }

  private readToken(accountId: string): string {
    if (accountId.trim() === '') { return ''; }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.tokenAlias(accountId));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows: Array<asset.AssetMap> =
        asset.querySync(query);
      if (rows.length !== 1) { return ''; }
      const secret: Uint8Array =
        rows[0].get(asset.Tag.SECRET) as Uint8Array;
      if (!secret || secret.length === 0 ||
        secret.length > ASSET_MAX_SECRET_BYTES) {
        return '';
      }
      return new util.TextDecoder().decodeToString(secret);
    } catch (_err) {
      return '';
    }
  }

  private writeToken(accountId: string, token: string): boolean {
    const normalizedId: string = accountId.trim();
    if (normalizedId === '' || token === '') { return false; }
    const secret: Uint8Array =
      new util.TextEncoder().encode(token);
    if (secret.length === 0 ||
      secret.length > ASSET_MAX_SECRET_BYTES) {
      return false;
    }
    try {
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS,
        this.tokenAlias(normalizedId));
      attributes.set(asset.Tag.SECRET, secret);
      attributes.set(asset.Tag.ACCESSIBILITY,
        asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE,
        asset.SyncType.THIS_DEVICE);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION,
        asset.ConflictResolution.OVERWRITE);
      asset.addSync(attributes);
      return true;
    } catch (_err) {
      return false;
    }
  }

  private removeToken(accountId: string): boolean {
    if (accountId.trim() === '') { return true; }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.tokenAlias(accountId));
      asset.removeSync(query);
      return true;
    } catch (err) {
      return this.assetErrorCode(err as Object) ===
        ASSET_NOT_FOUND_CODE;
    }
  }

  private load(): void {
    this.loaded = true;
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: this.activeStoreName() });
      const raw: string = prefs.getSync(ACCOUNTS_KEY, '') as string;
      if (raw.length === 0) { return; }
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return; }
      const rows: Object[] = parsed as Object[];
      let legacySecretFound: boolean = false;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i] && typeof rows[i] === 'object') {
          const row = rows[i] as Record<string, Object>;
          const accountId: string =
            typeof row['id'] === 'string'
              ? row['id'] as string : '';
          const legacyToken: string =
            typeof row['accessToken'] === 'string'
              ? row['accessToken'] as string : '';
          let accessToken: string = '';
          if (legacyToken !== '') {
            legacySecretFound = true;
            if (this.writeToken(accountId, legacyToken)) {
              accessToken = legacyToken;
            }
          } else {
            accessToken = this.readToken(accountId);
          }
          this.accounts.push(
            this.fromRecord(row, accessToken));
        }
      }
      if (legacySecretFound) {
        // Scrub plaintext tokens even if Asset Store was unavailable. The
        // affected Pro account becomes expired and must be authenticated
        // again rather than leaving a reusable token in Preferences.
        this.persist();
      }
    } catch (_err) {
      this.accounts = [];
    }
  }

  private fromRecord(
    row: Record<string, Object>, accessToken: string
  ): RustDeskProAccountState {
    const storedFingerprint: string = typeof row['accessTokenFingerprint'] === 'string'
      ? row['accessTokenFingerprint'] as string : '';
    const storedGeneration: number = typeof row['tokenGeneration'] === 'number'
      ? row['tokenGeneration'] as number : 1;
    let loginStatus: string =
      typeof row['loginStatus'] === 'string'
        ? row['loginStatus'] as string : 'none';
    let lastSyncError: string =
      typeof row['lastSyncError'] === 'string'
        ? row['lastSyncError'] as string : '';
    if (accessToken === '' && loginStatus === 'logged_in') {
      loginStatus = 'expired';
      lastSyncError = 'credential_asset_unavailable';
    }
    return {
      id: typeof row['id'] === 'string' ? row['id'] as string : '',
      relayId: typeof row['relayId'] === 'string' ? row['relayId'] as string : '',
      serverUrl: typeof row['serverUrl'] === 'string' ? row['serverUrl'] as string : '',
      username: typeof row['username'] === 'string' ? row['username'] as string : '',
      displayName: typeof row['displayName'] === 'string' ? row['displayName'] as string : '',
      userId: typeof row['userId'] === 'string' ? row['userId'] as string : '',
      accessToken,
      accessTokenFingerprint: accessToken === ''
        ? rustDeskProAccessTokenFingerprint('')
        : (storedFingerprint !== '' ? storedFingerprint :
          rustDeskProAccessTokenFingerprint(accessToken)),
      tokenGeneration: Number.isFinite(storedGeneration) && storedGeneration > 0
        ? Math.floor(storedGeneration) : 1,
      deviceId: typeof row['deviceId'] === 'string' ? row['deviceId'] as string : '',
      deviceUuid: typeof row['deviceUuid'] === 'string' ? row['deviceUuid'] as string : '',
      loginStatus,
      lastLoginAt: typeof row['lastLoginAt'] === 'number' ? row['lastLoginAt'] as number : 0,
      lastSyncAt: typeof row['lastSyncAt'] === 'number' ? row['lastSyncAt'] as number : 0,
      lastSyncError
    };
  }

  private persist(): boolean {
    if (!this.context) { return false; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: this.activeStoreName() });
      const metadata: Array<RustDeskProCredentialMetadata> = [];
      for (let i = 0; i < this.accounts.length; i++) {
        metadata.push(
          rustDeskProCredentialMetadata(this.accounts[i]));
      }
      prefs.putSync(ACCOUNTS_KEY, JSON.stringify(metadata));
      prefs.flushSync();
      return true;
    } catch (_err) {
      return false;
    }
  }

  private activeStoreName(): string {
    return STORE_NAME + '_' + this.scopeId;
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
      accessTokenFingerprint: account.accessTokenFingerprint !== ''
        ? account.accessTokenFingerprint : rustDeskProAccessTokenFingerprint(account.accessToken),
      tokenGeneration: rustDeskProTokenGeneration(account),
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

  save(account: RustDeskProAccountState): boolean {
    const next: RustDeskProAccountState =
      this.clone(account);
    const index = this.accounts.findIndex(
      (item: RustDeskProAccountState): boolean =>
        item.id === next.id);
    const previous: RustDeskProAccountState | undefined =
      index >= 0 ? this.clone(this.accounts[index]) : undefined;
    const secretStored: boolean = next.accessToken === ''
      ? this.removeToken(next.id)
      : this.writeToken(next.id, next.accessToken);
    if (!secretStored) { return false; }
    if (index >= 0) {
      this.accounts[index] = next;
    } else {
      this.accounts.push(next);
    }
    if (!this.persist()) {
      if (previous === undefined) {
        this.accounts = this.accounts.filter(
          (item: RustDeskProAccountState): boolean =>
            item.id !== next.id);
        this.removeToken(next.id);
      } else {
        this.accounts[index] = previous;
        if (previous.accessToken === '') {
          this.removeToken(previous.id);
        } else if (!this.writeToken(
          previous.id, previous.accessToken)) {
          this.removeToken(previous.id);
        }
      }
      return false;
    }
    this.emitDataChange();
    return true;
  }

  clear(id: string): boolean {
    const previous: RustDeskProAccountState | undefined =
      this.accounts.find(
        (account: RustDeskProAccountState): boolean =>
          account.id === id);
    if (!this.removeToken(id)) { return false; }
    this.accounts = this.accounts.filter(
      (account: RustDeskProAccountState): boolean =>
        account.id !== id);
    if (!this.persist()) {
      if (previous !== undefined) {
        this.accounts.push(previous);
        if (previous.accessToken !== '') {
          this.writeToken(previous.id, previous.accessToken);
        }
      }
      return false;
    }
    this.emitDataChange();
    return true;
  }
}
