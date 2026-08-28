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
  ACCOUNT_CLOUD_STORE_IDENTITY,
  accountLocalCompatibilityScopeToken,
  accountStoreIdentity,
  cloudAccountBindingForScope,
  accountScopeToken,
  deviceLocalScopeToken,
  ownerScopeIdForUnionId
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
  PlatformCloudIdentityProofState,
  platformCloudIdentityProofIsValid,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';
import { PlatformCloudIdentityService } from './PlatformCloudIdentityService';
import {
  CloudSyncCoordinator,
  CloudSyncOperationResult
} from './CloudSyncCoordinator';
import { cloudFirstTablesForSelectionFinalization } from './CloudSyncCoordinatorPolicy';
import { cloudTransferAllowed } from './CloudLifecycleSafetyPolicy';
import { safeError } from '../utils/SafeLogger';
import { MoonlightDataLifecycleBarrier } from './MoonlightDataLifecycleBarrier';
import { MoonlightDataLifecycleRuntime } from './MoonlightDataLifecycleRuntime';
import { AppCloneContext } from './AppCloneContext';
import { RemoteSessionWindowCoordinator } from './RemoteSessionWindowCoordinator';
import { ExtensionLoader } from './ExtensionLoader';
import {
  RemoteSessionTransitionGate,
  RemoteSessionTransitionLease
} from './RemoteSessionTransitionGate';
import {
  CLOUD_BINDING_RECOVERY_PREFERENCES_NAME,
  CloudBindingRecoveryState,
  CloudBindingRecoverySourceAuthority,
  cloudBindingRecoveryAfterProof,
  cloudBindingRecoveryAfterRollback,
  cloudBindingRecoveryIsPending,
  cloudBindingRecoveryRepeatedDialogBlocked,
  cloudBindingRecoveryRequested,
  cloudBindingRecoverySourceAuthorityKey,
  cloudBindingRecoverySourceAuthorityInspect,
  cloudBindingRecoverySourceAuthorityValue
} from './CloudBindingRecoveryPolicy';

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

