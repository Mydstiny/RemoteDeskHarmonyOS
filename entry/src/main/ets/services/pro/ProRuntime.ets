import { DEBUG } from 'BuildProfile';
import { ProAccessContext, ProAccessDecision, ProEntitlementState, proFeatureAccess,
  resolveProFeatureAccess } from './ProAccessPolicy';
import { ProFeature, proFeatures, PRO_LIFETIME } from './ProFeatureCatalog';
import { ProEntitlementService, ProEntitlementSnapshot } from './ProEntitlementService';
export type ProDebugMode = 'real' | 'free' | 'pro';
export interface ProRuntimeSnapshot {
  realState: ProEntitlementState;
  effectiveState: ProEntitlementState;
  mode: ProDebugMode;
  label: string;
  needsRevalidation: boolean;
}
export class ProRuntime {
  private debugMode: ProDebugMode = 'real';
  private listeners: Array<() => void> = [];
  private timer: number = -1;
  private stopEntitlement: () => void;
  private entitlement: ProEntitlementService;
  constructor(entitlement: ProEntitlementService) {
    this.entitlement = entitlement;
    this.stopEntitlement = entitlement.subscribe((): void => { this.publish(); });
  }
  snapshot(): ProRuntimeSnapshot {
    const real: ProEntitlementSnapshot = this.entitlement.snapshot();
    let effectiveState = real.state;
    let mode: ProDebugMode = 'real';
    if (DEBUG) {
      mode = this.debugMode;
      if (mode === 'pro') { effectiveState = 'active'; }
      if (mode === 'free') { effectiveState = 'free'; }
    }
    let label = effectiveState === 'active' ? 'Pro 已激活' : effectiveState === 'verificationRequired' ?
      '权益待验证' : effectiveState === 'revoked' ? 'Pro 权益已撤销' : '免费版';
    if (DEBUG) {
      if (mode === 'real' && real.environment === 'sandbox') { label = '沙盒 · ' + label; }
      if (mode === 'pro') { label = '模拟 Pro'; }
      if (mode === 'free') { label = '模拟免费'; }
    }
    return { realState: real.state, effectiveState, mode, label, needsRevalidation: real.needsRevalidation };
  }
  setDebugMode(mode: ProDebugMode): void {
    // Both this write and the read/override in snapshot/decision are removed from Release bytecode.
    if (DEBUG) {
      if (mode !== 'real' && mode !== 'free' && mode !== 'pro') { return; }
      if (mode === this.debugMode) { return; }
      this.debugMode = mode;
      this.publish();
    }
  }
  decision(id: string, context: ProAccessContext): ProAccessDecision {
    const real = this.entitlement.snapshot();
    let state = real.state;
    let ids = real.entitlementIds;
    if (DEBUG) {
      if (this.debugMode === 'pro') {
        state = 'active'; ids = [PRO_LIFETIME];
        const feature: ProFeature | undefined = proFeatures().find((item: ProFeature): boolean => item.id === id);
        // Implemented experiments are reachable only in an explicit Debug Pro
        // view; all device, protocol and capability checks still apply.
        if (feature !== undefined && feature.availability === 'experimental') {
          feature.availability = 'available';
          return resolveProFeatureAccess(feature, context, state, ids);
        }
      }
      if (this.debugMode === 'free') { state = 'free'; ids = []; }
    }
    return proFeatureAccess(id, context, state, ids);
  }
  run(id: string, context: ProAccessContext, action: () => void): ProAccessDecision {
    const decision = this.decision(id, context);
    if (decision.executable) { action(); }
    return decision;
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
    const delay = this.entitlement.nextChangeDelay();
    if (delay <= 0 || this.listeners.length === 0) { return; }
    this.timer = setTimeout((): void => { this.timer = -1; this.publish(); },
      Math.min(delay, 2147483647));
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* one window cannot block another */ }
    });
    this.scheduleBoundary();
  }
}
