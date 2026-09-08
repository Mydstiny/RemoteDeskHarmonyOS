import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { HostSyncService } from '../HostSyncService';
import { RemoteHost } from '../../model/RemoteHost';
import { SshAddBasicFields } from '../../common/SshAddBasicFields';
import { ProConnectionDescription, ProConnectionEnvelope, ProConnectionView } from './ProConnectionEnvelope';
import { describeProSshConnection } from './ProConnectionHostAdapter';
import { proConnectionShareBase } from './ProConnectionShareConfiguration';
import { parseProConnectionShareLink } from './ProConnectionSharePolicy';

export interface ProConnectionShareIncomingSnapshot {
  visible: boolean; canAccept: boolean; id: string; label: string; endpoint: string; directory: string; message: string;
}
/** Ordinary SSH reception is free. The URI is untrusted input, never an authentication or entitlement proof. */
export class ProConnectionShareReceiver {
  private static instance: ProConnectionShareReceiver;
  private envelope: ProConnectionEnvelope | null = null;
  private phase: string = '';
  private owner: string = '';
  private accountGeneration: number = 0;
  private hostId: string = '';
  private context: common.Context | null = null;
  private timer: number = -1;
  private transitionActive: boolean = true;
  private seen: Map<string, number> = new Map<string, number>();
  private listeners: Array<() => void> = [];
  static getInstance(): ProConnectionShareReceiver {
    if (!ProConnectionShareReceiver.instance) { ProConnectionShareReceiver.instance = new ProConnectionShareReceiver(); }
    return ProConnectionShareReceiver.instance;
  }
  private constructor() {
    AccountSessionCoordinator.getInstance().onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      // Cold links can arrive before account bootstrap. Only the unaccepted
      // preview survives; an accepted draft never moves into a different account.
      if (active && this.phase !== 'offered') { this.cancel(); }
      this.publish();
    });
  }
  ingest(link: string): boolean {
    const envelope = parseProConnectionShareLink(proConnectionShareBase(), link);
    const now = Date.now();
    this.seen.forEach((expires: number, id: string): void => { if (expires <= now) { this.seen.delete(id); } });
    if (envelope === null || envelope.connection.protocol !== 'ssh' || this.envelope !== null ||
        this.seen.has(envelope.transferId) || this.seen.size >= 64) { return false; }
    this.envelope = envelope; this.phase = 'offered';
    this.seen.set(envelope.transferId, envelope.expiresAt);
    this.timer = setTimeout((): void => { this.cancel(envelope.transferId); }, envelope.expiresAt - now);
    this.publish(); return true;
  }
  private scopeReady(): boolean {
    return !this.transitionActive && HostSyncService.getInstance().isReady() &&
      ['bound', 'ready', 'offline'].indexOf(AccountSessionCoordinator.getInstance().currentScope().sessionState) >= 0;
  }
  private current(id: string): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return this.envelope !== null && this.envelope.transferId === id && Date.now() < this.envelope.expiresAt &&
      this.scopeReady() && this.owner === scope.ownerScopeId && this.accountGeneration === scope.generation;
  }
  accept(id: string): SshAddBasicFields | null {
    const envelope = this.envelope;
    if (envelope === null || envelope.transferId !== id || this.phase !== 'offered' ||
        Date.now() >= envelope.expiresAt || !this.scopeReady()) { return null; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.owner = scope.ownerScopeId; this.accountGeneration = scope.generation; this.phase = 'draft';
    this.publish();
    return { label: envelope.connection.label, address: envelope.connection.host,
      port: envelope.connection.port, username: envelope.connection.username };
  }
  draftCurrent(id: string): boolean { return this.phase === 'draft' && this.current(id); }
  private sameEndpoint(description: ProConnectionDescription | null): boolean {
    const shared = this.envelope?.connection;
    return description !== null && shared !== undefined && description.protocol === shared.protocol &&
      description.host === shared.host && description.port === shared.port && description.username === shared.username;
  }
  bindSaved(id: string, host: RemoteHost, context: common.Context): boolean {
    if (!this.draftCurrent(id)) { return false; }
    const saved = HostSyncService.getInstance().getHost(host.id);
    if (saved === undefined || saved.userId !== this.owner || host.userId !== this.owner ||
        !this.sameEndpoint(describeProSshConnection(saved, 'terminal', '', context))) { this.cancel(id); return false; }
    this.hostId = saved.id; this.context = context; this.phase = 'connecting'; this.publish(); return true;
  }
  restoreView(id: string, host: RemoteHost): ProConnectionView | null {
    if (this.phase !== 'connecting' || !this.current(id) || this.context === null ||
        host.id !== this.hostId || host.userId !== this.owner) { return null; }
    const saved = HostSyncService.getInstance().getHost(this.hostId);
    if (saved === undefined || saved.userId !== this.owner ||
        !this.sameEndpoint(describeProSshConnection(saved, 'terminal', '', this.context)) ||
        !this.sameEndpoint(describeProSshConnection(host, 'terminal', '', this.context))) { return null; }
    const view = this.envelope?.connection.view;
    return view === undefined ? null : { sshPane: view.sshPane, sshDirectory: view.sshDirectory,
      monitor: 0, scale: 1, panX: 0, panY: 0, inputMode: 'direct' };
  }
  complete(id: string, host: RemoteHost): boolean {
    if (this.restoreView(id, host) === null) { return false; }
    this.cancel(id); return true;
  }
  incomingId(): string { return this.envelope?.transferId ?? ''; }
  cancel(expectedId: string = ''): void {
    if (expectedId !== '' && expectedId !== this.incomingId()) { return; }
    this.envelope = null; this.phase = ''; this.hostId = ''; this.owner = ''; this.context = null;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.publish();
  }
  snapshot(): ProConnectionShareIncomingSnapshot {
    const connection = this.envelope?.connection;
    return { visible: this.envelope !== null, canAccept: this.phase === 'offered' && this.scopeReady(),
      id: this.incomingId(), label: connection?.label ?? '', directory: connection?.view.sshDirectory ?? '',
      endpoint: connection === undefined ? '' : connection.username + '@' + connection.host + ':' + connection.port.toString(),
      message: this.phase === 'offered' ? '请核对来源与地址，随后填写本设备的密码或密钥。链接有效期为 2 分钟。' :
        '正在通过本设备的普通 SSH 流程保存、认证和连接；源端会话继续保留。' };
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener); listener();
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} });
  }
}
