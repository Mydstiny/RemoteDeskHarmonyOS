import { AbilityConstant, common, wantConstant, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { RemoteHost } from '../../model/RemoteHost';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProConnectionDescription, ProConnectionEnvelope, ProConnectionView, parseProConnectionEnvelope,
  PRO_CONNECTION_TTL_MS } from './ProConnectionEnvelope';
import { matchesProConnectionHost, proContinuationHostStoreReady,
  resolveProContinuationHost } from './ProConnectionHostAdapter';
import { ProRdpConnectionIdentity, sameProRdpConnectionIdentity } from './ProRdpConnectionIdentity';
import { ProConnectionTransaction } from './ProConnectionTransaction';
import { ProContinuationReceiptChannel } from './ProContinuationReceiptChannel';
import { ProContinuationCredentialHandoff, ProContinuationSecret,
  validProContinuationSecret } from './ProContinuationCredentials';
import { ProContinuationPreferences, proContinuationProtocolLabel } from './ProContinuationPreferences';

export const PRO_CONTINUATION_PARAM: string = 'remotedesk.pro.connection.v1';
/** Opt-in secret, a separate Want parameter so the whitelisted envelope never carries it. */
export const PRO_CONTINUATION_SECRET_PARAM: string = 'remotedesk.pro.connection.secret.v1';
export const PRO_CONTINUATION_LIBRARY_PARAM: string = 'remotedesk.pro.connection.library';
export const PRO_CONTINUATION_FEATURE: string = 'pro.connection.continuation';
const SYNC_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
const DATA_OBJECT_CAPABILITY: string = 'SystemCapability.DistributedDataManager.DataObject.DistributedObject';
/** Why the last preparation did not activate the system continuation entry. */
export type ProContinuationPrepareFailure = '' | 'ability' | 'pro' | 'source' | 'host' | 'account' | 'permission' |
  'changed' | 'mission' | 'disabled';
