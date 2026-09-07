import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AccountKitService } from '../AccountKitService';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { ownerScopeIdForUnionId } from '../AccountScopePolicy';
import { ProBackendConfiguration } from './ProBackendConfiguration';
import { ProBackendOperation, ProBackendTransport } from './ProTrustedEntitlementClient';

export class ProHttpTransport implements ProBackendTransport {
  private intentsUrl: string;
  private reconcileUrl: string;
  private requests: http.HttpRequest[] = [];
  constructor(configuration: ProBackendConfiguration) {
    this.intentsUrl = configuration.intentsUrl;
    this.reconcileUrl = configuration.reconcileUrl;
    for (const value of [this.intentsUrl, this.reconcileUrl]) {
      if (!/^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9/_-]+$/.test(value) || value.length > 2048) {
        throw new Error('Invalid Pro service address');
      }
    }
  }
  async post(operation: ProBackendOperation, body: string, isCurrent: () => boolean): Promise<string> {
    if (!isCurrent() || new util.TextEncoder().encodeInto(body).length > 1024 * 1024) {
      throw new Error('Pro request cancelled');
    }
    const account = AccountSessionCoordinator.getInstance().currentScope();
    const auth = AccountKitService.getInstance();
    const token = auth.getAccessToken();
    if (account.kind !== 'huawei_account' ||
      ownerScopeIdForUnionId(auth.getUnionID()) !== account.ownerScopeId ||
      !/^[^\s,\u0000-\u001f\u007f]{1,16384}$/.test(token) || !isCurrent()) {
      throw new Error('Pro account login required');
    }
    const request = http.createHttp();
    this.requests.push(request);
    try {
      const response = await request.request(operation === 'intents' ? this.intentsUrl : this.reconcileUrl, {
        method: http.RequestMethod.POST, header: { 'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ' + token, 'Accept': 'application/json' }, extraData: body,
        expectDataType: http.HttpDataType.STRING, usingCache: false, remoteValidation: 'system', maxRedirects: 0,
        connectTimeout: 10000, readTimeout: 15000, maxLimit: 32768
      });
      if (!isCurrent() || response.responseCode !== 200 || typeof response.result !== 'string' ||
        new util.TextEncoder().encodeInto(response.result).length > 32768) { throw new Error('Pro verification unavailable'); }
      return response.result;
    } finally {
      this.requests = this.requests.filter((item: http.HttpRequest): boolean => item !== request);
      request.destroy();
    }
  }
  cancel(): void {
    const active = this.requests.slice(); this.requests = [];
    active.forEach((request: http.HttpRequest): void => { request.destroy(); });
  }
}
