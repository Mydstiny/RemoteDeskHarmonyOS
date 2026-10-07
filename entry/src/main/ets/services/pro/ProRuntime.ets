import { DEBUG } from 'BuildProfile';
import { ProAccessContext, ProAccessDecision, ProEntitlementState, proFeatureAccess,
  resolveProFeatureAccess } from './ProAccessPolicy';
import { ProFeature, proFeatures, PRO_LIFETIME } from './ProFeatureCatalog';
import { ProEntitlementService, ProEntitlementSnapshot } from './ProEntitlementService';
import { ProComplimentaryGrant, proComplimentaryGrant } from './ProComplimentaryPolicy';
import { proDeveloperToolsVisible } from './ProDeveloperTools';
export type ProDebugMode = 'real' | 'free' | 'pro';
export interface ProRuntimeSnapshot {
  realState: ProEntitlementState;
  effectiveState: ProEntitlementState;
  mode: ProDebugMode;
  label: string;
  needsRevalidation: boolean;
  refundPending: boolean;
  /** Pro comes from the 1.2.0 free trial, not a purchase. */
  complimentary: boolean;
}
export class ProRuntime {
  private debugMode: ProDebugMode = 'real';
  private listeners: Array<() => void> = [];
  private timer: number = -1;
  private stopEntitlement: () => void;
  private entitlement: ProEntitlementService;
  constructor(entitlement: ProEntitlementService) {
    this.entitlement = entitlement;
    this.stopEntitlement = entitlement.subscribe((): void => {
      if (DEBUG && entitlement.snapshot().refundPending) { this.debugMode = 'real'; }
      this.publish();
    });
  }
  snapshot(): ProRuntimeSnapshot {
    const real: ProEntitlementSnapshot = this.entitlement.snapshot();
    // The free trial: Pro for everyone, on top of (never instead of) the real entitlement.
    const granted: ProComplimentaryGrant = proComplimentaryGrant(real.state, real.entitlementIds, real.refundPending);
    let effectiveState = granted.state;
    let mode: ProDebugMode = 'real';
    if (DEBUG && !real.refundPending) {
      mode = this.debugMode;
      if (mode === 'pro') { effectiveState = 'active'; }
      if (mode === 'free') { effectiveState = 'free'; }
    }
    let label = effectiveState === 'active' ? (granted.complimentary ? 'Pro 免费试用中' : 'Pro 已激活') :
      effectiveState === 'verificationRequired' ?
      '权益待验证' : effectiveState === 'revoked' ? 'Pro 权益已撤销' : '免费版';
    if (DEBUG) {
      if (mode === 'real' && real.environment === 'sandbox' && proDeveloperToolsVisible()) { label = '沙盒 · ' + label; }
      if (mode === 'pro') { label = '模拟 Pro'; }
      if (mode === 'free') { label = '模拟免费'; }
    }
    return { realState: real.state, effectiveState, mode, label,
      needsRevalidation: real.needsRevalidation, refundPending: real.refundPending,
      complimentary: granted.complimentary && mode === 'real' };
  }
  setDebugMode(mode: ProDebugMode): void {
    // Both this write and the read/override in snapshot/decision are removed from Release bytecode.
    if (DEBUG) {
      if (mode !== 'real' && mode !== 'free' && mode !== 'pro') { return; }
      if (this.entitlement.snapshot().refundPending && mode !== 'real') { return; }
      if (mode === this.debugMode) { return; }
      this.debugMode = mode;
      this.publish();
    }
  }
  // Account/environment rebinding must not expose the previous Debug Pro
  // override while the new scope restores its trusted entitlement.
  resetDebugMode(): void { if (DEBUG) { this.debugMode = 'real'; } }
  decision(id: string, context: ProAccessContext): ProAccessDecision {
    const real = this.entitlement.snapshot();
    const granted: ProComplimentaryGrant = proComplimentaryGrant(real.state, real.entitlementIds, real.refundPending);
    let state = granted.state;
    let ids = granted.ids;
    if (DEBUG && !real.refundPending) {
      if (this.debugMode === 'pro') { state = 'active'; ids = [PRO_LIFETIME]; }
      if (this.debugMode === 'free') { state = 'free'; ids = []; }
      // Debug builds let any active Pro view (the real sandbox subscription or the
      // simulated one) reach implemented experiments, so testing matches what a
      // subscriber sees; all device, protocol and capability checks still apply.
      // Release bytecode drops this branch and never exposes experiments.
      if (state === 'active') {
        const feature: ProFeature | undefined = proFeatures().find((item: ProFeature): boolean => item.id === id);
        if (feature !== undefined && feature.availability === 'experimental') {
          feature.availability = 'available';
          return resolveProFeatureAccess(feature, context, state, ids);
        }
      }
    }
    return proFeatureAccess(id, context, state, ids);
  }
  run(id: string, context: ProAccessContext, action: () => void): ProAccessDecision {
    const decision = this.decision(id, context);
    if (decision.executable) { action(); }
    return decision;
  }
  markRefundPending(): void {
    if (DEBUG) { this.debugMode = 'real'; }
    this.entitlement.markRefundPending();
  }
  refresh(): void { this.entitlement.refresh(); }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    try { listener(); } catch (_error) { /* isolate subscribers */ }
    this.scheduleBoundary();
    return (): void => {
      this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
      this.scheduleBoundary();
    };
  }
  dispose(): void {
    this.stopEntitlement();
    this.listeners = [];
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
  }
  private scheduleBoundary(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    let delay = this.entitlement.nextChangeDelay();
    if (this.entitlement.snapshot().needsRevalidation) {
      delay = delay > 0 ? Math.min(delay, 300000) : 300000;
    }
    if (delay <= 0 || this.listeners.length === 0) { return; }
    this.timer = setTimeout((): void => { this.timer = -1; this.entitlement.refresh(); },
      Math.min(delay, 2147483647));
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* one window cannot block another */ }
    });
    this.scheduleBoundary();
  }
}
