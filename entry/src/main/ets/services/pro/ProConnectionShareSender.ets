import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { HostSyncService } from '../HostSyncService';
import { ProAppRuntime } from './ProAppRuntime';
import { ProAccessContext } from './ProAccessPolicy';
import { ProConnectionDescription, sameProConnectionEndpoint, PRO_CONNECTION_TTL_MS } from './ProConnectionEnvelope';
import { describeProSshConnection } from './ProConnectionHostAdapter';
import { proConnectionShareBase } from './ProConnectionShareConfiguration';
import { buildProConnectionShareLink, makeProConnectionShareEnvelope, proConnectionShareBaseValid } from './ProConnectionSharePolicy';
import { KnockPoint } from './ProKnockPolicy';

export const PRO_CONNECTION_SHARE_FEATURE: string = 'pro.connection.knockShare';
const CAPABILITY: string = 'SystemCapability.Collaboration.HarmonyShare';
export function proConnectionShareContext(): ProAccessContext {
  const context = ProAppRuntime.getInstance().context('ssh');
  if (canIUse(CAPABILITY)) { context.capabilities.push(CAPABILITY); }
  return context;
}
export interface ProConnectionShareSource {
  windowId: number;
  context: common.UIAbilityContext;
  description: ProConnectionDescription;
  isCurrent: () => boolean;
  confirm: (point: KnockPoint | null) => Promise<boolean>;
}
export interface ProConnectionShareSenderSnapshot { windowId: number; active: boolean; message: string; }
function randomHex(): string {
  const bytes = cryptoFramework.createRandom().generateRandomSync(16).data;
  let result: string = '';
  bytes.forEach((byte: number): void => { result += byte.toString(16).padStart(2, '0'); });
  return result;
}