const ACCOUNT_SESSION_PREFS: string =
  CLOUD_BINDING_RECOVERY_PREFERENCES_NAME;
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
  private platformCloudIdentityState:
    PlatformCloudIdentityProofState =
      'identity_unavailable';
  private cloudBindingRecoveryState:
    CloudBindingRecoveryState = 'idle';
  private cloudIdentityRecoveryPromise:
    Promise<boolean> | null = null;

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

  /**
   * Retry only the permission-dialog race recorded by the preceding account
   * transition. An explicit user denial never enters this path. Rebinding is
   * coordinator-owned because a newly verified identity must move the same
   * account from its local-only hashed store to the canonical cloud store;
   * retrying setDistributedTables on the old store can never succeed.
   */
  async resumePendingCloudBindingAfterForeground():
    Promise<boolean> {
    const store: CloudStore = CloudStore.getInstance();
    if (store.isCloudAvailable()) {
      this.cloudBindingRecoveryState = 'idle';
      return true;
    }
    if (!this.initialized || this.context === null ||
        this.current.kind !== 'huawei_account' ||
        this.current.sessionState !== 'ready' ||
        !cloudBindingRecoveryIsPending(
          this.cloudBindingRecoveryState)) {
      return false;
    }
    if (this.remoteSessionBlocksCloudIdentityRecovery()) {
      hilog.info(0x0001, 'AccountSession',
        '平台云身份恢复已延后：当前仍有远程会话');
      return false;
    }
    if (this.cloudIdentityRecoveryPromise !== null) {
      return await this.cloudIdentityRecoveryPromise;
    }
    // Recovery is subordinate to explicit login/logout intent. Capture the
    // current generation without advancing it, so a user action always
    // supersedes an in-flight foreground retry.
    const intentGeneration: number =
      this.transitionIntentGeneration;
    const operation: Promise<boolean> = this.serialize(
      (): Promise<AccountTransitionResult> =>
        this.doResumePendingCloudBinding(
          intentGeneration)).then(
      (result: AccountTransitionResult): boolean =>
        result.ok);
    this.cloudIdentityRecoveryPromise = operation;
    try {
      return await operation;
    } finally {
      if (this.cloudIdentityRecoveryPromise === operation) {
        this.cloudIdentityRecoveryPromise = null;
      }
    }
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
    const requested: AccountScopeToken | null =
      accountScopeToken(
        identity.unionID, generation, 'switching', 'validating',
        platformProof);
    if (requested === null) {
      return this.result(false, 'blocked', '账号没有返回稳定的 UnionID');
    }
    const expectedLocalStoreIdentity: string =
      accountStoreIdentity(requested.ownerScopeId);
    const switching: AccountScopeToken = requested;
    const sourceAuthority: CloudBindingRecoverySourceAuthority =
      this.readCloudRecoverySourceAuthority(
        requested.ownerScopeId,
        expectedLocalStoreIdentity);
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

    let rebound: boolean = await store.rebindScope(
      this.context, switching, identity.unionID, platformProof);
    let compatibilityFallbackUsed: boolean = false;
    let primaryRebindFailure: string = 'none';
    if (!rebound) {
      primaryRebindFailure =
        store.lastScopeRebindFailureKind();
      const localFallback: AccountScopeToken | null =
        accountLocalCompatibilityScopeToken(switching);
      if (localFallback !== null &&
        this.intentIsCurrent(intentGeneration)) {
        hilog.warn(0x0001, 'AccountSession',
          '规范账号库初始化未完成，兼容降级到同账号本地库；登录继续，云绑定稍后重试 failureKind=' +
          primaryRebindFailure);
        rebound = await store.rebindScope(
          this.context, localFallback,
          identity.unionID, platformProof, true);
        compatibilityFallbackUsed = rebound;
      }
    }
    if (!rebound) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '账号物理数据域打开失败');
    }

    const currentScope: AccountScopeToken = store.currentScope();
    let cloudRecoveryBaselineReady: boolean = true;
    let capturedRecoveryFingerprint: string = '';
    let recoveryBaselineStoredInSource: boolean = false;
    if (currentScope.storeIdentity !==
        ACCOUNT_CLOUD_STORE_IDENTITY) {
      if (sourceAuthority.state === 'recoverable_source') {
        cloudRecoveryBaselineReady = true;
      } else if (sourceAuthority.state === 'absent' &&
          primaryRebindFailure !== 'source_changed') {
        const baselineCapture =
          store.capturePendingCloudBindingSourceBaseline();
        capturedRecoveryFingerprint =
          baselineCapture.fingerprint;
        recoveryBaselineStoredInSource =
          baselineCapture.storedInSource;
        cloudRecoveryBaselineReady =
          recoveryBaselineStoredInSource ||
          capturedRecoveryFingerprint !== '';
      } else {
        // An older process may already have admitted local writes. Capturing a
        // new baseline now would incorrectly classify those rows as unchanged.
        cloudRecoveryBaselineReady = false;
      }
      if (!cloudRecoveryBaselineReady) {
        hilog.error(0x0001, 'AccountSession',
          '本地兼容数据域缺少可证明的写入前基线；自动云绑定保持关闭');
      }
    }
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
      const finalizedTables: string[] =
        cloudFirstTablesForSelectionFinalization(
          bootstrap.ok, bootstrap.tables,
          bootstrap.failedTables);
      if (finalizedTables.length > 0) {
        if (!store.markStartupSelectionReenablePulled(
          finalizedTables) ||
          !store.prepareSelectionReenablePromotions()) {
          // The authoritative data transaction is already committed. Keep
          // the selection barrier closed and retry its metadata on a later
          // foreground; never roll the downloaded account data back here.
          hilog.warn(0x0001, 'AccountSession',
            '首次云端核对已提交，但同步范围 promotion 延后；上传保持暂停');
        }
      }
    } else if (cloudAccountBindingForScope(currentScope).state === 'bound' &&
      !store.isCloudAvailable()) {
      hilog.warn(0x0001, 'AccountSession',
        '华为账号本地登录成功，但云端存储不可用（setDistributedTables 失败或云空间未开通），跳过 cloud-first，保持本地可用');
    } else if (platformProof.state === 'permission_denied' ||
      platformProof.state === 'permission_dialog_blocked' ||
      platformProof.state === 'permission_unavailable' ||
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
    let recoverySourceAuthorityValue: string = '';
    if (currentScope.storeIdentity !== ACCOUNT_CLOUD_STORE_IDENTITY) {
      if (sourceAuthority.state === 'recoverable_source' ||
          sourceAuthority.state === 'local_source') {
        recoverySourceAuthorityValue =
          sourceAuthority.persistedValue;
      } else if (sourceAuthority.state === 'uncertain' ||
          primaryRebindFailure === 'source_changed') {
        recoverySourceAuthorityValue =
          cloudBindingRecoverySourceAuthorityValue(
            expectedLocalStoreIdentity, '');
      } else if (!recoveryBaselineStoredInSource) {
        recoverySourceAuthorityValue =
          cloudBindingRecoverySourceAuthorityValue(
            expectedLocalStoreIdentity,
            capturedRecoveryFingerprint);
      }
    }
    if (!this.persistAccountLoginState(
      currentScope.ownerScopeId,
      recoverySourceAuthorityValue)) {
      return await this.restorePreviousScope(
        previousScope, previousCredential, previousAuth,
        generation + 1, '登录状态未能持久化');
    }

    this.current = currentScope;
    this.current.sessionState = 'ready';
    this.platformCloudIdentityState =
      platformProof.state;
    this.cloudBindingRecoveryState =
      compatibilityFallbackUsed && cloudRecoveryBaselineReady
        ? (primaryRebindFailure === 'source_changed' ||
            primaryRebindFailure === 'identity_conflict'
          ? 'blocked' : 'binding_pending')
        : cloudBindingRecoveryRequested(
          platformProof.state, cloudBound);
    if (!cloudRecoveryBaselineReady) {
      this.cloudBindingRecoveryState = 'blocked';
    }
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

  private async doResumePendingCloudBinding(
    intentGeneration: number
  ): Promise<AccountTransitionResult> {
    if (this.context === null || !this.initialized ||
        !this.intentIsCurrent(intentGeneration) ||
        !cloudBindingRecoveryIsPending(
          this.cloudBindingRecoveryState)) {
      return this.result(false, this.current.sessionState,
        '平台云身份恢复条件已变化');
    }
    const accountKit: AccountKitService =
      AccountKitService.getInstance();
    const credential: StoredCredential | null =
      accountKit.credentialSnapshot();
    const auth: UserAccountJSON =
      AuthService.getInstance().sessionSnapshot();
    if (credential === null ||
        credential.unionID.trim() === '' ||
        !auth.isLoggedIn ||
        auth.unionId !== credential.unionID ||
        ownerScopeIdForUnionId(credential.unionID) !==
          this.current.ownerScopeId) {
      this.platformCloudIdentityState =
        'identity_mismatch';
      this.cloudBindingRecoveryState = 'blocked';
      return this.result(false, this.current.sessionState,
        '当前账号凭据与本地数据域不一致');
    }
    if (this.remoteSessionBlocksCloudIdentityRecovery()) {
      return this.result(false, this.current.sessionState,
        '远程会话结束后再恢复云同步');
    }
    const proof: PlatformCloudIdentityProof =
      await PlatformCloudIdentityService.getInstance()
        .proveCurrentCloudAccount(
          this.context, credential.unionID);
    if (!this.intentIsCurrent(intentGeneration)) {
      return this.result(false, 'superseded',
        '云身份恢复已被新的账号操作替代');
    }
    if (!platformCloudIdentityProofIsValid(proof)) {
      const repeatedBlockedDialog: boolean =
        cloudBindingRecoveryRepeatedDialogBlocked(
          this.platformCloudIdentityState,
          proof.state);
      this.platformCloudIdentityState = proof.state;
      this.cloudBindingRecoveryState =
        repeatedBlockedDialog
          ? 'blocked'
          : cloudBindingRecoveryAfterProof(proof.state);
      if (repeatedBlockedDialog) {
        this.platformCloudIdentityState =
          'permission_denied';
      }
      hilog.warn(0x0001, 'AccountSession',
        '前台平台云身份恢复未完成 state=' +
        proof.state);
      return this.result(false, this.current.sessionState,
        repeatedBlockedDialog
          ? '系统仍未展示权限窗口，已停止自动重试；请重新登录后授权'
          : this.platformIdentityFailureMessage(proof));
    }
    // Permission proof may have displayed a system surface. Re-check the
    // session boundary immediately before closing the mutation gate; a remote
    // connection started while awaiting that UI must never be drained by a
    // background cloud repair.
    if (this.remoteSessionBlocksCloudIdentityRecovery()) {
      return this.result(false, this.current.sessionState,
        '远程会话结束后再恢复云同步');
    }
    const remoteTransitionGate: RemoteSessionTransitionGate =
      RemoteSessionTransitionGate.getInstance();
    const remoteTransitionLease:
      RemoteSessionTransitionLease | null =
      remoteTransitionGate.tryAcquire();
    if (remoteTransitionLease === null) {
      return this.result(false, this.current.sessionState,
        '远程会话正在启动，稍后再恢复云同步');
    }
    try {
      // Acquisition synchronously closes native/window admission. This second
      // idle proof is therefore stable for the entire destructive barrier.
      if (this.remoteSessionBlocksCloudIdentityRecovery()) {
        return this.result(false, this.current.sessionState,
          '远程会话正在启动，稍后再恢复云同步');
      }
    this.platformCloudIdentityState = proof.state;
    this.cloudBindingRecoveryState =
      cloudBindingRecoveryAfterProof(proof.state);
    const previousScope: AccountScopeToken =
      this.cloneScope(this.current);
    const target: AccountScopeToken | null =
      accountScopeToken(
        credential.unionID,
        previousScope.generation + 1,
        'switching', 'validating', proof);
    if (target === null) {
      this.platformCloudIdentityState =
        'identity_mismatch';
      this.cloudBindingRecoveryState = 'blocked';
      return this.result(false, this.current.sessionState,
        '当前账号无法建立云数据域');
    }
    const store: CloudStore = CloudStore.getInstance();
    if (!store.closeMutationGate()) {
      return this.result(false, this.current.sessionState,
        '云身份恢复时数据写入闸门关闭失败');
    }
    if (!(await SensitiveDataBarrier.getInstance()
        .drain('cloud-identity-recovery'))) {
      store.activateScope(this.current);
      return this.result(false, this.current.sessionState,
        '云身份恢复等待当前任务结束');
    }
    if (!(await store.quiesceCurrentScope()) ||
        !this.intentIsCurrent(intentGeneration)) {
      store.activateScope(this.current);
      return this.result(false, this.current.sessionState,
        this.intentIsCurrent(intentGeneration)
          ? '旧数据域云任务尚未结束'
          : '云身份恢复已被新的账号操作替代');
    }
    HostSyncService.getInstance().clearForScopeTransition();
    KeyVaultService.getInstance().clearForScopeTransition();
    // This is a physical-store upgrade for the same owner, not an account
    // change. Drop decrypted memory only; revoking Asset Store tokens here
    // would damage an unrelated RustDesk Pro login.
    RustDeskProCredentialStore.getInstance()
      .clearMemoryForScopeTransition();
    const rebound: boolean = await store.rebindScope(
      this.context, target, credential.unionID, proof);
    if (!rebound || !this.intentIsCurrent(intentGeneration)) {
      const rebindFailure: string =
        store.lastScopeRebindFailureKind();
      const retryable: boolean =
        this.intentIsCurrent(intentGeneration) &&
        (rebindFailure === 'none' ||
          rebindFailure === 'transient');
      if (!retryable && this.intentIsCurrent(intentGeneration)) {
        this.platformCloudIdentityState =
          rebindFailure === 'identity_conflict'
            ? 'identity_mismatch' : 'verified';
      }
      return await this.restorePendingCloudBindingScope(
        previousScope, credential.unionID, proof,
        target.generation + 1,
        !this.intentIsCurrent(intentGeneration)
          ? '云身份恢复已被新的账号操作替代'
          : rebindFailure === 'source_changed'
            ? '本地兼容数据域在迁移后仍有新修改，已拒绝自动切库以保护数据'
            : '规范云数据域打开失败',
        retryable);
    }
    const recovered: AccountScopeToken =
      store.currentScope();
    recovered.sessionState = 'ready';
    if (recovered.cloudBindingState !== 'bound' ||
        !store.activateScope(recovered)) {
      const retryable: boolean =
        store.lastScopeRebindFailureKind() === 'none' ||
        store.lastScopeRebindFailureKind() === 'transient';
      this.platformCloudIdentityState = retryable ||
        store.lastScopeRebindFailureKind() === 'source_changed'
        ? 'verified' : 'identity_mismatch';
      return await this.restorePendingCloudBindingScope(
        previousScope, credential.unionID, proof,
        recovered.generation + 1,
        '平台账号已验证，但规范云数据域未能安全绑定',
        retryable);
    }
    this.current = recovered;
    this.platformCloudIdentityState = 'verified';
    this.cloudBindingRecoveryState = 'idle';
    this.reloadScopeServices();
    this.publish();
    hilog.info(0x0001, 'AccountSession',
      '前台平台云身份恢复成功，已重绑规范云数据域');
    return this.result(true, 'ready', '');
    } finally {
      remoteTransitionGate.release(
        remoteTransitionLease);
    }
  }

  private async restorePendingCloudBindingScope(
    previous: AccountScopeToken,
    unionId: string,
    verifiedProof: PlatformCloudIdentityProof,
    generation: number,
    message: string,
    retryable: boolean
  ): Promise<AccountTransitionResult> {
    if (this.context === null) {
      this.cloudBindingRecoveryState = 'blocked';
      return this.result(false, 'blocked', message);
    }
    const rollback: AccountScopeToken =
      this.cloneScope(previous);
    rollback.generation = Math.max(
      1, Math.floor(generation));
    rollback.sessionState = 'ready';
    const rollbackProof: PlatformCloudIdentityProof =
      rollback.platformIdentityFingerprint ===
        verifiedProof.fingerprint
        ? verifiedProof
        : unavailablePlatformCloudIdentityProof(
          'permission_unavailable');
    const store: CloudStore = CloudStore.getInstance();
    const preserveCompatibilityStore: boolean =
      rollback.kind === 'huawei_account' &&
      rollback.storeIdentity !== ACCOUNT_CLOUD_STORE_IDENTITY;
    const restored: boolean = await store.rebindScope(
      this.context, rollback, unionId,
      rollbackProof, preserveCompatibilityStore);
    if (!restored) {
      this.cloudBindingRecoveryState =
        cloudBindingRecoveryAfterRollback(false, retryable);
      this.current = rollback;
      this.current.sessionState = 'blocked';
      this.publish();
      return this.result(false, 'blocked',
        message + '；原本地数据域恢复失败');
    }
    this.current = store.currentScope();
    this.current.sessionState = 'ready';
    if (!store.activateScope(this.current)) {
      this.cloudBindingRecoveryState =
        cloudBindingRecoveryAfterRollback(false, retryable);
      this.current.sessionState = 'blocked';
      this.publish();
      return this.result(false, 'blocked',
        message + '；原本地数据域激活失败');
    }
    this.cloudBindingRecoveryState =
      cloudBindingRecoveryAfterRollback(true, retryable);
    this.reloadScopeServices();
    this.publish();
    return this.result(false, 'ready', message);
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
        const finalizedTables: string[] =
          cloudFirstTablesForSelectionFinalization(
            bootstrap.ok, bootstrap.tables,
            bootstrap.failedTables);
        if (!bootstrap.ok && finalizedTables.length === 0) {
          hilog.warn(0x0001, 'AccountSession',
            '主页已显示；首次云端核对未完成 failureKind=' +
            bootstrap.failureKind + '，云同步继续保持安全暂停');
          return;
        }
        if (!store.resumeSelectionReenableAfterCloudFirst(
          finalizedTables)) {
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
    this.platformCloudIdentityState =
      'not_logged_in';
    this.cloudBindingRecoveryState = 'idle';
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
      previousPlatformProof,
      rollback.kind === 'huawei_account' &&
        rollback.storeIdentity !== ACCOUNT_CLOUD_STORE_IDENTITY);
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
    this.platformCloudIdentityState =
      previousPlatformProof.state;
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
    this.platformCloudIdentityState =
      'not_logged_in';
    this.cloudBindingRecoveryState = 'idle';
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

  private readCloudRecoverySourceAuthority(
    ownerScopeId: string,
    expectedLocalStoreIdentity: string
  ): CloudBindingRecoverySourceAuthority {
    if (this.context === null) {
      return cloudBindingRecoverySourceAuthorityInspect(
        '', expectedLocalStoreIdentity, false);
    }
    const key: string =
      cloudBindingRecoverySourceAuthorityKey(ownerScopeId);
    if (key === '' || expectedLocalStoreIdentity.trim() === '') {
      return cloudBindingRecoverySourceAuthorityInspect(
        '', expectedLocalStoreIdentity, false);
    }
    try {
      const prefs = preferences.getPreferencesSync(
        this.context, { name: ACCOUNT_SESSION_PREFS });
      const stored: Object = prefs.getSync(key, '') as Object;
      if (typeof stored !== 'string') {
        return cloudBindingRecoverySourceAuthorityInspect(
          '', expectedLocalStoreIdentity, false);
      }
      return cloudBindingRecoverySourceAuthorityInspect(
        stored as string, expectedLocalStoreIdentity, true);
    } catch (_error) {
      return cloudBindingRecoverySourceAuthorityInspect(
        '', expectedLocalStoreIdentity, false);
    }
  }

  /**
   * The login mode and recovery-source authority share one Preferences flush.
   * Therefore a session cannot publish local writes after a failed baseline
   * capture unless the next process can identify that exact owner/store and
   * compare it with the pre-write fingerprint (or refuse an unsafe switch).
   */
  private persistAccountLoginState(
    ownerScopeId: string,
    recoverySourceAuthorityValue: string
  ): boolean {
    if (this.context === null) { return false; }
    const key: string =
      cloudBindingRecoverySourceAuthorityKey(ownerScopeId);
    if (key === '') { return false; }
    try {
      const prefs = preferences.getPreferencesSync(
        this.context, { name: ACCOUNT_SESSION_PREFS });
      prefs.putSync(LOGIN_MODE_KEY, 'account');
      if (recoverySourceAuthorityValue !== '') {
        prefs.putSync(key, recoverySourceAuthorityValue);
      } else {
        try {
          if (prefs.hasSync(key)) { prefs.deleteSync(key); }
        } catch (error) {
          // A stale marker only causes another safe source comparison later;
          // marker cleanup is not allowed to roll back an otherwise valid
          // local login.
          hilog.warn(0x0001, 'AccountSession',
            '云恢复旧标记暂未清理；登录继续 err=' + safeError(error));
        }
      }
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  private intentIsCurrent(generation: number): boolean {
    return generation > 0 && generation === this.transitionIntentGeneration;
  }

  private remoteSessionBlocksCloudIdentityRecovery(): boolean {
    return ActiveRemoteSessionRegistry.getInstance()
      .getActive() !== null ||
      RemoteSessionWindowCoordinator.getInstance()
        .hasOpenOrPendingWindows() ||
      ExtensionLoader.getInstance()
        .hasSessionActivity();
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
    if (proof.state === 'permission_unavailable') {
      return '系统权限窗口暂不可用，回到应用前台后将自动恢复云同步';
    }
    if (proof.state === 'permission_dialog_blocked') {
      return '系统权限窗口暂未展示，回到应用前台后将重试一次';
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
