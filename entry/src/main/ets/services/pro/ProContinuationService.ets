import { AbilityConstant, common, wantConstant, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { HostSyncService } from '../HostSyncService';
import { RemoteHost } from '../../model/RemoteHost';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProConnectionDescription, ProConnectionEnvelope, ProConnectionView, parseProConnectionEnvelope,
  sameProConnectionEndpoint, PRO_CONNECTION_TTL_MS } from './ProConnectionEnvelope';
import { describeProSshConnection } from './ProConnectionHostAdapter';
import { ProConnectionTransaction } from './ProConnectionTransaction';
import { ProContinuationReceiptChannel } from './ProContinuationReceiptChannel';

export const PRO_CONTINUATION_PARAM: string = 'remotedesk.pro.connection.v1';
export const PRO_CONTINUATION_FEATURE: string = 'pro.connection.continuation';
const SYNC_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
const DATA_OBJECT_CAPABILITY: string = 'SystemCapability.DistributedDataManager.DataObject.DistributedObject';
export interface ProContinuationSource {
  windowId: number;
  describe: () => ProConnectionDescription | null;
  isCurrent: () => boolean;
  close: () => void;
}
export interface ProContinuationSnapshot {
  incoming: boolean;
  incomingCanAccept: boolean;
  incomingLabel: string;
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
export function proContinuationContext(): ProAccessContext {
  const context = ProAppRuntime.getInstance().context('ssh');
  if (canIUse(DATA_OBJECT_CAPABILITY)) { context.capabilities.push(DATA_OBJECT_CAPABILITY); }
  context.requestablePermissions = [SYNC_PERMISSION];
  return context;
}
/** One main-ability continuation per process; PC session abilities remain outside this first adapter. */
export class ProContinuationService {
  private static instance: ProContinuationService;
  private listeners: Array<() => void> = [];
  private source: ProContinuationSource | null = null;
  private sourceContext: common.UIAbilityContext | null = null;
  private sourceOwner: string = '';
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
          (scope.generation !== this.targetAccountGeneration || !this.allowed())) { this.cancelIncoming(); }
      this.publish();
    });
  }
  private allowed(): boolean {
    if (this.transitionActive) { return false; }
    // Permission is separately checked against the platform before joining.
    const context = proContinuationContext(); context.grantedPermissions = [SYNC_PERMISSION];
    return ProAppRuntime.getInstance().runtime.decision(PRO_CONTINUATION_FEATURE, context).executable;
  }
  private async permission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const token = context.applicationInfo.accessTokenId;
      if (await manager.checkAccessToken(token, SYNC_PERMISSION) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const result = await manager.requestPermissionsFromUser(context, [SYNC_PERMISSION]);
      return result.authResults.length === 1 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_error) { return false; }
  }
  private sourceCurrent(): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return this.source !== null && this.sourceContext !== null && Date.now() < this.sourceDeadline && this.source.isCurrent() &&
      this.descriptionAllowed(this.source.describe(), this.sourceContext) && this.allowed() &&
      scope.kind === 'huawei_account' && scope.ownerScopeId === this.sourceOwner &&
      scope.generation === this.sourceAccountGeneration &&
      ['bound', 'ready', 'offline'].indexOf(scope.sessionState) >= 0;
  }
  private descriptionAllowed(description: ProConnectionDescription | null, context: common.Context): boolean {
    if (description === null || description.protocol !== 'ssh' || !HostSyncService.getInstance().isReady()) { return false; }
    const host = HostSyncService.getInstance().getHost(description.hostReference);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const local = host === undefined ? null : describeProSshConnection(host, 'terminal', '', context);
    return host !== undefined && host.userId === scope.ownerScopeId && local !== null &&
      sameProConnectionEndpoint(local, description);
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
  async prepare(context: common.UIAbilityContext, source: ProContinuationSource): Promise<boolean> {
    this.cancelSource();
    if (context.abilityInfo.name !== 'EntryAbility' || !this.allowed() || !source.isCurrent() ||
        !this.descriptionAllowed(source.describe(), context) || !Number.isInteger(source.windowId) || source.windowId <= 0) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (scope.kind !== 'huawei_account' || !/^owner-[a-f0-9]{64}$/.test(scope.ownerScopeId)) { return false; }
    const generation = this.sourceGeneration;
    if (!await this.permission(context) || generation !== this.sourceGeneration || !this.allowed() ||
        !source.isCurrent() || !this.descriptionAllowed(source.describe(), context) ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation) {
      return false;
    }
    this.source = source; this.sourceContext = context; this.sourceOwner = scope.ownerScopeId;
    this.sourceAccountGeneration = scope.generation;
    this.sourceDeadline = Date.now() + PRO_CONNECTION_TTL_MS;
    this.sourceTimer = setTimeout((): void => { if (generation === this.sourceGeneration) { this.cancelSource(); } }, PRO_CONNECTION_TTL_MS);
    try {
      await this.setMission(context, AbilityConstant.ContinueState.ACTIVE);
      if (generation !== this.sourceGeneration || !this.sourceCurrent()) { return false; }
      this.sourceMessage = '已准备接续，请在 2 分钟内从另一台同账号设备的系统入口继续';
      this.publish(); return true;
    } catch (_error) { if (generation === this.sourceGeneration) { this.cancelSource(); } return false; }
  }
  async onContinue(windowId: number, parameters: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const source = this.source; const context = this.sourceContext;
    if (source === null || context === null || source.windowId !== windowId || !this.sourceCurrent() ||
        this.sourceTransaction !== null) { return AbilityConstant.OnContinueResult.REJECT; }
    const description = source.describe();
    if (description === null || description.protocol !== 'ssh') { return AbilityConstant.OnContinueResult.REJECT; }
    const generation = this.sourceGeneration;
    const now = Date.now();
    const envelope: ProConnectionEnvelope = { version: 1, purpose: 'continuation', transferId: randomHex(),
      channelId: 'rd_' + randomHex(), owner: this.sourceOwner, createdAt: now,
      expiresAt: now + PRO_CONNECTION_TTL_MS, connection: description };
    const serialized = JSON.stringify(envelope);
    if (parseProConnectionEnvelope(serialized) === null) { return AbilityConstant.OnContinueResult.REJECT; }
    const transaction = new ProConnectionTransaction(envelope);
    this.sourceTransaction = transaction;
    this.sourceDeadline = envelope.expiresAt;
    if (this.sourceTimer !== -1) { clearTimeout(this.sourceTimer); }
    this.sourceTimer = setTimeout((): void => { if (generation === this.sourceGeneration) { this.cancelSource(); } }, PRO_CONNECTION_TTL_MS);
    if (!transaction.begin(this.sourceOwner, this.allowed(), true)) { this.cancelSource(); return AbilityConstant.OnContinueResult.REJECT; }
    const channel = new ProContinuationReceiptChannel(); this.sourceChannel = channel;
    const joined = await this.boundedJoin(channel, context, envelope,
      (receipt: string): boolean => {
        if (generation !== this.sourceGeneration || !this.sourceCurrent() || this.sourceTransaction !== transaction ||
            !transaction.acceptReceipt(receipt, this.sourceOwner, this.allowed())) { return false; }
        this.sourceMessage = '目标已连接并恢复接续状态；可以保留本端，或手动结束本端会话';
        this.publish(); return true;
      }, (): void => {});
    if (!joined || generation !== this.sourceGeneration || !this.sourceCurrent()) {
      if (generation === this.sourceGeneration) { this.cancelSource(); }
      return AbilityConstant.OnContinueResult.REJECT;
    }
    parameters[PRO_CONTINUATION_PARAM] = serialized;
    parameters[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
    parameters[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY] = false;
    this.sourceMessage = '正在等待目标确认与连接；本端会话继续保留'; this.publish();
    return AbilityConstant.OnContinueResult.AGREE;
  }
  ingest(serialized: string): boolean {
    const envelope = parseProConnectionEnvelope(serialized);
    const now = Date.now();
    this.seen.forEach((expires: number, id: string): void => { if (expires <= now) { this.seen.delete(id); } });
    if (envelope === null || envelope.purpose !== 'continuation' || envelope.connection.protocol !== 'ssh' ||
        this.target !== null || this.seen.has(envelope.transferId) || this.seen.size >= 64) { return false; }
    this.seen.set(envelope.transferId, envelope.expiresAt);
    this.target = new ProConnectionTransaction(envelope);
    this.targetMessage = '将重新进行主机认证。普通终端进程和未完成传输不会迁移。';
    this.targetTimer = setTimeout((): void => { this.cancelIncoming(); }, envelope.expiresAt - now);
    this.publish(); return true;
  }
  async accept(context: common.UIAbilityContext): Promise<RemoteHost | null> {
    const target = this.target; const envelope = target?.envelope();
    if (target === null || envelope === undefined || envelope === null || target.state() !== 'offered') { return null; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (!this.allowed() || scope.kind !== 'huawei_account' || scope.ownerScopeId !== envelope.owner) {
      this.targetMessage = '请使用同一华为账号，并在本设备独立激活可用的 Pro 接续能力'; this.publish(); return null;
    }
    const host = HostSyncService.getInstance().getHost(envelope.connection.hostReference);
    const local = host === undefined ? null : describeProSshConnection(host, 'terminal', '', context);
    if (!HostSyncService.getInstance().isReady() || host === undefined || local === null || host.userId !== scope.ownerScopeId ||
        !sameProConnectionEndpoint(local, envelope.connection)) {
      this.targetMessage = '本设备还没有对应的同账号主机配置，或端点已变化；请先同步并核对'; this.publish(); return null;
    }
    const generation = this.targetGeneration;
    if (!await this.permission(context) || generation !== this.targetGeneration || this.target !== target ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation ||
        !this.descriptionAllowed(envelope.connection, context) ||
        !target.begin(scope.ownerScopeId, this.allowed(), true)) { return null; }
    this.targetAccountGeneration = scope.generation; this.targetContext = context;
    const channel = new ProContinuationReceiptChannel(); this.targetChannel = channel;
    const joined = await this.boundedJoin(channel, context, envelope,
      (_receipt: string): boolean => false, (): void => {
        if (generation === this.targetGeneration && this.target === target && target.state() === 'ready') {
          this.cancelIncoming();
        }
      });
    if (!joined || generation !== this.targetGeneration || this.target !== target ||
        AccountSessionCoordinator.getInstance().currentScope().generation !== scope.generation || !this.allowed()) {
      if (generation === this.targetGeneration) { this.cancelIncoming(); } return null;
    }
    const currentHost = HostSyncService.getInstance().getHost(envelope.connection.hostReference);
    if (currentHost === undefined || currentHost.userId !== envelope.owner ||
        this.restoreView(envelope.transferId, currentHost) === null) { this.cancelIncoming(); return null; }
    this.targetMessage = '正在通过本设备原有流程进行主机认证'; this.publish(); return currentHost;
  }
  incomingId(): string { return this.target?.envelope()?.transferId ?? ''; }
  restoreView(id: string, host: RemoteHost): ProConnectionView | null {
    const envelope = this.target?.envelope(); const scope = AccountSessionCoordinator.getInstance().currentScope();
    const currentHost = HostSyncService.getInstance().getHost(host.id);
    const local = currentHost === undefined || this.targetContext === null ? null :
      describeProSshConnection(currentHost, 'terminal', '', this.targetContext);
    if (envelope === undefined || envelope === null || this.target?.state() !== 'connecting' ||
        id !== envelope.transferId || scope.ownerScopeId !== envelope.owner ||
        scope.generation !== this.targetAccountGeneration || host.userId !== scope.ownerScopeId ||
        !HostSyncService.getInstance().isReady() || currentHost?.userId !== scope.ownerScopeId ||
        host.id !== envelope.connection.hostReference ||
        ['bound', 'ready', 'offline'].indexOf(scope.sessionState) < 0 || !this.allowed() || local === null ||
        !sameProConnectionEndpoint(local, envelope.connection)) { return null; }
    return envelope.connection.view;
  }
  complete(id: string, host: RemoteHost): boolean {
    if (this.restoreView(id, host) === null) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const receipt = this.target?.ready(scope.ownerScopeId, this.allowed());
    if (receipt === undefined || receipt === null || !this.targetChannel.send(JSON.stringify(receipt))) { return false; }
    this.targetMessage = '本端已恢复接续状态，已发送就绪回执'; this.publish(); return true;
  }
  cancelIncoming(): void {
    this.targetGeneration++; this.target?.cancel(); this.target = null; this.targetChannel.close();
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
      incomingEndpoint: envelope === undefined || envelope === null ? '' :
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
