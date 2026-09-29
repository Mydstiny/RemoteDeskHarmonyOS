import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { AccountScopeToken } from '../AccountScopePolicy';
import { ProAppRuntime } from '../pro/ProAppRuntime';
import { ProFeatureVisibility } from '../pro/ProFeatureVisibility';
import { AiBackend, aiOwnerValid } from './AiModels';
import { AiLifecycle } from './AiLifecycle';

export interface AiAccountLease { owner: string; generation: number; lifecycle: number; }
/** Same authority as the rest of Pro, plus account-transition fencing. */
export class AiAccess {
  private static instance: AiAccess;
  private transitioning: boolean = false;
  private listeners: Array<() => void> = [];
  private constructor() {
    const account = AccountSessionCoordinator.getInstance();
    account.onTransitionActivity((active: boolean): void => {
      this.transitioning = active;
      if (active) { AiLifecycle.invalidateAll(); }
      this.publish();
    });
    account.onChange((_scope: AccountScopeToken): void => { this.publish(); });
    ProAppRuntime.getInstance().runtime.subscribe((): void => { this.publish(); });
    ProFeatureVisibility.getInstance().subscribe((): void => { this.publish(); });
  }
  static getInstance(): AiAccess {
    if (!AiAccess.instance) { AiAccess.instance = new AiAccess(); }
    return AiAccess.instance;
  }
  capture(): AiAccountLease {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (AiLifecycle.restoring() || this.transitioning || scope.kind !== 'huawei_account' || !aiOwnerValid(scope.ownerScopeId) ||
      !['bound', 'ready', 'offline'].includes(scope.sessionState)) {
      throw new Error('AI_ACCOUNT_UNAVAILABLE');
    }
    return { owner: scope.ownerScopeId, generation: scope.generation, lifecycle: AiLifecycle.generation() };
  }
  current(lease: AiAccountLease): boolean {
    try {
      const now = this.capture();
      return now.owner === lease.owner && now.generation === lease.generation && now.lifecycle === lease.lifecycle;
    } catch (_error) { return false; }
  }
  assertCurrent(lease: AiAccountLease): void {
    if (!this.current(lease)) { throw new Error('AI_ACCOUNT_CHANGED'); }
  }
  executable(backend: AiBackend): boolean {
    try { this.capture(); } catch (_error) { return false; }
    const pro = ProAppRuntime.getInstance();
    return ProFeatureVisibility.getInstance().isVisible('pro.ai.workspace') &&
      ProFeatureVisibility.getInstance().isVisible('pro.ai.' + backend) &&
      pro.runtime.decision('pro.ai.workspace', pro.context('ai')).executable &&
      pro.runtime.decision('pro.ai.' + backend, pro.context('ai')).executable;
  }
  /**
   * UI admission for the whole remote-AI surface.  Keep this separate from
   * executable(), which also requires a bound Huawei account and a concrete
   * backend.  A refund/revocation must close the add/settings surfaces before
   * an account lease is captured.
   */
  proVisible(): boolean {
    const pro = ProAppRuntime.getInstance();
    return ProFeatureVisibility.getInstance().isVisible('pro.ai.workspace') &&
      pro.runtime.decision('pro.ai.workspace', pro.context('ai')).visible;
  }
  assertExecute(lease: AiAccountLease, backend: AiBackend): void {
    this.assertCurrent(lease);
    if (!this.executable(backend)) { throw new Error('AI_PRO_ACCESS_REQUIRED'); }
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    listener();
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* A closing window cannot block other owners. */ }
    });
  }
}
