import { ProEntitlementState } from './ProAccessPolicy';
import { PRO_LIFETIME } from './ProFeatureCatalog';

/**
 * 1.2.0 免费试用: the merchant contract is still under review, so every user has Pro until charging starts (users are
 * told before it does). Turning this off restores the real, signed entitlement as the only source of Pro.
 */
export const PRO_COMPLIMENTARY_TRIAL: boolean = true;

export interface ProComplimentaryGrant {
  state: ProEntitlementState;
  ids: string[];
  /** Pro comes from the free trial rather than a purchase. */
  complimentary: boolean;
}

/**
 * The entitlement the runtime acts on. During the free trial everyone is treated as Pro — unless a real refund is
 * pending or the purchase was revoked, which the trial never overrides. Nothing is signed or stored: the real
 * entitlement (and its store) stay exactly as they are.
 */
export function proComplimentaryGrant(state: ProEntitlementState, ids: string[], refundPending: boolean,
  enabled: boolean = PRO_COMPLIMENTARY_TRIAL): ProComplimentaryGrant {
  if (!enabled || refundPending || state === 'revoked' || state === 'active') {
    return { state: state, ids: ids, complimentary: false };
  }
  return { state: 'active', ids: ids.indexOf(PRO_LIFETIME) >= 0 ? ids : ids.concat([PRO_LIFETIME]), complimentary: true };
}
