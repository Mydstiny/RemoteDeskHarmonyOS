import { DEBUG } from 'BuildProfile';
import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AccountKitService } from '../AccountKitService';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { ownerScopeIdForUnionId } from '../AccountScopePolicy';
import { ProBackendConfiguration } from './ProBackendConfiguration';
import { ProAccountSession } from './ProAccountSession';
import { ProBackendOperation, ProBackendTransport } from './ProTrustedEntitlementClient';

interface ProCloudReply { version: number; status: number; body: string; }
interface ProCloudEnvelope { version: number; operation: string; sessionToken: string; body: string; }
export class ProCloudTransport implements ProBackendTransport {
  private static initialized: boolean = false;
  private static pendingCalls: number = 0;
  private functionName: string;
  private functionVersion: string;
  private session: ProAccountSession;
  private generation: number = 0;
  private cancellations: (() => void)[] = [];
  constructor(configuration: ProBackendConfiguration, context: common.Context) {
    this.functionName = configuration.functionName;
    this.functionVersion = configuration.functionVersion;
    if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(this.functionName) ||
      !/^(\$latest|[1-9][0-9]{0,7})$/.test(this.functionVersion)) {
      throw new Error('Invalid Pro cloud function');
    }
    if (!ProCloudTransport.initialized) {
      cloudCommon.init({ region: cloudCommon.CloudRegion.CHINA });
      ProCloudTransport.initialized = true;
    }
    this.session = new ProAccountSession(context, async (body: string, isCurrent: () => boolean): Promise<string> => {
      const response = await this.send('session', body, '', isCurrent);
      if (response.status !== 200) { throw new Error('Pro account login required'); }
      return response.body;
    });
  }
  async post(operation: ProBackendOperation, body: string, isCurrent: () => boolean): Promise<string> {
    if (!isCurrent() || ProCloudTransport.pendingCalls >= 4 ||
      !['intents', 'reconcile', 'refund-order'].includes(operation) || new util.TextEncoder().encodeInto(body).length > 1024 * 1024) {
      throw new Error('Pro request cancelled');
    }
    const account = AccountSessionCoordinator.getInstance().currentScope();
    const auth = AccountKitService.getInstance();
    const owner = ownerScopeIdForUnionId(auth.getUnionID());
    if (account.kind !== 'huawei_account' ||
      !auth.isAuthorized() || owner !== account.ownerScopeId || !isCurrent()) {
      throw new Error('Pro account login required');
    }
    const generation = this.generation;
    const current = (): boolean => {
      const scope = AccountSessionCoordinator.getInstance().currentScope();
      return generation === this.generation && isCurrent() && scope.kind === 'huawei_account' && scope.generation === account.generation &&
        scope.ownerScopeId === owner && auth.isAuthorized() && ownerScopeIdForUnionId(auth.getUnionID()) === owner;
    };
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await this.session.get(owner, account.generation, current);
      const response = await this.send(operation, body, token, current);
      if (response.status === 200) { return response.body; }
      if (response.status !== 401 || attempt > 0) { throw new Error('Pro verification unavailable'); }
      this.session.invalidate(token);
    }
    throw new Error('Pro verification unavailable');
  }
  private async send(operation: string, body: string, token: string, isCurrent: () => boolean): Promise<ProCloudReply> {
    if (!isCurrent() || ProCloudTransport.pendingCalls >= 4) { throw new Error('Pro request cancelled'); }
    const envelope: ProCloudEnvelope = { version: 1, operation, sessionToken: token, body };
    let timer: number = -1;
    let cancel: () => void = (): void => {};
    const cancelled = new Promise<null>((resolve: (value: null) => void): void => {
      cancel = (): void => { resolve(null); };
      timer = setTimeout(cancel, 20000);
    });
    this.cancellations.push(cancel);
    ProCloudTransport.pendingCalls++;
    try {
      // Cloud Foundation has no native cancel API. Keep the global slot until
      // its promise settles, including after a local timeout/account change.
      const pending = Promise.resolve().then((): Promise<cloudFunction.FunctionResult> => {
        if (!isCurrent()) { throw new Error('Pro request cancelled'); }
        return cloudFunction.call({ name: this.functionName, version: this.functionVersion,
          data: envelope, timeout: 15000, loadMode: cloudFunction.LoadMode.NORMAL });
      }).finally((): void => { ProCloudTransport.pendingCalls--; });
      const response = await Promise.race([pending, cancelled]) as cloudFunction.FunctionResult | null;
      if (!isCurrent() || response === null) { throw new Error('Pro request cancelled'); }
      const text = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      if (typeof text !== 'string' || new util.TextEncoder().encodeInto(text).length > 65536) {
        throw new Error('Pro verification unavailable');
      }
      const reply = JSON.parse(text) as ProCloudReply;
      if (!reply || Object.keys(reply).length !== 3 || reply.version !== 1 ||
        !Number.isInteger(reply.status) || reply.status < 200 || reply.status > 599 ||
        typeof reply.body !== 'string' || new util.TextEncoder().encodeInto(reply.body).length > 32768) {
        throw new Error('Pro verification unavailable');
      }
      if (DEBUG) { console.info(`[ProVerify] cloud ${operation} status=${reply.status}`); }
      return reply;
    } finally {
      if (timer !== -1) { clearTimeout(timer); }
      this.cancellations = this.cancellations.filter((item: () => void): boolean => item !== cancel);
    }
  }
  cancel(): void {
    this.generation++;
    this.session.clear();
    const active = this.cancellations.slice(); this.cancellations = [];
    active.forEach((cancel: () => void): void => { cancel(); });
  }
}