/** One explicit window, one short-lived offer. Share Kit completion is never a remote SSH-ready receipt. */
export class ProConnectionShareSender {
  private static instance: ProConnectionShareSender;
  private source: ProConnectionShareSource | null = null;
  private registry: harmonyShare.SendCapabilityRegistry | null = null;
  private callback: ((target: harmonyShare.SharableTarget) => void) | null = null;
  private epoch: number = 0;
  private owner: string = '';
  private accountGeneration: number = 0;
  private deadline: number = 0;
  private timer: number = -1;
  private sharing: boolean = false;
  private claimed: boolean = false;
  private transitionActive: boolean = true;
  private message: string = '';
  private listeners: Array<() => void> = [];
  static getInstance(): ProConnectionShareSender {
    if (!ProConnectionShareSender.instance) { ProConnectionShareSender.instance = new ProConnectionShareSender(); }
    return ProConnectionShareSender.instance;
  }
  private constructor() {
    AccountSessionCoordinator.getInstance().onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      if (active) { this.stop(); }
    });
    ProAppRuntime.getInstance().runtime.subscribe((): void => { this.stop(); });
  }
  private allowed(): boolean {
    return !this.transitionActive && deviceInfo.sdkApiVersion >= 23 && canIUse(CAPABILITY) &&
      proConnectionShareBaseValid(proConnectionShareBase()) &&
      ProAppRuntime.getInstance().runtime.decision(PRO_CONNECTION_SHARE_FEATURE, proConnectionShareContext()).executable;
  }
  private current(source: ProConnectionShareSource, epoch: number): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (this.source !== source || this.epoch !== epoch || !this.allowed() || !source.isCurrent() ||
        Date.now() >= this.deadline || scope.ownerScopeId !== this.owner || scope.generation !== this.accountGeneration ||
        ['bound', 'ready', 'offline'].indexOf(scope.sessionState) < 0 || !HostSyncService.getInstance().isReady()) { return false; }
    const host = HostSyncService.getInstance().getHost(source.description.hostReference);
    const local = host === undefined ? null : describeProSshConnection(host, 'terminal', '', source.context);
    return host?.userId === this.owner && local !== null && sameProConnectionEndpoint(local, source.description);
  }
  arm(source: ProConnectionShareSource): boolean {
    this.stop();
    if (this.sharing || !this.allowed() || !Number.isInteger(source.windowId) || source.windowId <= 0 ||
        source.description.protocol !== 'ssh') { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.source = source; this.owner = scope.ownerScopeId; this.accountGeneration = scope.generation;
    this.claimed = false;
    this.deadline = Date.now() + PRO_CONNECTION_TTL_MS;
    const epoch = this.epoch;
    if (!this.current(source, epoch)) { this.stop(); return false; }
    this.registry = { windowId: source.windowId, sendOnly: true };
    this.callback = (target: harmonyShare.SharableTarget): void => { void this.send(target, source, epoch); };
    try { harmonyShare.on('knockShare', this.registry, this.callback); }
    catch (_error) { this.stop(); return false; }
    this.timer = setTimeout((): void => { if (this.epoch === epoch) { this.stop(); } }, PRO_CONNECTION_TTL_MS);
    this.message = '已准备分享，请在 2 分钟内碰一碰当前窗口；发送前会再次确认';
    this.publish(); return true;
  }
  private unregister(): void {
    if (this.registry !== null && this.callback !== null) {
      try { harmonyShare.off('knockShare', this.registry, this.callback); } catch (_error) {}
    }
    this.registry = null; this.callback = null;
  }
  private async reject(target: harmonyShare.SharableTarget): Promise<void> {
    try { await target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR); } catch (_error) {}
  }
  private async send(target: harmonyShare.SharableTarget, source: ProConnectionShareSource, epoch: number): Promise<void> {
    if (this.sharing || this.claimed || !this.current(source, epoch)) { await this.reject(target); return; }
    this.claimed = true; this.sharing = true; this.unregister();
    let submitted: boolean = false;
    try {
      let point: KnockPoint | null = null;
      if (deviceInfo.sdkApiVersion >= 26) {
        try {
          const coordinate = target.getInfo().coordinate;
          if (coordinate !== undefined) { point = { x: coordinate.screenX, y: coordinate.screenY }; }
        } catch (_error) {}
      }
      if (!await source.confirm(point) || !this.current(source, epoch)) {
        if (this.current(source, epoch)) { this.message = '本次分享已取消，可重新准备'; }
        await this.reject(target); return;
      }
      const envelope = makeProConnectionShareEnvelope(source.description, randomHex(), 'rd_' + randomHex());
      const link = envelope === null ? '' : buildProConnectionShareLink(proConnectionShareBase(), envelope);
      if (link === '' || !this.current(source, epoch)) { await this.reject(target); return; }
      const data = new systemShare.SharedData({ utd: 'general.hyperlink', content: link,
        title: 'RemoteDesk · ' + source.description.label,
        description: 'SSH 连接信息；接收端需自行认证，本端会话继续保留' });
      submitted = true;
      await target.share(data);
      if (this.current(source, epoch)) {
        this.message = '连接信息已交给系统分享；请在目标设备确认并认证。本端会话继续保留'; this.publish();
      }
    } catch (_error) {
      if (!submitted) { await this.reject(target); }
      if (this.current(source, epoch)) { this.message = '连接分享未完成，可重新准备'; this.publish(); }
    } finally {
      this.sharing = false;
      if (this.epoch === epoch) { this.unregister(); this.publish(); }
    }
  }
  stop(windowId: number = 0): void {
    if (windowId > 0 && this.source?.windowId !== windowId) { return; }
    this.epoch++; this.unregister(); this.source = null; this.message = ''; this.deadline = 0;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.publish();
  }
  snapshot(): ProConnectionShareSenderSnapshot {
    return { windowId: this.source?.windowId ?? 0, active: this.registry !== null || this.sharing, message: this.message };
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener); listener();
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} });
  }
}