/** User-facing explanation for a preparation failure; never includes host or account details. */
export function proContinuationFailureText(reason: ProContinuationPrepareFailure): string {
  if (reason === 'pro') { return '无法准备接续：需要有效的 Pro，且当前设备和协议受支持'; }
  if (reason === 'host') { return '无法准备接续：此主机不属于当前登录账号，或已被修改，请重新打开主机'; }
  if (reason === 'account') { return '无法准备接续：请先登录华为账号'; }
  if (reason === 'permission') { return '无法准备接续：需要允许"多设备协同"权限'; }
  if (reason === 'disabled') { return '此协议的接续已在 Pro 功能 > 同账号接续中关闭'; }
  if (reason === 'mission') { return '无法准备接续：系统拒绝开启接续，请确认系统"接续"开关已打开'; }
  if (reason === 'source' || reason === 'changed') { return '无法准备接续：会话、页面或账号已变化，请重试'; }
  return '无法准备接续：当前窗口不支持接续';
}
export interface ProContinuationSource {
  windowId: number;
  describe: () => ProConnectionDescription | null;
  isCurrent: () => boolean;
  close: () => void;
  /** Stored secret for this session; offered only when the user enabled credential transfer. */
  secret?: () => ProContinuationSecret | null;
}
export interface ProContinuationSnapshot {
  incoming: boolean;
  incomingCanAccept: boolean;
  incomingLabel: string;
  incomingProtocol: string;
  incomingEndpoint: string;
  incomingMessage: string;
  sourceWindow: number;
  sourceMessage: string;
  sourceCloseAllowed: boolean;
}
function randomHex(): string {
  const bytes = cryptoFramework.createRandom().generateRandomSync(16).data;
  let value: string = '';
  bytes.forEach((byte: number): void => { value += byte.toString(16).padStart(2, '0'); });
  return value;
}
export function proContinuationContext(protocol: string = 'ssh'): ProAccessContext {
  const context = ProAppRuntime.getInstance().context(protocol);
  if (canIUse(DATA_OBJECT_CAPABILITY)) { context.capabilities.push(DATA_OBJECT_CAPABILITY); }
  context.requestablePermissions = [SYNC_PERMISSION];
  return context;
}
/** One explicitly prepared source per process, bound to its main or independent session window. */
export class ProContinuationService {
  private static instance: ProContinuationService;
  private listeners: Array<() => void> = [];
  private source: ProContinuationSource | null = null;
  private sourceContext: common.UIAbilityContext | null = null;
  private sourceOwner: string = '';
  private prepareFailure: ProContinuationPrepareFailure = '';
  private sourceAccountGeneration: number = 0;
  private sourceTransaction: ProConnectionTransaction | null = null;
  private sourceChannel: ProContinuationReceiptChannel = new ProContinuationReceiptChannel();
  private sourceGeneration: number = 0;
  private sourceTimer: number = -1;
  private sourceMessage: string = '';
  private sourceDeadline: number = 0;
  private missionOperation: Promise<void> = Promise.resolve();
  private target: ProConnectionTransaction | null = null;
  private targetContext: common.UIAbilityContext | null = null;
  private targetChannel: ProContinuationReceiptChannel = new ProContinuationReceiptChannel();
  private targetSecret: ProContinuationSecret | null = null;
  private targetAccountGeneration: number = 0;
  private targetGeneration: number = 0;
  private targetTimer: number = -1;
  private targetMessage: string = '';
  private seen: Map<string, number> = new Map<string, number>();
  private transitionActive: boolean = true;
  static getInstance(): ProContinuationService {
    if (!ProContinuationService.instance) { ProContinuationService.instance = new ProContinuationService(); }
    return ProContinuationService.instance;
  }
  private constructor() {
    AccountSessionCoordinator.getInstance().onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      if (active) {
        this.cancelSource();
        const scope = AccountSessionCoordinator.getInstance().currentScope();
        if (this.target?.state() !== 'offered' || scope.kind === 'huawei_account') {
          this.cancelIncoming();
        } else {
          // A cold official Want can precede account bootstrap. This is only
          // unconfirmed data: invalidate pending acceptance, retain no channel
          // or account lease, and validate the final account on explicit accept.
          this.targetGeneration++; this.targetContext = null;
        }
      }
      this.publish();
    });
    ProAppRuntime.getInstance().runtime.subscribe((): void => {
      if (this.source !== null && !this.sourceCurrent()) { this.cancelSource(); }
      const scope = AccountSessionCoordinator.getInstance().currentScope();
      if ((this.target?.state() === 'connecting' || this.target?.state() === 'ready') &&
          (scope.generation !== this.targetAccountGeneration ||
            !this.allowed(this.target?.envelope()?.connection.protocol ?? ''))) { this.cancelIncoming(); }
      this.publish();
    });
  }
  private allowed(protocol: string): boolean {
    if (this.transitionActive) { return false; }
    // Permission is separately checked against the platform before joining.
    const context = proContinuationContext(protocol); context.grantedPermissions = [SYNC_PERMISSION];
    return ProAppRuntime.getInstance().runtime.decision(PRO_CONTINUATION_FEATURE, context).executable;
  }
  private async permission(context: common.UIAbilityContext, request: boolean = true): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const token = context.applicationInfo.accessTokenId;
      if (await manager.checkAccessToken(token, SYNC_PERMISSION) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      if (!request) { return false; }
      const result = await manager.requestPermissionsFromUser(context, [SYNC_PERMISSION]);
      return result.authResults.length === 1 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_error) { return false; }
  }
  private sourceCurrent(): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const description = this.source?.describe() ?? null;
    return this.source !== null && this.sourceContext !== null && Date.now() < this.sourceDeadline && this.source.isCurrent() &&
      this.descriptionAllowed(description, this.sourceContext) && this.allowed(description?.protocol ?? '') &&
      scope.kind === 'huawei_account' && scope.ownerScopeId === this.sourceOwner &&
      scope.generation === this.sourceAccountGeneration &&
      ['bound', 'ready', 'offline'].indexOf(scope.sessionState) >= 0;
  }
  private descriptionAllowed(description: ProConnectionDescription | null, context: common.Context): boolean {
    if (description === null || !proContinuationHostStoreReady(description.protocol)) { return false; }
    const host = resolveProContinuationHost(description.protocol, description.hostReference);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return host !== null && host.userId === scope.ownerScopeId &&
      matchesProConnectionHost(description, host, context);
  }
  private setMission(context: common.UIAbilityContext, state: AbilityConstant.ContinueState): Promise<void> {
    // Serialize ACTIVE/INACTIVE so an old cancellation cannot hide a later preparation.
    const operation = this.missionOperation.then((): Promise<void> => context.setMissionContinueState(state));
    this.missionOperation = operation.catch((): void => {});
    return operation;
  }
  initializeMission(context: common.UIAbilityContext): void {
    // A continuable manifest defaults to ACTIVE. Keep every fresh mission off
    // until an explicitly authorized source is prepared.
    void this.setMission(context, AbilityConstant.ContinueState.INACTIVE).catch((): void => {});
  }
  private async boundedJoin(channel: ProContinuationReceiptChannel, context: common.UIAbilityContext,
    envelope: ProConnectionEnvelope, onReceipt: (value: string) => boolean,
    onAcknowledged: () => void): Promise<boolean> {
    let timer: number = -1;
    const timeout = new Promise<boolean>((resolve: (value: boolean) => void): void => {
      timer = setTimeout((): void => { resolve(false); }, 2500);
    });
    try {
      const joined = await Promise.race([channel.join(context, envelope.channelId, envelope.expiresAt,
        onReceipt, onAcknowledged), timeout]);
      if (!joined) { channel.close(); }
      return joined;
    } catch (_error) { channel.close(); return false; }
    finally { if (timer !== -1) { clearTimeout(timer); } }
  }
  lastPrepareFailure(): ProContinuationPrepareFailure { return this.prepareFailure; }
  private rejectPrepare(reason: ProContinuationPrepareFailure): boolean {
    this.prepareFailure = reason;
    hilog.warn(0x0001, 'ProContinuation', 'prepare rejected reason=%{public}s', reason);
    return false;
  }
  /** Whether a source window currently offers continuation. */
  armed(windowId: number): boolean { return windowId > 0 && this.source?.windowId === windowId && this.sourceCurrent(); }
  /**
   * persistent: the always-on Pro mode. It stays armed while the session is current (no two-minute
   * window) and never raises the permission dialog on its own; the explicit menu action does.
   */
  async prepare(context: common.UIAbilityContext, source: ProContinuationSource, persistent: boolean = false,
    requestPermission: boolean = !persistent): Promise<boolean> {
    this.cancelSource();
    this.prepareFailure = '';
    const protocol = source.describe()?.protocol ?? '';
    if (['EntryAbility', 'RemoteSessionAbility'].indexOf(context.abilityInfo.name) < 0 ||
        !Number.isInteger(source.windowId) || source.windowId <= 0) { return this.rejectPrepare('ability'); }
    if (!this.allowed(protocol)) { return this.rejectPrepare('pro'); }
    ProContinuationPreferences.getInstance().load(context);
    if (!ProContinuationPreferences.getInstance().protocolEnabled(protocol)) { return this.rejectPrepare('disabled'); }
    if (!source.isCurrent()) { return this.rejectPrepare('source'); }
    if (!this.descriptionAllowed(source.describe(), context)) { return this.rejectPrepare('host'); }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (scope.kind !== 'huawei_account' || !/^owner-[a-f0-9]{64}$/.test(scope.ownerScopeId)) { return this.rejectPrepare('account'); }
    const generation = this.sourceGeneration;
    if (!await this.permission(context, requestPermission)) {
      return generation === this.sourceGeneration ? this.rejectPrepare('permission') : false;
    }
    if (generation !== this.sourceGeneration || !this.allowed(protocol) ||
        !source.isCurrent() || !this.descriptionAllowed(source.describe(), context) ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation) {
      return this.rejectPrepare('changed');
    }
    this.source = source; this.sourceContext = context; this.sourceOwner = scope.ownerScopeId;
    this.sourceAccountGeneration = scope.generation;
    this.sourceDeadline = persistent ? Number.MAX_SAFE_INTEGER : Date.now() + PRO_CONNECTION_TTL_MS;
    if (!persistent) {
      this.sourceTimer = setTimeout((): void => { if (generation === this.sourceGeneration) { this.cancelSource(); } }, PRO_CONNECTION_TTL_MS);
    }
    try {
      await this.setMission(context, AbilityConstant.ContinueState.ACTIVE);
      if (generation !== this.sourceGeneration || !this.sourceCurrent()) {
        if (generation === this.sourceGeneration) { this.cancelSource(source.windowId); }
        return this.rejectPrepare('changed');
      }
      hilog.info(0x0001, 'ProContinuation', 'prepare active protocol=%{public}s persistent=%{public}s', protocol,
        persistent ? 'true' : 'false');
      this.sourceMessage = persistent ? '已开启：可在同账号设备的系统接续入口继续' :
        '已准备接续，请在 2 分钟内从另一台同账号设备的系统入口继续';
      this.publish(); return true;
    } catch (error) {
      hilog.warn(0x0001, 'ProContinuation', 'setMissionContinueState failed code=%{public}d',
        (error as BusinessError).code ?? -1);
      if (generation === this.sourceGeneration) { this.cancelSource(); }
      return this.rejectPrepare('mission');
    }
  }
  async onContinue(windowId: number, parameters: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const source = this.source; const context = this.sourceContext;
    if (source === null || context === null || source.windowId !== windowId || !this.sourceCurrent() ||
        this.sourceTransaction !== null) { return AbilityConstant.OnContinueResult.REJECT; }
    const description = source.describe();
    if (description === null || !ProContinuationPreferences.getInstance().protocolEnabled(description.protocol)) {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    const generation = this.sourceGeneration;
    const now = Date.now();
    const envelope: ProConnectionEnvelope = { version: description.protocol === 'rdp' ? 2 :
      (description.protocol === 'ssh' ? 1 : 3),
      purpose: 'continuation', transferId: randomHex(),
      channelId: 'rd_' + randomHex(), owner: this.sourceOwner, createdAt: now,
      expiresAt: now + PRO_CONNECTION_TTL_MS, connection: description };
    const serialized = JSON.stringify(envelope);
    if (parseProConnectionEnvelope(serialized) === null) { return AbilityConstant.OnContinueResult.REJECT; }
    const transaction = new ProConnectionTransaction(envelope);
    this.sourceTransaction = transaction;
    this.sourceDeadline = envelope.expiresAt;
    if (this.sourceTimer !== -1) { clearTimeout(this.sourceTimer); }
    this.sourceTimer = setTimeout((): void => { if (generation === this.sourceGeneration) { this.cancelSource(); } }, PRO_CONNECTION_TTL_MS);
    if (!transaction.begin(this.sourceOwner, this.allowed(description.protocol), true)) {
      this.cancelSource(); return AbilityConstant.OnContinueResult.REJECT;
    }
    const channel = new ProContinuationReceiptChannel(); this.sourceChannel = channel;
    const joined = await this.boundedJoin(channel, context, envelope,
      (receipt: string): boolean => {
        if (generation !== this.sourceGeneration || !this.sourceCurrent() || this.sourceTransaction !== transaction ||
            !transaction.acceptReceipt(receipt, this.sourceOwner, this.allowed(description.protocol))) { return false; }
        this.sourceMessage = '目标已连接并恢复接续状态；可以保留本端，或手动结束本端会话';
        this.publish(); return true;
      }, (): void => {});
    if (!joined || generation !== this.sourceGeneration || !this.sourceCurrent()) {
      if (generation === this.sourceGeneration) { this.cancelSource(); }
      return AbilityConstant.OnContinueResult.REJECT;
    }
    // Opt-in only: the platform's authenticated same-account continuation transport carries the
    // secret as its own Want parameter (never inside the whitelisted envelope). Data-object sync
    // is unavailable between the devices during continuation, so it cannot carry it.
    if (ProContinuationPreferences.getInstance().settings().credentialMode === 'transfer' && source.secret !== undefined) {
      const secret = source.secret();
      if (secret !== null) { parameters[PRO_CONTINUATION_SECRET_PARAM] = JSON.stringify(secret); }
      hilog.info(0x0001, 'ProContinuation', 'credential attached=%{public}s kind=%{public}s', secret !== null ? 'true' : 'false',
        secret?.kind ?? 'none');
    }
    parameters[PRO_CONTINUATION_PARAM] = serialized;
    parameters[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
    parameters[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY] = false;
    // The target's readiness receipt cannot cross devices during continuation, so do not wait for it.
    this.sourceMessage = '已接续到其他设备；本端会话仍保留，可随时手动结束'; this.publish();
    return AbilityConstant.OnContinueResult.AGREE;
  }
  ingest(serialized: string, secretValue: Object | null = null): boolean {
    const envelope = parseProConnectionEnvelope(serialized);
    hilog.info(0x0001, 'ProContinuation', 'ingest valid=%{public}s busy=%{public}s', envelope !== null ? 'true' : 'false',
      this.target !== null ? 'true' : 'false');
    const now = Date.now();
    this.seen.forEach((expires: number, id: string): void => { if (expires <= now) { this.seen.delete(id); } });
    if (envelope === null || envelope.purpose !== 'continuation' ||
        this.seen.has(envelope.transferId) || this.seen.size >= 64) { return false; }
    // A newer continuation from the user replaces an older one still pending or failed.
    if (this.target !== null) { this.cancelIncoming(); }
    let secret: ProContinuationSecret | null = null;
    if (typeof secretValue === 'string' && secretValue.length <= 40000) {
      try { secret = validProContinuationSecret(JSON.parse(secretValue) as Object); } catch (_error) { secret = null; }
    }
    this.seen.set(envelope.transferId, envelope.expiresAt);
    this.target = new ProConnectionTransaction(envelope);
    this.targetSecret = envelope.connection.protocol === 'ssh' ? secret : null;
    hilog.info(0x0001, 'ProContinuation', 'ingest credential=%{public}s', this.targetSecret !== null ? 'true' : 'false');
    this.targetMessage = envelope.connection.protocol === 'rdp'
      ? '正在自动接续：使用本设备保存的凭据连接，恢复缩放、平移和输入模式。'
      : envelope.connection.protocol === 'ssh'
        ? '正在自动接续：使用本设备保存的凭据连接并恢复目录。普通终端进程和未完成传输不会迁移。'
        : '正在自动接续：使用本设备保存的主机配置和凭据重新连接同一台远程桌面。';
    this.targetTimer = setTimeout((): void => { this.cancelIncoming(); }, envelope.expiresAt - now);
    this.publish(); return true;
  }
  async accept(context: common.UIAbilityContext): Promise<RemoteHost | null> {
    const target = this.target; const envelope = target?.envelope();
    if (target === null || envelope === undefined || envelope === null || target.state() !== 'offered') { return null; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (!this.allowed(envelope.connection.protocol)) {
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=pro');
      this.targetMessage = '接续失败：本设备需要有效的 Pro'; this.publish(); return null;
    }
    ProContinuationPreferences.getInstance().load(context);
    if (!ProContinuationPreferences.getInstance().protocolEnabled(envelope.connection.protocol)) {
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=disabled');
      this.targetMessage = '接续失败：本设备已在 Pro 功能 > 同账号接续中关闭 ' +
        proContinuationProtocolLabel(envelope.connection.protocol) + ' 接续'; this.publish(); return null;
    }
    if (scope.kind !== 'huawei_account' || scope.ownerScopeId !== envelope.owner) {
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=account kind=%{public}s', scope.kind);
      this.targetMessage = '接续失败：请在两台设备登录同一华为账号'; this.publish(); return null;
    }
    const host = resolveProContinuationHost(envelope.connection.protocol, envelope.connection.hostReference);
    if (!proContinuationHostStoreReady(envelope.connection.protocol) || host === null ||
        host.userId !== scope.ownerScopeId ||
        !matchesProConnectionHost(envelope.connection, host, context)) {
      const reason = !proContinuationHostStoreReady(envelope.connection.protocol) ? 'store' : host === null ? 'missing' :
        host.userId !== scope.ownerScopeId ? 'owner' : 'endpoint';
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=host-%{public}s', reason);
      this.targetMessage = reason === 'missing' ? '接续失败：本设备没有这台主机，请先开启云同步或在本设备添加' :
        reason === 'endpoint' ? '接续失败：本设备上这台主机的地址、端口或用户名与源设备不一致' :
        '接续失败：主机数据尚未就绪或不属于当前账号，请稍后重试'; this.publish(); return null;
    }
    const generation = this.targetGeneration;
    if (!await this.permission(context)) {
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=permission');
      if (generation === this.targetGeneration) { this.targetMessage = '接续失败：需要允许"多设备协同"权限'; this.publish(); }
      return null;
    }
    if (generation !== this.targetGeneration || this.target !== target ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation ||
        !this.descriptionAllowed(envelope.connection, context) ||
        !target.begin(scope.ownerScopeId, this.allowed(envelope.connection.protocol), true)) { return null; }
    this.targetAccountGeneration = scope.generation; this.targetContext = context;
    const channel = new ProContinuationReceiptChannel(); this.targetChannel = channel;
    const joined = await this.boundedJoin(channel, context, envelope,
      (_receipt: string): boolean => false, (): void => {
        if (generation === this.targetGeneration && this.target === target && target.state() === 'ready') {
          this.cancelIncoming();
        }
      });
    if (!joined || generation !== this.targetGeneration || this.target !== target ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation ||
        !this.allowed(envelope.connection.protocol)) {
      hilog.warn(0x0001, 'ProContinuation', 'accept rejected reason=channel joined=%{public}s', joined ? 'true' : 'false');
      if (generation === this.targetGeneration) { this.cancelIncoming(); } return null;
    }
    // Moved into the one-shot, host-bound handoff only once every account/host/Pro check passed.
    const secret = this.targetSecret; this.targetSecret = null;
    if (secret !== null) {
      ProContinuationCredentialHandoff.getInstance().deposit(envelope.connection.hostReference, envelope.owner, secret);
    }
    hilog.info(0x0001, 'ProContinuation', 'accept credential received=%{public}s', secret !== null ? 'true' : 'false');
    hilog.info(0x0001, 'ProContinuation', 'accept connecting protocol=%{public}s', envelope.connection.protocol);
    const currentHost = resolveProContinuationHost(envelope.connection.protocol, envelope.connection.hostReference);
    if (currentHost === null || currentHost.userId !== envelope.owner ||
        this.restoreView(envelope.transferId, currentHost) === null) { this.cancelIncoming(); return null; }
    this.targetMessage = '正在连接；仅在缺少凭据或需要解锁时提示'; this.publish(); return currentHost;
  }
  incomingId(): string { return this.target?.envelope()?.transferId ?? ''; }
  restoreView(id: string, host: RemoteHost): ProConnectionView | null {
    const envelope = this.target?.envelope(); const scope = AccountSessionCoordinator.getInstance().currentScope();
    const currentHost = resolveProContinuationHost(envelope?.connection.protocol ?? '', host.id);
    if (envelope === undefined || envelope === null || this.target?.state() !== 'connecting' ||
        id !== envelope.transferId || scope.ownerScopeId !== envelope.owner ||
        scope.generation !== this.targetAccountGeneration || host.userId !== scope.ownerScopeId ||
        !proContinuationHostStoreReady(envelope.connection.protocol) || currentHost?.userId !== scope.ownerScopeId ||
        host.id !== envelope.connection.hostReference ||
        ['bound', 'ready', 'offline'].indexOf(scope.sessionState) < 0 ||
        !this.allowed(envelope.connection.protocol) || currentHost === undefined || this.targetContext === null ||
        !matchesProConnectionHost(envelope.connection, currentHost, this.targetContext)) { return null; }
    return envelope.connection.view;
  }
  incomingRdpIdentity(id: string, host: RemoteHost): ProRdpConnectionIdentity | null {
    if (this.restoreView(id, host) === null) { return null; }
    return this.target?.envelope()?.connection.rdpIdentity ?? null;
  }
  complete(id: string, host: RemoteHost, nativeRdpIdentity: ProRdpConnectionIdentity | null = null): boolean {
    if (this.restoreView(id, host) === null) { return false; }
    const description = this.target?.envelope()?.connection;
    if (description === undefined || (description.protocol === 'rdp' &&
      (nativeRdpIdentity === null || description.rdpIdentity === undefined ||
        !sameProRdpConnectionIdentity(nativeRdpIdentity, description.rdpIdentity)))) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const receipt = this.target?.ready(scope.ownerScopeId, this.allowed(description.protocol));
    if (receipt === undefined || receipt === null || !this.targetChannel.send(JSON.stringify(receipt))) { return false; }
    this.targetMessage = '本端已恢复接续状态，已发送就绪回执'; this.publish(); return true;
  }
  cancelIncoming(expectedId: string = ''): void {
    if (expectedId !== '' && this.incomingId() !== expectedId) { return; }
    this.targetGeneration++; this.target?.cancel(); this.target = null; this.targetChannel.close();
    this.targetSecret = null;
    this.targetContext = null;
    if (this.targetTimer !== -1) { clearTimeout(this.targetTimer); this.targetTimer = -1; }
    this.targetMessage = ''; this.publish();
  }
  cancelSource(windowId: number = 0): void {
    if (windowId > 0 && this.source?.windowId !== windowId) { return; }
    this.sourceGeneration++; this.sourceTransaction?.cancel(); this.sourceTransaction = null; this.sourceChannel.close();
    if (this.sourceTimer !== -1) { clearTimeout(this.sourceTimer); this.sourceTimer = -1; }
    const context = this.sourceContext;
    this.source = null; this.sourceContext = null; this.sourceMessage = ''; this.sourceDeadline = 0;
    if (context !== null) { void this.setMission(context, AbilityConstant.ContinueState.INACTIVE).catch((): void => {}); }
    this.publish();
  }
  closeConfirmedSource(windowId: number): boolean {
    const source = this.source;
    if (source === null || source.windowId !== windowId || !this.sourceCurrent() ||
        this.sourceTransaction?.mayOfferSourceClose() !== true) { return false; }
    this.cancelSource(windowId); source.close(); return true;
  }
  snapshot(): ProContinuationSnapshot {
    const envelope = this.target?.envelope();
    return { incoming: envelope !== undefined && envelope !== null, incomingCanAccept: this.target?.state() === 'offered',
      incomingLabel: envelope?.connection.label ?? '',
      incomingProtocol: envelope?.connection.protocol ?? '',
      incomingEndpoint: envelope === undefined || envelope === null ? '' :
        (envelope.connection.rdpIdentity?.domain ? envelope.connection.rdpIdentity.domain + '\\' : '') +
          envelope.connection.username + '@' + envelope.connection.host + ':' + envelope.connection.port.toString(),
      incomingMessage: this.targetMessage, sourceWindow: this.source?.windowId ?? 0,
      sourceMessage: this.sourceMessage, sourceCloseAllowed: this.sourceCurrent() &&
        this.sourceTransaction?.mayOfferSourceClose() === true };
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener); listener();
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} });
  }
}
