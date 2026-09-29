import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProFeatureVisibility } from './ProFeatureVisibility';

/**
 * The one definition of whether a Pro entry point is shown: the user's "Pro 功能显示"
 * choice AND the entitlement decision (plan, account, device, version, capability).
 * Every Pro row, card, tab or sheet entry must use visible() (or ProFeatureGate, which
 * calls it) so a new Pro feature follows the entitlement without extra wiring.
 * UI visibility is not authority: business actions still call runtime.run/decision.
 */
export class ProEntries {
  static visible(featureId: string, context: ProAccessContext = ProAppRuntime.getInstance().context()): boolean {
    return ProEntries.shown(featureId) &&
      ProAppRuntime.getInstance().runtime.decision(featureId, context).visible;
  }

  /**
   * Only the user's display choice, without entitlement. Reserved for free affordances
   * that must survive a revocation (e.g. restoring the default icon) and for the
   * purchase/visibility settings that describe features the user does not own.
   */
  static shown(featureId: string): boolean {
    return ProFeatureVisibility.getInstance().isVisible(featureId);
  }

  /** Pro is active for this account (in Debug this includes the simulated Pro view). */
  static proActive(): boolean {
    return ProAppRuntime.getInstance().runtime.snapshot().effectiveState === 'active';
  }

  /** Fires on entitlement and on display-choice changes. */
  static subscribe(listener: () => void): () => void {
    const stopRuntime = ProAppRuntime.getInstance().runtime.subscribe(listener);
    const stopVisibility = ProFeatureVisibility.getInstance().subscribe(listener);
    return (): void => { stopRuntime(); stopVisibility(); };
  }
}
