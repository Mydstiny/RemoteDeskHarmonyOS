import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustDeskProAccountState } from '../model/RustDeskProModels';

const STORE_NAME: string = 'RustDeskProCredentials';
const ACCOUNTS_KEY: string = 'accounts';
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'RustDeskProStore';

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
    this.ensureLoaded();
  }

  /**
   * 读取/写入前保证磁盘内容已经进过内存。
   *
   * load() 读失败不会置位 loaded，所以这里每次都会重试；调用方不需要关心
   * 是哪个页面先 init 的。
   */
  private ensureLoaded(): void {
    if (this.loaded || !this.context) { return; }
    this.load();
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

  /**
   * 从 Preferences 读回账号。
   *
   * 失败时**不能**把 loaded 置位：这个 store 是 Server Pro 会话 token 的唯一
   * 本地副本，一次读取失败如果被当成"读到了 0 个账号"，接下来任何一次 save()
   * 都会用空数组覆盖磁盘，把 token 永久删掉 —— 表现就是杀后台之后必须重新
   * 登录一次。读失败保持 loaded=false，让下一次 init() 重试。
   */
  private load(): void {
    if (!this.context) { return; }
    const loadedAccounts: RustDeskProAccountState[] = [];
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      const raw: string = prefs.getSync(ACCOUNTS_KEY, '') as string;
      if (raw.length > 0) {
        const parsed: Object = JSON.parse(raw) as Object;
        if (Array.isArray(parsed)) {
          const rows: Object[] = parsed as Object[];
          for (let i = 0; i < rows.length; i++) {
            if (rows[i] && typeof rows[i] === 'object') {
              const row = rows[i] as Record<string, Object>;
              loadedAccounts.push(this.fromRecord(row));
            }
          }
        } else {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'load: 存储内容不是数组，忽略本次读取');
          return;
        }
      }
    } catch (err) {
      // 保持 loaded=false，绝不让后续 persist() 写空数组覆盖磁盘上的 token。
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load failed: ' + JSON.stringify(err));
      return;
    }
    this.accounts = loadedAccounts;
    this.loaded = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'load: accounts=' + this.accounts.length.toString() +
      ' withToken=' + this.tokenBearingCount().toString());
  }

  /** 诊断用：只统计条数，绝不记录 token 本身。 */
  private tokenBearingCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.accounts.length; i++) {
      if (this.accounts[i].accessToken.length > 0) { count++; }
    }
    return count;
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
    if (!this.context) {
      // 之前这里静默返回：登录成功、内存里有 token、UI 显示"已登录"，但磁盘
      // 上什么都没有，进程一死 token 就没了。
      hilog.error(LOG_DOMAIN, LOG_TAG, 'persist skipped: store 未 init(context)，凭据只存在于内存');
      return;
    }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      prefs.putSync(ACCOUNTS_KEY, JSON.stringify(this.accounts));
      prefs.flushSync();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'persist: accounts=' + this.accounts.length.toString() +
        ' withToken=' + this.tokenBearingCount().toString());
    } catch (err) {
      // The caller still owns the in-memory state; a later init can retry persistence.
      hilog.error(LOG_DOMAIN, LOG_TAG, 'persist failed: ' + JSON.stringify(err));
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
    this.ensureLoaded();
    return this.accounts.map((account: RustDeskProAccountState): RustDeskProAccountState => this.clone(account));
  }

  get(id: string): RustDeskProAccountState | undefined {
    this.ensureLoaded();
    const found = this.accounts.find((account: RustDeskProAccountState): boolean => account.id === id);
    return found ? this.clone(found) : undefined;
  }

  save(account: RustDeskProAccountState): void {
    this.ensureLoaded();
    if (!this.loaded) {
      // 磁盘读不出来，但用户刚登录成功，这份新 token 不能丢。写入会覆盖掉
      // 读失败的旧内容，所以要留下痕迹。
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'save: 磁盘内容未成功读入，本次写入会覆盖原有账号 id=' + account.id);
    }
    const index = this.accounts.findIndex((item: RustDeskProAccountState): boolean => item.id === account.id);
    if (index >= 0) { this.accounts[index] = this.clone(account); }
    else { this.accounts.push(this.clone(account)); }
    this.persist();
    this.emitDataChange();
  }

  clear(id: string): void {
    this.ensureLoaded();
    this.accounts = this.accounts.filter((account: RustDeskProAccountState): boolean => account.id !== id);
    this.persist();
    this.emitDataChange();
  }
}
