import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AccountKitService,
  CredentialParams,
  StoredCredential
} from './AccountKitService';
import {
  AccountScopeToken,
  cloudAccountBindingForScope,
  accountScopeToken,
  deviceLocalScopeToken
} from './AccountScopePolicy';
import { AuthService } from './AuthService';
import { CloudStore } from './CloudStore';
import { HostSyncService } from './HostSyncService';
import { KeyVaultService } from './KeyVaultService';
import { SensitiveDataBarrier } from './SensitiveDataBarrier';
import { RustDeskProCredentialStore } from './RustDeskProCredentialStore';
import { ActiveRemoteSessionRegistry } from './ActiveRemoteSessionRegistry';
import { UserAccountJSON } from '../model/UserAccount';
import {
  PlatformCloudIdentityProof,
  platformCloudIdentityProofIsValid,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';
import { PlatformCloudIdentityService } from './PlatformCloudIdentityService';
import {
  CloudSyncCoordinator,
  CloudSyncOperationResult
} from './CloudSyncCoordinator';
import { cloudTransferAllowed } from './CloudLifecycleSafetyPolicy';
import { safeError } from '../utils/SafeLogger';
import { MoonlightDataLifecycleBarrier } from './MoonlightDataLifecycleBarrier';
import { MoonlightDataLifecycleRuntime } from './MoonlightDataLifecycleRuntime';
import { AppCloneContext } from './AppCloneContext';

export interface AccountLoginIdentity extends CredentialParams {
  avatarUrl: string;
}

export interface AccountTransitionOptions {
  /**
   * Keep the account/store safety transition synchronous, but let the first
   * cloud-first bootstrap finish after the entry page is visible.
   */
  deferCloudBootstrap?: boolean;
}

export interface AccountTransitionResult {
  ok: boolean;
  state: string;
  message: string;
  scope: AccountScopeToken;
}

type AccountTransitionAction = () => Promise<AccountTransitionResult>;

const ACCOUNT_SESSION_PREFS: string = 'RemoteDesktopAppPrefs';
const LOGIN_MODE_KEY: string = 'loginMode';

/**
 * The only owner of account/store transitions. UI pages may request a
 * transition but never open a database, mutate AuthService or publish a ready
 * account independently.
 */
export class AccountSessionCoordinator {
  private static instance: AccountSessionCoordinator;
  private context: common.Context | null = null;
  private current: AccountScopeToken = deviceLocalScopeToken(1);
  private transitionTail: Promise<void> = Promise.resolve();
  private listeners: Array<(scope: AccountScopeToken) => void> = [];
  private initPromise: Promise<boolean> | null = null;
  private startupFallbackPromise: Promise<boolean> | null = null;
  private initialized: boolean = false;
  private startupFallbackApplied: boolean = false;
  private transitionLoginModeSnapshot: string = '';
  private transitionIntentGeneration: number = 0;

  static getInstance(): AccountSessionCoordinator {
    if (!AccountSessionCoordinator.instance) {
      AccountSessionCoordinator.instance = new AccountSessionCoordinator();
    }
    return AccountSessionCoordinator.instance;
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.initialized) { return true; }
    if (this.initPromise !== null) { return await this.initPromise; }
    this.context = context;
    AppCloneContext.getInstance().init(context);
    SensitiveDataBarrier.getInstance().init(context as common.UIAbilityContext);
    MoonlightDataLifecycleBarrier.getInstance().registerPort(
      MoonlightDataLifecycleRuntime.getInstance());
    const operation: Promise<boolean> = this.initialize(context);
    this.initPromise = operation;
    let ready: boolean = false;
    try {
      ready = await operation;
    } catch (error) {
      hilog.error(0x0001, 'AccountSession',
        '账号生命周期初始化异常: ' + safeError(error));
      ready = false;
    } finally {
      if (this.initPromise === operation) { this.initPromise = null; }
    }
    if (!ready && context !== null) {
      const fallbackReady: boolean =
        await this.ensureStartupFallbackIfNeeded(context);
      if (fallbackReady) {
        ready = true;
      }
    }
    if (!ready) {
      this.startupFallbackApplied = false;
    }
    this.initialized = ready;
    return this.initialized;
  }

  private async initialize(context: common.Context): Promise<boolean> {
    const accountReady: boolean = await AccountKitService.getInstance().init(context);
    const store: CloudStore = CloudStore.getInstance();
    const storeReady: boolean = await store.rebindScope(context, this.current);
    if (storeReady) {
      this.current = store.currentScope();
      this.current.sessionState = 'offline';
    }
    if (!storeReady || !store.activateScope(this.current)) {
      this.current.sessionState = 'blocked';
      this.publish();
      return false;
    }
    if (!accountReady) {
      hilog.warn(0x0001, 'AccountSession',
        'AccountKit persistence unavailable; local device scope remains usable');
    }
    RustDeskProCredentialStore.getInstance().bindScope(context, this.current.ownerScopeId);
    ActiveRemoteSessionRegistry.getInstance()
      .bindScope(this.current.ownerScopeId, this.current.generation);
    this.bindMoonlightScope();
    this.publish();
    return true;
  }

  currentScope(): AccountScopeToken {
    return this.cloneScope(this.current);
  }

  onChange(listener: (scope: AccountScopeToken) => void): () => void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  async transitionToAccount(identity: AccountLoginIdentity,
    options: AccountTransitionOptions = {}): Promise<AccountTransitionResult> {
    const intentGeneration: number = ++this.transitionIntentGeneration;
    if (!AppCloneContext.getInstance().accountKitAllowed()) {
      return this.result(false, 'local_only',
        AppCloneContext.getInstance().snapshot().statusText +
        '，华为账号登录与云同步不可用');
    }
    if (!(await this.whenReady())) {
      return this.result(false, 'blocked', '账号生命周期初始化失败');
    }
    return await this.serialize((): Promise<AccountTransitionResult> =>
      this.doTransitionToAccount(
        identity, intentGeneration,
        options.deferCloudBootstrap === true));
  }

  async transitionToOffline(reason: string = 'offline'): Promise<AccountTransitionResult> {
    const intentGeneration: number = ++this.transitionIntentGeneration;
    if (!(await this.whenReady())) {
      return this.result(false, 'blocked', '账号生命周期初始化失败');
    }
    return await this.serialize((): Promise<AccountTransitionResult> =>
      this.doTransitionToOffline(reason, intentGeneration));
  }

  private async whenReady(): Promise<boolean> {
    if (this.initialized) { return true; }
    if (this.initPromise !== null) {
      let ready: boolean = false;
      try {
        ready = await this.initPromise;
      } catch (error) {
        hilog.error(0x0001, 'AccountSession',
          '等待账号生命周期时捕获初始化异常: ' + safeError(error));
      }
      if (!ready &&
        this.context !== null &&
        !this.startupFallbackApplied) {
        return await this.ensureStartupFallbackIfNeeded(this.context);
      }
      return ready;
    }
    if (this.context !== null && !this.startupFallbackApplied) {
      return await this.ensureStartupFallbackIfNeeded(this.context);
    }
    return false;
  }

  private async ensureStartupFallbackIfNeeded(
    context: common.Context
  ): Promise<boolean> {
    if (this.startupFallbackApplied) { return this.initialized; }
    if (this.startupFallbackPromise !== null) { return await this.startupFallbackPromise; }
    const attempt: Promise<boolean> = this.ensureStartupFallback(context);
    this.startupFallbackPromise = attempt.finally(
      (): void => { this.startupFallbackPromise = null; });
    const ready: boolean = await attempt;
    this.startupFallbackApplied = ready;
    return ready;
  }

  private async ensureStartupFallback(
    context: common.Context
  ): Promise<boolean> {
    const store: CloudStore = CloudStore.getInstance();
    const fallback: AccountScopeToken =
      deviceLocalScopeToken(this.current.generation + 1);
    try {
      const rebound: boolean = await store.rebindScope(
        context,
        fallback,
        '',
        unavailablePlatformCloudIdentityProof()
      );
      if (!rebound) {
        return false;
      }
      const fallbackScope: AccountScopeToken = store.currentScope();
      fallbackScope.sessionState = 'offline';
      if (!store.activateScope(fallbackScope)) {
        return false;
      }
      this.current = fallbackScope;
      this.current.sessionState = 'offline';
      this.current.cloudBindingState =
        this.current.kind === 'device_local'
          ? 'unbound' : this.current.cloudBindingState;
      this.reloadScopeServices();
      this.publish();
      hilog.warn(0x0001, 'AccountSession',
        '账号生命周期初始化未完成，已回退到本地设备作用域并允许离线入口');
      this.initialized = true;
      return true;
    } catch (_error) {
      return false;
    }
  }

  private async serialize(action: AccountTransitionAction): Promise<AccountTransitionResult> {
    let result: AccountTransitionResult = {
      ok: false,
      state: 'blocked',
      message: '账号切换未执行',
      scope: this.cloneScope(this.current)
    };
    const previous: Promise<void> = this.transitionTail;
    const run: Promise<void> = previous.catch((_err: Error): void => {}).then(async (): Promise<void> => {
      result = await action();
    });
    this.transitionTail = run.catch((_err: Error): void => {});
    await run;
    return result;
  }

  private async doTransitionToAccount(identity: AccountLoginIdentity,
    intentGeneration: number,
    deferCloudBootstrap: boolean): Promise<AccountTransitionResult> {
    if (this.context === null || !this.initialized) {
      return this.result(false, 'blocked', '账号生命周期尚未初始化');
    }
    const generation: number = this.current.generation + 1;
    const platformProof: PlatformCloudIdentityProof =
      await PlatformCloudIdentityService.getInstance()
        .proveCurrentCloudAccount(
          this.context, identity.unionID);
    const switching: AccountScopeToken | null =
      accountScopeToken(
        identity.unionID, generation, 'switching', 'validating',
        platformProof);
    if (switching === null) {
      return this.result(false, 'blocked', '账号没有返回稳定的 UnionID');
    }
    const previousScope: AccountScopeToken = this.cloneScope(this.current);
    this.transitionLoginModeSnapshot = this.readLoginMode();
    const accountKit: AccountKitService = AccountKitService.getInstance();
    const previousCredential: StoredCredential | null =
      accountKit.credentialSnapshot();
    const previousAuth: UserAccountJSON =
      AuthService.getInstance().sessionSnapshot();
    if (!this.intentIsCurrent(intentGeneration)) {
      return this.result(false, 'superseded', '登录请求已被更新的账号操作替代');
    }

    const store: CloudStore = CloudStore.getInstance();
    if (!store.closeMutationGate()) {
      return this.result(false, 'blocked', '账号数据写入闸门关闭失败');
    }
    if (!(await SensitiveDataBarrier.getInstance().drain('account-switch'))) {
      store.activateScope(this.current);
      return this.result(false, 'blocked', '远程会话仍在安全退出，账号切换已停止');
    }
    if (!(await store.quiesceCurrentScope())) {
      this.current.sessionState = 'blocked';
      this.publish();
      return this.result(false, 'blocked', '旧账号云任务状态不确定，请重启应用后再切换账号');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '登录请求已被更新的账号操作替代');
    }
    HostSyncService.getInstance().clearForScopeTransition();
    KeyVaultService.getInstance().clearForScopeTransition();
    if (!RustDeskProCredentialStore.getInstance()
      .clearForScopeTransition()) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1,
        '旧账号 RustDesk Pro 凭据未能从 Asset Store 安全清除');
    }

    const rebound: boolean = await store.rebindScope(
      this.context, switching, identity.unionID, platformProof);
    if (!rebound) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '账号物理数据域打开失败');
    }

    const currentScope: AccountScopeToken = store.currentScope();
    // 云同步是否真正可用的判定必须同时满足: 账号绑定有效 且 物理库已完成
    // setDistributedTables 注册 (cloudAvailable)。若云端注册失败/云空间未开通,
    // 本地账号登录仍应成功, 只是云功能暂停; 不能把必然失败的 startup pull
    // 作为登录硬前置。
    const cloudBound: boolean = store.isCloudAvailable() &&
      cloudTransferAllowed(cloudAccountBindingForScope(currentScope));

    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '登录请求已被更新的账号操作替代');
    }

    let startupBootstrapDeferred: boolean = false;
    if (cloudBound && deferCloudBootstrap) {
      startupBootstrapDeferred = true;
      hilog.info(0x0001, 'AccountSession',
        '账号数据域已绑定，首次 cloud-first 延后到主页显示后执行');
    } else if (cloudBound) {
      const bootstrap: CloudSyncOperationResult =
        await CloudSyncCoordinator.getInstance()
          .requestStartupPull();
      if (!bootstrap.ok) {
        // The startup cloud-first is the bootstrap gate: uploads stay
        // blocked and bootstrapCompleted stays false until an authoritative
        // pull succeeds. A single table/platform failure (for example the AGC
        // vncrecordv2 table missing its primary key) must NOT roll the login
        // back to device-local: the account scope stays active with sync
        // paused so local data remains usable and the user can resolve the
        // failing table in its own settings.
        hilog.warn(0x0001, 'AccountSession',
          '首次云端核对未完成 failureKind=' + bootstrap.failureKind +
          '，保持账号作用域，云同步暂停，本地数据可用');
      }
      if (bootstrap.ok) {
        if (!store.markStartupSelectionReenablePulled(
          bootstrap.tables) ||
          !store.prepareSelectionReenablePromotions()) {
          return await this.restorePreviousScope(
            previousScope, previousCredential, previousAuth,
            generation + 1,
            '同步范围重新启用的 cloud-first 状态未能安全落盘');
        }
      }
    } else if (cloudAccountBindingForScope(currentScope).state === 'bound' &&
      !store.isCloudAvailable()) {
      hilog.warn(0x0001, 'AccountSession',
        '华为账号本地登录成功，但云端存储不可用（setDistributedTables 失败或云空间未开通），跳过 cloud-first，保持本地可用');
    } else if (platformProof.state === 'permission_denied' ||
      platformProof.state === 'identity_unavailable' ||
      platformProof.state === 'not_logged_in' ||
      platformProof.state === 'platform_error') {
      hilog.warn(0x0001, 'AccountSession',
        '华为账号已完成本地登录，但平台云身份不可验证，跳过云端 startup pull，保持本地可用');
    } else if (platformProof.state === 'identity_mismatch') {
      hilog.warn(0x0001, 'AccountSession',
        '华为账号已完成本地登录，但平台云身份未绑定，跳过 cloud-first，保持本地可用');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1,
        '登录请求已被更新的账号操作替代');
    }

    if (!(await accountKit.init(this.context)) || !(await accountKit.saveCredential(identity))) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '账号凭据未能安全保存');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '登录请求已被更新的账号操作替代');
    }
    if (!AuthService.getInstance().setLoginResult(
      identity.unionID, identity.displayName, identity.avatarUrl, identity.openID)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '账号身份无效');
    }
    if (!this.persistLoginMode('account')) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '登录状态未能持久化');
    }

    this.current = currentScope;
    this.current.sessionState = 'ready';
    if (!store.activateScope(this.current)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '账号数据域状态发布失败');
    }
    if (!store.releaseSelectionReenableBarriers()) {
      hilog.warn(0x0001, 'AccountSession',
        '同步范围 promotion 已完成但 barrier 尚未释放；上传保持暂停');
    }
    this.reloadScopeServices();
    this.publish();
    if (startupBootstrapDeferred) {
      this.scheduleDeferredCloudBootstrap(intentGeneration, store);
    }
    return this.result(true, 'ready', '');
  }

  /**
   * The account/store transition is the security boundary; the initial
   * cloud-first pull is deliberately allowed to continue after navigation.
   * The coordinator still keeps startupState pending, so automatic uploads
   * remain fail-closed until the authoritative pull and selection promotion
   * complete.
   */
  private scheduleDeferredCloudBootstrap(
    intentGeneration: number,
    store: CloudStore
  ): void {
    void CloudSyncCoordinator.getInstance().requestStartupPull().then(
      (bootstrap: CloudSyncOperationResult): void => {
        if (!this.intentIsCurrent(intentGeneration)) { return; }
        if (!bootstrap.ok) {
          hilog.warn(0x0001, 'AccountSession',
            '主页已显示；首次云端核对未完成 failureKind=' +
            bootstrap.failureKind + '，云同步继续保持安全暂停');
          return;
        }
        if (!store.markStartupSelectionReenablePulled(
          bootstrap.tables) ||
          !store.prepareSelectionReenablePromotions() ||
          !store.releaseSelectionReenableBarriers()) {
          hilog.error(0x0001, 'AccountSession',
            '首次云端核对完成，但同步范围 promotion 未能安全落盘；上传保持受限');
          return;
        }
        hilog.info(0x0001, 'AccountSession',
          '后台首次云端核对完成，已完成同步范围 promotion');
      },
      (error: Error): void => {
        if (!this.intentIsCurrent(intentGeneration)) { return; }
        hilog.warn(0x0001, 'AccountSession',
          '主页已显示；首次云端核对 Promise 异常，云同步继续保持安全暂停: ' +
          safeError(error));
      });
  }

  private async doTransitionToOffline(reason: string,
    intentGeneration: number): Promise<AccountTransitionResult> {
    if (this.context === null || !this.initialized) {
      return this.result(false, 'blocked', '账号生命周期尚未初始化');
    }
    const previousScope: AccountScopeToken = this.cloneScope(this.current);
    this.transitionLoginModeSnapshot = this.readLoginMode();
    const accountKit: AccountKitService = AccountKitService.getInstance();
    const previousCredential: StoredCredential | null =
      accountKit.credentialSnapshot();
    const previousAuth: UserAccountJSON =
      AuthService.getInstance().sessionSnapshot();
    if (!this.intentIsCurrent(intentGeneration)) {
      return this.result(false, 'superseded', '离线请求已被更新的账号操作替代');
    }
    const next: AccountScopeToken = deviceLocalScopeToken(this.current.generation + 1);
    const store: CloudStore = CloudStore.getInstance();
    if (!store.closeMutationGate()) {
      return this.result(false, 'blocked', '账号数据写入闸门关闭失败');
    }
    if (!(await SensitiveDataBarrier.getInstance().drain(reason))) {
      store.activateScope(this.current);
      return this.result(false, 'blocked', '远程会话仍在安全退出，离线切换已停止');
    }
    if (!(await store.quiesceCurrentScope())) {
      this.current.sessionState = 'blocked';
      this.publish();
      return this.result(false, 'blocked', '旧账号云任务状态不确定，请重启应用后再退出账号');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线请求已被更新的账号操作替代');
    }
    HostSyncService.getInstance().clearForScopeTransition();
    KeyVaultService.getInstance().clearForScopeTransition();
    if (!RustDeskProCredentialStore.getInstance()
      .clearForScopeTransition()) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1,
        'RustDesk Pro 凭据未能从 Asset Store 安全清除');
    }
    const rebound: boolean = await store.rebindScope(this.context, next);
    if (!rebound) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线数据域打开失败');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线请求已被更新的账号操作替代');
    }
    if (!(await accountKit.clearCredential())) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '账号凭据清除失败');
    }
    if (!this.intentIsCurrent(intentGeneration)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线请求已被更新的账号操作替代');
    }
    await AuthService.getInstance().logout();
    const nextLoginMode: string =
      reason === 'offline-login' ? 'offline' : '';
    if (!this.persistLoginMode(nextLoginMode)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线登录状态未能持久化');
    }
    this.current = store.currentScope();
    this.current.sessionState = 'offline';
    if (!store.activateScope(this.current)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        next.generation + 1, '离线数据域状态发布失败');
    }
    this.reloadScopeServices();
    this.publish();
    return this.result(true, 'offline', '');
  }

  /**
   * A failed target commit reopens the previous physical store under a fresh
   * generation, then restores both durable credentials and in-memory auth.
   * If any rollback component fails, fall back to an explicitly logged-out
   * device-local scope instead of publishing a mixed identity/store state.
   */
  private async restorePreviousScope(
    previous: AccountScopeToken,
    previousCredential: StoredCredential | null,
    previousAuth: UserAccountJSON,
    generation: number,
    message: string
  ): Promise<AccountTransitionResult> {
    if (this.context === null) {
      return this.result(false, 'blocked', message);
    }
    const rollback: AccountScopeToken = this.cloneScope(previous);
    rollback.generation = Math.max(1, Math.floor(generation));
    rollback.sessionState = rollback.kind === 'device_local' ? 'offline' : 'ready';
    const previousUnionId: string = previousCredential !== null
      ? previousCredential.unionID : previousAuth.unionId;
    const store: CloudStore = CloudStore.getInstance();
    let previousPlatformProof: PlatformCloudIdentityProof =
      unavailablePlatformCloudIdentityProof();
    if (rollback.kind === 'huawei_account') {
      previousPlatformProof =
        await PlatformCloudIdentityService.getInstance()
          .proveCurrentCloudAccount(
            this.context, previousUnionId);
      if (!platformCloudIdentityProofIsValid(
        previousPlatformProof) ||
        previousPlatformProof.fingerprint !==
          rollback.platformIdentityFingerprint) {
        return await this.recoverDeviceLocal(
          rollback.generation + 1,
          message + '；平台云账号已变化，旧账号不可安全回滚');
      }
    }
    const rebound: boolean = await store.rebindScope(
      this.context, rollback, previousUnionId,
      previousPlatformProof);
    const credentialRestored: boolean =
      await AccountKitService.getInstance()
        .restoreCredentialSnapshot(previousCredential);
    if (!rebound || !credentialRestored) {
      return await this.recoverDeviceLocal(
        rollback.generation + 1, message + '；旧账号回滚失败');
    }
    AuthService.getInstance().restoreSessionSnapshot(previousAuth);
    if (!this.persistLoginMode(this.transitionLoginModeSnapshot)) {
      return await this.recoverDeviceLocal(
        rollback.generation + 1, message + '；登录状态回滚失败');
    }
    this.current = store.currentScope();
    this.current.sessionState = rollback.sessionState;
    if (!store.activateScope(this.current)) {
      return await this.recoverDeviceLocal(
        rollback.generation + 1, message + '；旧账号数据域恢复失败');
    }
    this.reloadScopeServices();
    this.publish();
    return this.result(false, this.current.sessionState, message);
  }

  private reloadScopeServices(): void {
    if (this.context === null) { return; }
    HostSyncService.getInstance().reloadForScopeTransition();
    KeyVaultService.getInstance().reloadForScopeTransition();
    RustDeskProCredentialStore.getInstance()
      .bindScope(this.context, this.current.ownerScopeId);
    ActiveRemoteSessionRegistry.getInstance()
      .bindScope(this.current.ownerScopeId, this.current.generation);
    this.bindMoonlightScope();
  }

  private bindMoonlightScope(): void {
    const lease = CloudStore.getInstance().currentAccountLease();
    if (lease === null ||
        !MoonlightDataLifecycleBarrier.getInstance().bindScope(lease)) {
      hilog.error(0x0001, 'AccountSession',
        'Moonlight scope binding failed; feature remains closed');
    }
  }

  private async recoverDeviceLocal(generation: number, message: string): Promise<AccountTransitionResult> {
    if (this.context === null) { return this.result(false, 'blocked', message); }
    await AuthService.getInstance().logout();
    await AccountKitService.getInstance().clearCredential();
    this.persistLoginMode('');
    const fallback: AccountScopeToken = deviceLocalScopeToken(generation);
    const store: CloudStore = CloudStore.getInstance();
    const recovered: boolean = await store.rebindScope(this.context, fallback);
    this.current = this.cloneScope(fallback);
    if (!recovered || !store.activateScope(this.current)) {
      this.current.sessionState = 'blocked';
    }
    this.reloadScopeServices();
    this.publish();
    return this.result(false, recovered ? 'offline' : 'blocked', message);
  }

  private readLoginMode(): string {
    if (this.context === null) { return ''; }
    try {
      const prefs = preferences.getPreferencesSync(
        this.context, { name: ACCOUNT_SESSION_PREFS });
      return prefs.getSync(LOGIN_MODE_KEY, '') as string;
    } catch (_error) {
      return '';
    }
  }

  private persistLoginMode(mode: string): boolean {
    if (this.context === null) { return false; }
    try {
      const prefs = preferences.getPreferencesSync(
        this.context, { name: ACCOUNT_SESSION_PREFS });
      prefs.putSync(LOGIN_MODE_KEY, mode);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  private intentIsCurrent(generation: number): boolean {
    return generation > 0 && generation === this.transitionIntentGeneration;
  }

  private result(ok: boolean, state: string, message: string): AccountTransitionResult {
    return { ok, state, message, scope: this.cloneScope(this.current) };
  }

  private cloneScope(scope: AccountScopeToken): AccountScopeToken {
    return {
      kind: scope.kind,
      ownerScopeId: scope.ownerScopeId,
      generation: scope.generation,
      sessionState: scope.sessionState,
      cloudBindingState: scope.cloudBindingState,
      storeIdentity: scope.storeIdentity,
      schemaRevision: scope.schemaRevision,
      selectionRevision: scope.selectionRevision,
      platformIdentityFingerprint:
        scope.platformIdentityFingerprint
    };
  }

  private platformIdentityFailureMessage(
    proof: PlatformCloudIdentityProof
  ): string {
    if (proof.state === 'permission_denied') {
      return '未授权分布式数据访问，无法验证当前华为云账号';
    }
    if (proof.state === 'not_logged_in') {
      return '系统当前没有已登录的分布式华为账号';
    }
    if (proof.state === 'identity_mismatch') {
      return 'Account Kit 账号与系统云账号无法建立可信对应，云同步已停止';
    }
    return '无法独立验证当前平台云账号，云同步已安全停止';
  }

  private publish(): void {
    const snapshot: AccountScopeToken = this.cloneScope(this.current);
    const listeners: Array<(scope: AccountScopeToken) => void> = this.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try { listeners[i](this.cloneScope(snapshot)); } catch (_err) { /* isolate listeners */ }
    }
  }
}
