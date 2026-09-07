import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AccountKitService } from '../AccountKitService';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { ownerScopeIdForUnionId } from '../AccountScopePolicy';
import { ProBackendConfiguration } from './ProBackendConfiguration';
import { ProAccountSession } from './ProAccountSession';
import { ProBackendOperation, ProBackendTransport } from './ProTrustedEntitlementClient';

interface ProHttpReply { status: number; body: string; }
export class ProHttpTransport implements ProBackendTransport {
  private sessionUrl: string;
  private intentsUrl: string;
  private reconcileUrl: string;
  private session: ProAccountSession;
  private generation: number = 0;
  private requests: http.HttpRequest[] = [];
  constructor(configuration: ProBackendConfiguration, context: common.Context) {
    this.sessionUrl = configuration.sessionUrl;
    this.intentsUrl = configuration.intentsUrl;
    this.reconcileUrl = configuration.reconcileUrl;
    for (const value of [this.sessionUrl, this.intentsUrl, this.reconcileUrl]) {
      if (!/^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9/_-]+$/.test(value) || value.length > 2048) {
        throw new Error('Invalid Pro service address');
      }
    }
    this.session = new ProAccountSession(context, async (body: string, isCurrent: () => boolean): Promise<string> => {
      const response = await this.send(this.sessionUrl, body, '', isCurrent);
      if (response.status !== 200) { throw new Error('Pro account login required'); }
      return response.body;
    });
  }
  async post(operation: ProBackendOperation, body: string, isCurrent: () => boolean): Promise<string> {
    if (!isCurrent() || new util.TextEncoder().encodeInto(body).length > 1024 * 1024) {
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
      const response = await this.send(operation === 'intents' ? this.intentsUrl : this.reconcileUrl, body, token, current);
      if (response.status === 200) { return response.body; }
      if (response.status !== 401 || attempt > 0) { throw new Error('Pro verification unavailable'); }
      this.session.invalidate(token);
    }
    throw new Error('Pro verification unavailable');
  }
  private async send(url: string, body: string, token: string, isCurrent: () => boolean): Promise<ProHttpReply> {
    if (!isCurrent()) { throw new Error('Pro request cancelled'); }
    const request = http.createHttp();
    this.requests.push(request);
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json; charset=utf-8', 'Accept': 'application/json' };
      if (token.length > 0) { headers['Authorization'] = 'Bearer ' + token; }
      const response = await request.request(url, {
        method: http.RequestMethod.POST, header: headers, extraData: body,
        expectDataType: http.HttpDataType.STRING, usingCache: false, remoteValidation: 'system', maxRedirects: 0,
        connectTimeout: 10000, readTimeout: 15000, maxLimit: 32768
      });
      if (!isCurrent() || typeof response.result !== 'string' ||
        new util.TextEncoder().encodeInto(response.result).length > 32768) { throw new Error('Pro verification unavailable'); }
      return { status: response.responseCode, body: response.result };
    } finally {
      this.requests = this.requests.filter((item: http.HttpRequest): boolean => item !== request);
      request.destroy();
    }
  }
  cancel(): void {
    this.generation++;
    this.session.clear();
    const active = this.requests.slice(); this.requests = [];
    active.forEach((request: http.HttpRequest): void => { request.destroy(); });
  }
}
