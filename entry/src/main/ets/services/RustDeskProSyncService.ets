import { common } from '@kit.AbilityKit';
import {
  RustDeskProAccountState,
  rustDeskProAccessTokenFingerprint,
  rustDeskProTokenGeneration,
  rustDeskProTokenMatchesConnection
} from '../model/RustDeskProModels';
import { HostSyncService } from './HostSyncService';
import { RustDeskProApiService } from './RustDeskProApiService';
import { RustDeskProCredentialStore } from './RustDeskProCredentialStore';
import { normalizeRustDeskProServerUrl, RustDeskProApiError } from './RustDeskProApiPolicy';
import { RustDeskProReconcileResult } from './RustDeskProSyncPolicy';
import { LegacyRustDeskAccountCloudAdapter } from './LegacyRustDeskAccountCloudAdapter';
import { RustDeskAccount } from '../model/RustDeskAccount';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { CloudStore } from './CloudStore';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  RustDeskControlPlaneCapabilityIssueResult
} from './RustDeskControlPlaneCapabilityPolicy';
import {
  cloneRustDeskControlPlaneCapabilityProof
} from '../model/RustDeskControlPlaneCapabilityModels';

export interface RustDeskProLoginInput {
  id: string
  relayId: string
  serverUrl: string
  username: string
  password: string
}

interface RustDeskProOperation {
  generation: number;
  lease: AccountSessionLease;
}

