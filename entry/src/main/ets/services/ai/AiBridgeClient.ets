import { aiParams } from './AiWirePolicy';
import { AiAccess, AiAccountLease } from './AiAccess';
import { AiLocalStore } from './AiLocalStore';
import { AiHost, AiIdentity, AiHandshake, AiOperationReceipt, AiPendingOperation, AiEvent, aiIdValid } from './AiModels';
import { AiTransport, aiRandomId } from './AiTransport';
import { AiLifecycle } from './AiLifecycle';
import { aiArray, aiNumber, aiRecord, aiString, parseAiInvite } from './AiWirePolicy';

const AI_CLEANUP_METHODS: string[] = ['turn.cancel', 'lease.release', 'terminal.stop'];
export class AiBridgeClient {
  readonly ownerId: string = aiRandomId();
  readonly account: AiAccountLease;
  readonly host: AiHost;
  handshake: AiHandshake | null = null;
  private transport: AiTransport;
  private cleanupTransport: AiTransport;
  private revoked: boolean = false;
  private ownedLeases: Map<string, string> = new Map();
  private closed: boolean = false;
  private unregister: () => void;
  private stopAccess: () => void = (): void => {};
  private readonly access: AiAccess = AiAccess.getInstance();
  private readonly store: AiLocalStore = AiLocalStore.getInstance();
  private constructor(host: AiHost, identity: AiIdentity, account: AiAccountLease) {
    this.account = account;
    this.host = JSON.parse(JSON.stringify(host)) as AiHost;
    this.transport = new AiTransport(host, identity);
    this.cleanupTransport = new AiTransport(host, identity);
    this.unregister = AiLifecycle.register(this.ownerId, host.id, (): void => this.close());
    this.stopAccess = this.access.subscribe((): void => {
      if (!this.access.current(account)) { this.close(); }
      else if (!this.access.executable(host.backend)) { this.revoked = true; this.transport.close(); }
    });
  }
  static async connect(host: AiHost): Promise<AiBridgeClient> {
    const access = AiAccess.getInstance();
    const account = access.capture();
    access.assertExecute(account, host.backend);
    if (host.owner !== account.owner) { throw new Error('AI_ACCOUNT_CHANGED'); }
    const store = AiLocalStore.getInstance();
    const record = await store.connection(account, host.id);
    if (record === null || record.host.revision !== host.revision) { throw new Error('AI_HOST_CHANGED'); }
    const identity = record.identity;
    access.assertExecute(account, host.backend);
    if (identity === null) { throw new Error('AI_IDENTITY_REQUIRED'); }
    const client = new AiBridgeClient(record.host, identity, account);
    try {
      const recheck = await store.connection(account, host.id);
      if (recheck === null || recheck.host.revision !== record.host.revision) { throw new Error('AI_HOST_CHANGED'); }
      await client.greet(identity.instance, identity.deviceId);
      return client;
    } catch (error) { client.close(); throw new Error((error as Error).message); }
  }
  static async pair(host: AiHost, inviteText: string, deviceName: string): Promise<void> {
    const access = AiAccess.getInstance();
    const account = access.capture();
    access.assertExecute(account, host.backend);
    if (host.owner !== account.owner) { throw new Error('AI_ACCOUNT_CHANGED'); }
    const invite = parseAiInvite(inviteText);
    const identity = await AiTransport.generateIdentity();
    access.assertExecute(account, host.backend);
    const credential: AiIdentity = { ca: invite.ca, certificate: '', privateKey: '',
      deviceId: '', instance: invite.serverInstance };
    const transport = new AiTransport(host, credential);
    const id = aiRandomId();
    const unregister = AiLifecycle.register(id, host.id, (): void => transport.close());
    const stop = access.subscribe((): void => {
      if (!access.current(account) || !access.executable(host.backend)) { transport.close(); }
    });
    let verified: AiBridgeClient | null = null;
    try {
      access.assertExecute(account, host.backend);
      if (Date.now() >= invite.expires) { throw new Error('AI_INVITE_EXPIRED'); }
      const response = await transport.post('/v1/pair', JSON.stringify({ code: invite.code,
        csr: identity.csr, name: deviceName.trim().slice(0, 80) || 'HarmonyOS' }));
      access.assertExecute(account, host.backend);
      if (aiString(response['instance']) !== invite.serverInstance || !aiIdValid(aiString(response['deviceId']))) {
        throw new Error('AI_SERVER_IDENTITY_MISMATCH');
      }
      credential.certificate = aiString(response['cert']);
      credential.privateKey = identity.privateKey;
      credential.deviceId = aiString(response['deviceId']);
      verified = new AiBridgeClient(host, credential, account);
      // A real authenticated roundtrip proves the returned certificate/key and
      // instance/device binding before any identity is committed locally.
      await verified.greet(invite.serverInstance, credential.deviceId);
      access.assertExecute(account, host.backend);
      await AiLocalStore.getInstance().saveHost(account, host, credential);
    } finally {
      identity.privateKey = ''; credential.privateKey = '';
      verified?.close(); transport.close(); unregister(); stop();
    }
  }
  private current(cleanup: boolean = false): void {
    if (this.closed) { throw new Error('AI_CONNECTION_CLOSED'); }
    if (cleanup) { this.access.assertCurrent(this.account); }
    else {
      if (this.revoked) { throw new Error('AI_RECONNECT_REQUIRED'); }
      this.access.assertExecute(this.account, this.host.backend);
    }
  }
  private async greet(instance: string, deviceId: string): Promise<void> {
    const result = aiRecord(await this.read('handshake', aiParams(["version"], [1])));
    const epoch = aiRecord(result['epoch']);
    const handshake: AiHandshake = { version: aiNumber(result['version']), engine: aiString(result['engine']),
      instance: aiString(result['instance']), deviceId: aiString(result['deviceId']), runtime: aiString(result['runtime']),
      role: aiString(result['role']), epoch: { id: aiString(epoch['id']), device: aiString(epoch['device']),
        expires: aiNumber(epoch['expires']) }, capabilities: aiRecord(result['capabilities']) };
    if (handshake.version !== 1 || handshake.engine !== this.host.backend || handshake.instance !== instance ||
      handshake.deviceId !== deviceId || !aiIdValid(handshake.runtime) || !aiIdValid(handshake.epoch.id) ||
      handshake.epoch.device !== deviceId || handshake.epoch.expires <= Date.now() ||
      !['operator', 'viewer'].includes(handshake.role)) { throw new Error('AI_SERVER_IDENTITY_MISMATCH'); }
    this.handshake = handshake;
  }
  capability(name: string): boolean { return this.handshake?.capabilities[name] === true; }
  choices(name: string): string[] {
    return aiArray(this.handshake?.capabilities[name]).filter((item: Object): boolean =>
      typeof item === 'string').map((item: Object): string => item as string);
  }
  async read(method: string, params: Record<string, Object> = {}): Promise<Object> {
    this.current();
    const response = await this.transport.post('/v1/rpc', JSON.stringify({ method, params }));
    this.current();
    if (response['result'] === undefined) { throw new Error('AI_RESPONSE_INVALID'); }
    return response['result'];
  }
  async write(method: string, params: Record<string, Object>, sessionId: string = ''): Promise<Record<string, Object>> {
    const cleanup = AI_CLEANUP_METHODS.includes(method);
    this.current(cleanup);
    if (cleanup && (sessionId === '' || this.ownedLeases.get(sessionId) !== aiString(params['lease']))) {
      throw new Error('AI_OWNED_LEASE_REQUIRED');
    }
    const handshake = this.handshake;
    if (handshake === null || handshake.role !== 'operator' || handshake.epoch.expires <= Date.now()) {
      throw new Error('AI_EPOCH_EXPIRED_RECONCILE');
    }
    const operationId = aiRandomId();
    const body = JSON.stringify({ method, params, operationId, epoch: handshake.epoch.id });
    const pending: AiPendingOperation = { id: operationId, hostId: this.host.id, sessionId,
      createdAt: Date.now(), body, receipt: '' };
    await this.store.retainOperation(this.account, pending);
    this.current(cleanup);
    // Never retry a write with a new operationId on timeout or connection loss.
    const response = await (cleanup ? this.cleanupTransport : this.transport).post('/v1/rpc', body);
    this.current(cleanup);
    const receipt = aiRecord(response['operation']);
    if (receipt['operationId'] !== operationId || receipt['epoch'] !== handshake.epoch.id) {
      throw new Error('AI_OPERATION_RECEIPT_INVALID');
    }
    await this.store.saveReceipt(this.account, operationId, JSON.stringify(receipt));
    this.current(cleanup);
    if (receipt['status'] === 'rejected') { throw new Error(aiString(receipt['error'], 'AI_OPERATION_REJECTED')); }
    if (receipt['status'] !== 'succeeded') { throw new Error('AI_OPERATION_UNKNOWN_RECONCILE'); }
    const result: Record<string, Object> = receipt['result'] === undefined ? {} : aiRecord(receipt['result']);
    if (method === 'lease.acquire' || method === 'lease.renew') {
      const lease = aiString(result['lease']);
      if (sessionId !== '' && lease !== '') { this.ownedLeases.set(sessionId, lease); }
    } else if (method === 'lease.release') { this.ownedLeases.delete(sessionId); }
    return result;
  }
  async reconcile(operation: AiPendingOperation): Promise<AiOperationReceipt> {
    if (operation.hostId !== this.host.id) { throw new Error('AI_OPERATION_INVALID'); }
    const result = aiRecord(await this.read('operation.read', aiParams(["operationId"], [operation.id])));
    if (result['status'] !== 'not_found' && result['operationId'] !== operation.id) {
      throw new Error('AI_OPERATION_RECEIPT_INVALID');
    }
    // not_found and old epochs are still uncertain; never dispatch here.
    await this.store.saveReceipt(this.account, operation.id, JSON.stringify(result));
    return result as Object as AiOperationReceipt;
  }
  async events(cursor: number, onEvent: (event: AiEvent) => void): Promise<void> {
    this.current();
    const runtime = this.handshake?.runtime ?? '';
    if (runtime === '') { throw new Error('AI_HANDSHAKE_REQUIRED'); }
    await this.transport.events(cursor, runtime, (event: AiEvent): void => {
      this.current();
      if (event.runtime !== runtime) { throw new Error('RESET_REQUIRED'); }
      onEvent(event);
    });
  }
  stopEvents(): void { this.transport.stopEvents(); }
  close(): void {
    if (this.closed) { return; }
    this.closed = true; this.handshake = null;
    this.transport.close(); this.cleanupTransport.close(); this.ownedLeases.clear();
    this.unregister(); this.stopAccess();
  }
}
