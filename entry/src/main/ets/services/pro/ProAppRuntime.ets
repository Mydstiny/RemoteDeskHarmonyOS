import { VERSION_CODE } from 'BuildProfile';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { AccountScopeToken } from '../AccountScopePolicy';
import { ProAccessContext, ProEnvironment } from './ProAccessPolicy';
import { proDevice } from './ProFeatureCatalog';
import { ProEntitlementService, ProOrderVerifier, ProVerificationResult } from './ProEntitlementService';
import { ProRuntime } from './ProRuntime';
// No production verifier is configured yet. Never infer delivery from a sandbox checkout callback.
class UnavailableProVerifier implements ProOrderVerifier {
  async verify(_records: string[], owner: string, environment: ProEnvironment): Promise<ProVerificationResult> {
    return { status: 'unavailable', owner, environment };
  }
}
export class ProAppRuntime {
  private static instance: ProAppRuntime;
  private entitlement: ProEntitlementService = new ProEntitlementService(new UnavailableProVerifier());
  readonly runtime: ProRuntime = new ProRuntime(this.entitlement);
  private stopAccount: (() => void) | null = null;
  private stopTransition: (() => void) | null = null;
  private transitionActive: boolean = false;
  static getInstance(): ProAppRuntime {
    if (!ProAppRuntime.instance) { ProAppRuntime.instance = new ProAppRuntime(); }
    ProAppRuntime.instance.start();
    return ProAppRuntime.instance;
  }
  private start(): void {
    if (this.stopAccount !== null) { return; }
    const account = AccountSessionCoordinator.getInstance();
    this.stopTransition = account.onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      this.bindScope(account.currentScope());
    });
    this.stopAccount = account.onChange((scope: AccountScopeToken): void => { this.bindScope(scope); });
    this.bindScope(account.currentScope());
  }
  private bindScope(scope: AccountScopeToken): void {
    const usable = !this.transitionActive && scope.kind === 'huawei_account' &&
      (scope.sessionState === 'bound' || scope.sessionState === 'ready' || scope.sessionState === 'offline');
    this.entitlement.bindAccount(usable ? scope.ownerScopeId : '', 'production', scope.generation);
  }
  context(protocol: string = ''): ProAccessContext {
    return { appVersionCode: VERSION_CODE, apiVersion: deviceInfo.sdkApiVersion,
      device: proDevice(deviceInfo.deviceType), protocol, capabilities: [],
      grantedPermissions: [], requestablePermissions: [] };
  }
}