export class RustDeskProSyncService {
  private static instance: RustDeskProSyncService;
  private readonly api: RustDeskProApiService = RustDeskProApiService.getInstance();
  private readonly credentials: RustDeskProCredentialStore = RustDeskProCredentialStore.getInstance();
  private readonly hosts: HostSyncService = HostSyncService.getInstance();
  private context: common.Context | null = null;
  private operationGeneration: number = 0;
  private activeOperations: number = 0;

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
    void this.initializeCurrentScope(context);
  }

  getAccounts(): RustDeskProAccountState[] {
    return this.credentials.getAll();
  }

  getAccount(accountId: string): RustDeskProAccountState | undefined {
    const id: string = accountId.trim();
    if (id.length === 0) { return undefined; }
    return this.credentials.get(id);
  }

  onDataChange(callback: () => void): () => void {
    return this.credentials.onDataChange(callback);
  }

  async prepareScopeTransition(timeoutMs: number = 10000): Promise<boolean> {
    this.operationGeneration++;
    const startedAt: number = Date.now();
    while (this.activeOperations > 0 &&
      Date.now() - startedAt < Math.max(1, timeoutMs)) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 20);
      });
    }
    return this.activeOperations === 0;
  }

  private beginOperation(): RustDeskProOperation {
    const lease: AccountSessionLease | null =
      CloudStore.getInstance().currentAccountLease();
    if (lease === null) {
      throw new RustDeskProApiError('account_scope_unavailable',
        '账号数据域尚未就绪');
    }
    this.activeOperations++;
    return {
      generation: this.operationGeneration,
      lease: cloneAccountSessionLease(lease)
    };
  }

  private endOperation(): void {
    this.activeOperations = Math.max(0, this.activeOperations - 1);
  }

  private operationIsCurrent(operation: RustDeskProOperation): boolean {
    return operation.generation === this.operationGeneration &&
      accountSessionLeaseEquals(
        CloudStore.getInstance().currentAccountLease(), operation.lease);
  }

  private requireCurrentOperation(operation: RustDeskProOperation): void {
    if (!this.operationIsCurrent(operation)) {
      throw new RustDeskProApiError('account_scope_changed',
        '账号已切换，已丢弃旧账号网络结果');
    }
  }

  private async initializeCurrentScope(context: common.Context): Promise<void> {
    let operation: RustDeskProOperation | null = null;
    try {
      operation = this.beginOperation();
      await this.hosts.init(context);
      this.requireCurrentOperation(operation);
      this.importCloudAccountMetadata(operation);
    } catch (_err) {
      // A page may initialize while the account scope is still opening or
      // leaving. The active scope will initialize the service again.
    } finally {
      if (operation !== null) { this.endOperation(); }
    }
  }

  private importCloudAccountMetadata(operation: RustDeskProOperation): void {
    this.requireCurrentOperation(operation);
    const relays: RustDeskRelayConfig[] = this.hosts.getAllRelays();
    for (let i = 0; i < relays.length; i++) {
      this.requireCurrentOperation(operation);
      const relay: RustDeskRelayConfig = relays[i];
      let migrated: RustDeskRelayConfig | null = null;
      for (let j = 0; j < relay.accounts.length; j++) {
        const legacy: RustDeskAccount = relay.accounts[j];
        // Released versions called these records "Admin" accounts. They
        // are now Pro metadata; migrate every legacy row without carrying
        // its old password into the new local-only credential model.
        if (!LegacyRustDeskAccountCloudAdapter.isProMetadata(legacy)) {
          if (migrated === null) { migrated = RustDeskRelayConfig.fromJSON(relay.toJSON()); }
          const migratedRow: RustDeskAccount = migrated.accounts[j];
          migrated.accounts[j] = LegacyRustDeskAccountCloudAdapter.toLegacy(
            LegacyRustDeskAccountCloudAdapter.fromLegacy(legacy, relay.apiServer));
          migrated.accounts[j].id = migratedRow.id;
        }
        const local: RustDeskProAccountState | undefined = this.credentials.get(legacy.id);
        if (local !== undefined && local.accessToken.length > 0) { continue; }
        this.requireCurrentOperation(operation);
        this.saveCredentialOrThrow(
          LegacyRustDeskAccountCloudAdapter.fromLegacy(
            legacy, relay.apiServer));
      }
      if (migrated !== null) {
        this.requireCurrentOperation(operation);
        this.hosts.updateRelay(migrated);
      }
    }
  }

  private persistCloudAccountMetadata(account: RustDeskProAccountState): void {
    const relay: RustDeskRelayConfig | undefined = this.hosts.getAllRelays().find(
      (item: RustDeskRelayConfig): boolean => item.id === account.relayId);
    if (relay === undefined) { return; }
    const next: RustDeskRelayConfig = RustDeskRelayConfig.fromJSON(relay.toJSON());
    const metadata: RustDeskAccount = LegacyRustDeskAccountCloudAdapter.toLegacy(account);
    const index: number = next.accounts.findIndex((item: RustDeskAccount): boolean => item.id === account.id);
    if (index >= 0) { next.accounts[index] = metadata; } else { next.accounts.push(metadata); }
    this.hosts.updateRelay(next);
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
      accessTokenFingerprint: account.accessTokenFingerprint !== ''
        ? account.accessTokenFingerprint : rustDeskProAccessTokenFingerprint(account.accessToken),
      tokenGeneration: rustDeskProTokenGeneration(account),
      deviceId: account.deviceId,
      deviceUuid: account.deviceUuid,
      loginStatus: account.loginStatus,
      lastLoginAt: account.lastLoginAt,
      lastSyncAt: account.lastSyncAt,
      lastSyncError: account.lastSyncError,
      controlPlaneCapabilityProof:
        cloneRustDeskControlPlaneCapabilityProof(
          account.controlPlaneCapabilityProof)
    };
  }

  private saveCredentialOrThrow(
    account: RustDeskProAccountState
  ): void {
    if (!this.credentials.save(account)) {
      throw new RustDeskProApiError(
        'credential_store_failed',
        'Pro 登录凭据未能写入系统安全资产');
    }
  }

  private async authenticate(input: RustDeskProLoginInput,
    operation: RustDeskProOperation): Promise<RustDeskProAccountState> {
    this.requireCurrentOperation(operation);
    const previous = this.credentials.get(input.id);
    const account: RustDeskProAccountState = {
      id: input.id,
      relayId: input.relayId,
      serverUrl: normalizeRustDeskProServerUrl(input.serverUrl),
      username: input.username.trim(),
      displayName: input.username.trim(),
      userId: '',
      accessToken: '',
      accessTokenFingerprint: rustDeskProAccessTokenFingerprint(''),
      tokenGeneration: previous ? rustDeskProTokenGeneration(previous) : 1,
      deviceId: previous ? previous.deviceId : '',
      deviceUuid: previous ? previous.deviceUuid : '',
      loginStatus: 'none',
      lastLoginAt: 0,
      lastSyncAt: 0,
      lastSyncError: '',
      controlPlaneCapabilityProof: undefined
    };
    this.credentials.ensureDeviceIdentity(account);
    const result = await this.api.login(account, input.username, input.password);
    this.requireCurrentOperation(operation);
    account.accessToken = result.accessToken;
    account.accessTokenFingerprint = rustDeskProAccessTokenFingerprint(result.accessToken);
    account.tokenGeneration = previous ? rustDeskProTokenGeneration(previous) + 1 : 1;
    account.userId = result.userId;
    account.username = result.username.length > 0 ? result.username : input.username.trim();
    account.displayName = result.displayName.length > 0 ? result.displayName : account.username;
    account.loginStatus = 'logged_in';
    account.lastLoginAt = Date.now();
    account.lastSyncError = '';
    return account;
  }

  private async syncAccount(account: RustDeskProAccountState,
    operation: RustDeskProOperation): Promise<RustDeskProReconcileResult> {
    this.requireCurrentOperation(operation);
    if (this.context !== null) {
      await this.hosts.init(this.context);
      this.requireCurrentOperation(operation);
    }
    await this.hosts.whenReady();
    this.requireCurrentOperation(operation);
    const addressBook = await this.api.getAddressBook(account);
    this.requireCurrentOperation(operation);
    const relay = this.hosts.getAllRelays().find((item) => item.id === account.relayId);
    this.requireCurrentOperation(operation);
    const result = this.hosts.reconcileRustDeskProHosts(account.relayId, account.id, addressBook.peers,
      addressBook.updatedAt > 0 ? addressBook.updatedAt : Date.now(),
      relay ? relay.idServer : '', relay ? relay.idServerPort : 21116);
    account.loginStatus = 'logged_in';
    account.lastSyncAt = Date.now();
    account.lastSyncError = '';
    return result;
  }

  private bindAuthenticatedControlPlaneCapability(
    account: RustDeskProAccountState,
    operation: RustDeskProOperation
  ): RustDeskControlPlaneCapabilityIssueResult {
    this.requireCurrentOperation(operation);
    const relay: RustDeskRelayConfig | undefined =
      this.hosts.getAllRelays().find(
        (item: RustDeskRelayConfig): boolean =>
          item.id === account.relayId);
    const unavailable = new RustDeskControlPlaneCapabilityIssueResult();
    account.controlPlaneCapabilityProof = undefined;
    unavailable.code = relay === undefined
      ? 'relay_missing' : 'capability_attestation_unavailable';
    unavailable.message =
      '地址簿已同步；当前构建没有可验证的官方／第三方控制面能力证明，连接将按 API-only 模式且不发送地址簿令牌。';
    return unavailable;
  }

  async login(input: RustDeskProLoginInput): Promise<RustDeskProAccountState> {
    const operation: RustDeskProOperation = this.beginOperation();
    try {
      const account = await this.authenticate(input, operation);
      this.requireCurrentOperation(operation);
      this.saveCredentialOrThrow(account);
      this.persistCloudAccountMetadata(account);
      return this.cloneAccount(account);
    } finally {
      this.endOperation();
    }
  }

  async loginAndSync(input: RustDeskProLoginInput): Promise<RustDeskProReconcileResult> {
    // Keep login + first address-book pull atomic. A successful login followed
    // by a failed address-book request must not leave a half-created account.
    const operation: RustDeskProOperation = this.beginOperation();
    try {
      const account = await this.authenticate(input, operation);
      const result = await this.syncAccount(account, operation);
      this.requireCurrentOperation(operation);
      this.bindAuthenticatedControlPlaneCapability(account, operation);
      this.saveCredentialOrThrow(account);
      this.persistCloudAccountMetadata(account);
      return result;
    } finally {
      this.endOperation();
    }
  }

  async sync(accountId: string): Promise<RustDeskProReconcileResult> {
    const operation: RustDeskProOperation = this.beginOperation();
    const account = this.credentials.get(accountId);
    if (!account) {
      this.endOperation();
      throw new RustDeskProApiError('account_missing', 'Pro 账号不存在');
    }
    try {
      const result = await this.syncAccount(account, operation);
      this.requireCurrentOperation(operation);
      this.bindAuthenticatedControlPlaneCapability(account, operation);
      this.saveCredentialOrThrow(account);
      return result;
    } catch (err) {
      if (!this.operationIsCurrent(operation)) {
        throw err instanceof Error ? err : new Error('账号已切换');
      }
      const code = err instanceof RustDeskProApiError ? err.code : 'sync_error';
      account.lastSyncError = code;
      if (code === 'token_expired') {
        account.loginStatus = 'expired';
        account.accessToken = '';
        account.accessTokenFingerprint = rustDeskProAccessTokenFingerprint('');
        account.controlPlaneCapabilityProof = undefined;
      }
      this.saveCredentialOrThrow(account);
      throw err instanceof Error ? err : new Error('Pro 同步失败');
    } finally {
      this.endOperation();
    }
  }

  markConnectionSessionExpired(accountId: string, reason: string = 'connection_token_expired',
    expectedFingerprint: string = '', expectedGeneration: number = 0,
    expectedOwnerScopeId: string = '', expectedAccountGeneration: number = 0): boolean {
    const lease: AccountSessionLease | null =
      CloudStore.getInstance().currentAccountLease();
    if (lease === null ||
      expectedOwnerScopeId.trim() !== lease.ownerScopeId ||
      expectedAccountGeneration !== lease.generation) {
      return false;
    }
    const account = this.credentials.get(accountId);
    if (!account) { return false; }
    const currentFingerprint: string = account.accessTokenFingerprint !== ''
      ? account.accessTokenFingerprint : rustDeskProAccessTokenFingerprint(account.accessToken);
    const currentGeneration: number = rustDeskProTokenGeneration(account);
    if (!rustDeskProTokenMatchesConnection(
      expectedFingerprint, expectedGeneration, currentFingerprint, currentGeneration)) {
      return false;
    }
    account.accessToken = '';
    account.accessTokenFingerprint = rustDeskProAccessTokenFingerprint('');
    account.loginStatus = 'expired';
    account.lastSyncError = reason;
    account.controlPlaneCapabilityProof = undefined;
    if (!this.credentials.save(account)) { return false; }
    this.persistCloudAccountMetadata(account);
    return true;
  }

  async logout(accountId: string): Promise<void> {
    const operation: RustDeskProOperation = this.beginOperation();
    const account = this.credentials.get(accountId);
    try {
      if (!account) { return; }
      await this.api.logout(account);
      this.requireCurrentOperation(operation);
      if (!this.credentials.clear(accountId)) {
        throw new RustDeskProApiError(
          'credential_store_failed',
          'Pro 登录凭据未能从系统安全资产删除');
      }
      const relay = this.hosts.getAllRelays().find(
        (item: RustDeskRelayConfig): boolean => item.id === account.relayId);
      if (relay !== undefined) {
        const next: RustDeskRelayConfig = RustDeskRelayConfig.fromJSON(relay.toJSON());
        next.accounts = next.accounts.filter(
          (item: RustDeskAccount): boolean => item.id !== accountId);
        this.hosts.updateRelay(next);
      }
    } finally {
      this.endOperation();
    }
  }
}
