import { common } from '@kit.AbilityKit';
import { RustDeskProAccountState } from '../model/RustDeskProModels';
import { HostSyncService } from './HostSyncService';
import { RustDeskProApiService } from './RustDeskProApiService';
import { RustDeskProCredentialStore } from './RustDeskProCredentialStore';
import { normalizeRustDeskProServerUrl, RustDeskProApiError } from './RustDeskProApiPolicy';
import { RustDeskProReconcileResult } from './RustDeskProSyncPolicy';

export interface RustDeskProLoginInput {
  id: string
  relayId: string
  serverUrl: string
  username: string
  password: string
}

export class RustDeskProSyncService {
  private static instance: RustDeskProSyncService;
  private readonly api: RustDeskProApiService = RustDeskProApiService.getInstance();
  private readonly credentials: RustDeskProCredentialStore = RustDeskProCredentialStore.getInstance();
  private readonly hosts: HostSyncService = HostSyncService.getInstance();
  private context: common.Context | null = null;

  static getInstance(): RustDeskProSyncService {
    if (!RustDeskProSyncService.instance) {
      RustDeskProSyncService.instance = new RustDeskProSyncService();
    }
    return RustDeskProSyncService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    this.credentials.init(context);
    // EntryAbility starts this initialization too; HostSyncService safely
    // coalesces concurrent init calls. Pro sync must never race the first
    // CloudStore load and then lose imported hosts.
    void this.hosts.init(context);
  }

  getAccounts(): RustDeskProAccountState[] {
    return this.credentials.getAll();
  }

  onDataChange(callback: () => void): () => void {
    return this.credentials.onDataChange(callback);
  }

  private cloneAccount(account: RustDeskProAccountState): RustDeskProAccountState {
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

  private async authenticate(input: RustDeskProLoginInput): Promise<RustDeskProAccountState> {
    const previous = this.credentials.get(input.id);
    const account: RustDeskProAccountState = {
      id: input.id,
      relayId: input.relayId,
      serverUrl: normalizeRustDeskProServerUrl(input.serverUrl),
      username: input.username.trim(),
      displayName: input.username.trim(),
      userId: '',
      accessToken: '',
      deviceId: previous ? previous.deviceId : '',
      deviceUuid: previous ? previous.deviceUuid : '',
      loginStatus: 'none',
      lastLoginAt: 0,
      lastSyncAt: 0,
      lastSyncError: ''
    };
    this.credentials.ensureDeviceIdentity(account);
    const result = await this.api.login(account, input.username, input.password);
    account.accessToken = result.accessToken;
    account.userId = result.userId;
    account.username = result.username.length > 0 ? result.username : input.username.trim();
    account.displayName = result.displayName.length > 0 ? result.displayName : account.username;
    account.loginStatus = 'logged_in';
    account.lastLoginAt = Date.now();
    account.lastSyncError = '';
    return account;
  }

  private async syncAccount(account: RustDeskProAccountState): Promise<RustDeskProReconcileResult> {
    if (this.context !== null) {
      await this.hosts.init(this.context);
    }
    await this.hosts.whenReady();
    const addressBook = await this.api.getAddressBook(account);
    const relay = this.hosts.getAllRelays().find((item) => item.id === account.relayId);
    const result = this.hosts.reconcileRustDeskProHosts(account.relayId, account.id, addressBook.peers,
      addressBook.updatedAt > 0 ? addressBook.updatedAt : Date.now(),
      relay ? relay.idServer : '', relay ? relay.idServerPort : 21116);
    account.loginStatus = 'logged_in';
    account.lastSyncAt = Date.now();
    account.lastSyncError = '';
    return result;
  }

  async login(input: RustDeskProLoginInput): Promise<RustDeskProAccountState> {
    const account = await this.authenticate(input);
    this.credentials.save(account);
    return this.cloneAccount(account);
  }

  async loginAndSync(input: RustDeskProLoginInput): Promise<RustDeskProReconcileResult> {
    // Keep login + first address-book pull atomic. A successful login followed
    // by a failed address-book request must not leave a half-created account.
    const account = await this.authenticate(input);
    const result = await this.syncAccount(account);
    this.credentials.save(account);
    return result;
  }

  async sync(accountId: string): Promise<RustDeskProReconcileResult> {
    const account = this.credentials.get(accountId);
    if (!account) { throw new RustDeskProApiError('account_missing', 'Pro 账号不存在'); }
    try {
      const result = await this.syncAccount(account);
      this.credentials.save(account);
      return result;
    } catch (err) {
      const code = err instanceof RustDeskProApiError ? err.code : 'sync_error';
      account.lastSyncError = code;
      if (code === 'token_expired') { account.loginStatus = 'expired'; account.accessToken = ''; }
      this.credentials.save(account);
      throw err instanceof Error ? err : new Error('Pro 同步失败');
    }
  }

  async logout(accountId: string): Promise<void> {
    const account = this.credentials.get(accountId);
    if (!account) { return; }
    await this.api.logout(account);
    this.credentials.clear(accountId);
  }
}
