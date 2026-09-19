import { DEBUG, VERSION_CODE } from 'BuildProfile';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { AccountScopeToken } from '../AccountScopePolicy';
import { ProAccessContext, ProEnvironment } from './ProAccessPolicy';
import { proDevice } from './ProFeatureCatalog';
import { ProEntitlementService, ProOrderVerifier, ProVerificationResult, ProReconciliationOutcome } from './ProEntitlementService';
import { ProRuntime } from './ProRuntime';
import { proBackendConfiguration } from './ProBackendConfiguration';
import { ProEntitlementClock } from './ProEntitlementClock';
import { ProEntitlementStore } from './ProEntitlementStore';
import { ProCloudTransport } from './ProCloudTransport';
import { ProClientLease, ProPurchaseIntent, ProTrustedEntitlementClient, proPurchaseBatches } from './ProTrustedEntitlementClient';
import { ProBillingBackend } from './ProBillingService';
class ProVerifierBridge implements ProOrderVerifier {
  client: ProTrustedEntitlementClient | null = null;
  async verify(records: string[], owner: string, environment: ProEnvironment): Promise<ProVerificationResult> {
    if (this.client !== null) { return this.client.verify(records, owner, environment); }
    return { status: 'unavailable', owner, environment };
  }
  async loadCached(owner: string, environment: ProEnvironment): Promise<ProVerificationResult> {
    if (this.client !== null) { return this.client.loadCached(owner, environment); }
    return { status: 'unavailable', owner, environment, fromCache: true };
  }
}
export class ProAppRuntime implements ProBillingBackend {
  private static instance: ProAppRuntime;
  private clock: ProEntitlementClock = new ProEntitlementClock();
  private bridge: ProVerifierBridge = new ProVerifierBridge();
  private store: ProEntitlementStore = ProEntitlementStore.getInstance();
  private entitlement: ProEntitlementService = new ProEntitlementService(this.bridge, (): number => this.clock.now());
  readonly runtime: ProRuntime = new ProRuntime(this.entitlement);
  private productionClient: ProTrustedEntitlementClient | null = null;
  private sandboxClient: ProTrustedEntitlementClient | null = null;
  private environment: ProEnvironment = 'production';
  private initializing: Promise<void> | null = null;
  private initialized: boolean = false;
  private boundKey: string = '';
  private refreshing: boolean = false;
  private lastReconcileAt: number = 0;
  private stopAccount: (() => void) | null = null;
  private stopTransition: (() => void) | null = null;
  private transitionActive: boolean = false;
  static getInstance(): ProAppRuntime {
    if (!ProAppRuntime.instance) { ProAppRuntime.instance = new ProAppRuntime(); }
    ProAppRuntime.instance.start();
    return ProAppRuntime.instance;
  }
  initialize(context: common.Context): Promise<void> {
    if (this.initialized) { return Promise.resolve(); }
    if (this.initializing !== null) { return this.initializing; }
    this.initializing = this.store.initialize(context).then((): void => {
      if (DEBUG) {
        const configuration = proBackendConfiguration('sandbox');
        if (configuration !== null) {
          this.sandboxClient = new ProTrustedEntitlementClient(configuration.trust, this.store,
            new ProCloudTransport(configuration, context), this.clock);
        }
      }
      const production = proBackendConfiguration('production');
      if (!DEBUG && production !== null && production.trust.environment === 'production') {
        this.productionClient = new ProTrustedEntitlementClient(production.trust, this.store,
          new ProCloudTransport(production, context), this.clock);
      }
      this.initialized = true;
      this.boundKey = '';
      this.selectClient();
      this.bindScope(AccountSessionCoordinator.getInstance().currentScope());
    }).finally((): void => { this.initializing = null; });
    return this.initializing;
  }
  setSandbox(enabled: boolean): void {
    if (DEBUG) {
      const environment: ProEnvironment = enabled ? 'sandbox' : 'production';
      if (this.environment === environment) { return; }
      this.bridge.client?.bind('', -1);
      this.environment = environment;
      this.selectClient();
      this.bindScope(AccountSessionCoordinator.getInstance().currentScope());
    }
  }
  sandboxSelected(): boolean { return DEBUG && this.environment === 'sandbox'; }
  private selectClient(): void {
    this.bridge.client = this.environment === 'production' ? this.productionClient : null;
    if (DEBUG && this.environment === 'sandbox') { this.bridge.client = this.sandboxClient; }
  }
  billingProductId(): string { return proBackendConfiguration(this.environment)?.trust.productId ?? ''; }
  billingAvailable(): boolean { return this.bridge.client !== null; }
  private start(): void {
    if (this.stopAccount !== null) { return; }
    const account = AccountSessionCoordinator.getInstance();
    this.stopTransition = account.onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      this.bindScope(account.currentScope());
    });
    this.stopAccount = account.onChange((scope: AccountScopeToken): void => { this.bindScope(scope); });
    this.entitlement.subscribe((): void => {
      if (this.entitlement.snapshot().needsRevalidation) { void this.refreshOnline(); }
    });
    this.bindScope(account.currentScope());
  }
  private bindScope(scope: AccountScopeToken): void {
    const usable = !this.transitionActive && scope.kind === 'huawei_account' &&
      (scope.sessionState === 'bound' || scope.sessionState === 'ready' || scope.sessionState === 'offline');
    const owner = usable ? scope.ownerScopeId : '';
    this.bridge.client?.bind(owner, scope.generation);
    this.entitlement.bindAccount(owner, this.environment, scope.generation);
    const key = owner + ':' + scope.generation.toString() + ':' + this.environment;
    if (key !== this.boundKey) {
      this.boundKey = key;
      this.lastReconcileAt = 0;
      if (owner.length > 0 && this.bridge.client !== null) {
        void this.entitlement.restoreCached().then((): void => { void this.refreshOnline(); });
      }
    }
  }
  lease(productId: string): ProClientLease | null {
    const lease = this.bridge.client?.lease() ?? null;
    return lease !== null && lease.scope.productId === productId ? lease : null;
  }
  current(lease: ProClientLease): boolean { return this.bridge.client?.current(lease) === true; }
  intent(lease: ProClientLease, isCurrent: () => boolean): Promise<ProPurchaseIntent> {
    const client = this.bridge.client;
    if (client === null || !client.current(lease)) { return Promise.reject(new Error('Pro service unavailable')); }
    return client.intent(lease, isCurrent);
  }
  retain(lease: ProClientLease, records: string[]): Promise<void> {
    // Retain late payment receipts in their captured environment, including after a UI switch.
    if (lease.scope.environment === 'production' && this.productionClient !== null) {
      return this.productionClient.retain(lease, records);
    }
    if (DEBUG && lease.scope.environment === 'sandbox' && this.sandboxClient !== null) { return this.sandboxClient.retain(lease, records); }
    return Promise.reject(new Error('Pro service unavailable'));
  }
  pending(lease: ProClientLease): Promise<string[]> {
    const client = this.bridge.client;
    if (client === null) { return Promise.reject(new Error('Pro service unavailable')); }
    return client.pending(lease);
  }
  refundOrder(lease: ProClientLease, isCurrent: () => boolean): Promise<string> {
    const client = this.bridge.client;
    if (!DEBUG || client === null || !client.current(lease)) { return Promise.reject(new Error('Pro service unavailable')); }
    return client.refundOrder(lease, isCurrent);
  }
  reconcile(lease: ProClientLease, records: string[]): Promise<ProReconciliationOutcome> {
    if (!this.current(lease)) { return Promise.resolve<ProReconciliationOutcome>({ current: false, online: false, active: false }); }
    return this.entitlement.reconcileResult(records);
  }
  async refreshOnline(): Promise<void> {
    const client = this.bridge.client;
    const lease = client?.lease() ?? null;
    if (client === null || lease === null || this.refreshing ||
      (Date.now() >= this.lastReconcileAt && Date.now() - this.lastReconcileAt < 300000)) { return; }
    this.refreshing = true; this.lastReconcileAt = Date.now();
    try {
      const pending = await client.pending(lease);
      const batches = proPurchaseBatches(pending);
      if (batches.length === 0) { batches.push([]); }
      for (const batch of batches) {
        if (!this.current(lease)) { return; }
        const outcome = await this.reconcile(lease, batch);
        if (!outcome.current || !outcome.online) { return; }
      }
    } catch (_error) { /* A valid signed cache retains its original expiry. */ }
    finally {
      this.refreshing = false;
      if (!this.current(lease)) { void this.refreshOnline(); }
    }
  }
  context(protocol: string = ''): ProAccessContext {
    return { appVersionCode: VERSION_CODE, apiVersion: deviceInfo.sdkApiVersion,
      device: proDevice(deviceInfo.deviceType), protocol, capabilities: [],
      grantedPermissions: [], requestablePermissions: [] };
  }
}
