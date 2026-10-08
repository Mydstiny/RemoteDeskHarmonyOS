import { ProFeature, proFeatures, ProDevice, PRO_LIFETIME } from './ProFeatureCatalog';
export type ProEnvironment = 'sandbox' | 'production';
export interface ProVerifiedGrant {
  owner: string;
  environment: ProEnvironment;
  productId: string;
  entitlementIds: string[];
  verifiedAt: number;
  revalidateAfter: number;
  usableUntil: number;
}
export type ProEntitlementState = 'free' | 'active' | 'verificationRequired' | 'revoked';
export type ProAccess = 'allowed' | 'purchaseRequired' | 'verificationRequired' | 'planned' | 'unknown' |
  'versionUnsupported' | 'deviceUnsupported' | 'protocolUnsupported' | 'capabilityUnsupported' |
  'permissionRequired' | 'permissionDenied' | 'serverAuthorizationRequired';
export interface ProAccessContext {
  appVersionCode: number;
  apiVersion: number;
  device: ProDevice;
  protocol: string;
  capabilities: string[];
  grantedPermissions: string[];
  requestablePermissions: string[];
}
export interface ProAccessDecision { visible: boolean; executable: boolean; reason: ProAccess; }
export function proGrantMatches(grant: ProVerifiedGrant, owner: string,
  environment: ProEnvironment, now: number): boolean {
  return owner.length > 0 && grant.owner === owner && grant.environment === environment &&
    typeof grant.productId === 'string' && grant.productId.length > 0 &&
    Array.isArray(grant.entitlementIds) && grant.entitlementIds.every((id: string): boolean =>
      typeof id === 'string' && id.length > 0) && Number.isFinite(now) && Number.isFinite(grant.verifiedAt) &&
    Number.isFinite(grant.revalidateAfter) && Number.isFinite(grant.usableUntil) &&
    grant.verifiedAt >= 0 && grant.verifiedAt <= now && grant.verifiedAt <= grant.revalidateAfter &&
    grant.revalidateAfter < grant.usableUntil;
}
export function proGrantState(grant: ProVerifiedGrant | null, owner: string,
  environment: ProEnvironment, now: number): ProEntitlementState {
  if (grant === null) { return 'free'; }
  if (!proGrantMatches(grant, owner, environment, now) || grant.usableUntil <= now) {
    return 'verificationRequired';
  }
  return grant.entitlementIds.indexOf(PRO_LIFETIME) >= 0 ? 'active' : 'free';
}
function denied(reason: ProAccess): ProAccessDecision {
  return { visible: false, executable: false, reason };
}
// Pure policy: no debug state, UI storage or mutable global protocol here.
export function resolveProFeatureAccess(feature: ProFeature, context: ProAccessContext,
  entitlement: ProEntitlementState, entitlementIds: string[]): ProAccessDecision {
  if (feature.availability !== 'available') { return denied('planned'); }
  if (!Number.isFinite(context.appVersionCode) || !Number.isFinite(context.apiVersion) ||
    context.appVersionCode < feature.minAppVersionCode || context.apiVersion < feature.minApiVersion) {
    return denied('versionUnsupported');
  }
  if (feature.devices.length > 0 && feature.devices.indexOf(context.device) < 0) {
    return denied('deviceUnsupported');
  }
  if (feature.protocols.length > 0 && feature.protocols.indexOf(context.protocol) < 0) {
    return denied('protocolUnsupported');
  }
  if (feature.capabilities.some((capability: string): boolean => context.capabilities.indexOf(capability) < 0)) {
    return denied('capabilityUnsupported');
  }
  if (feature.requiredEntitlementId.length > 0) {
    if (entitlement === 'verificationRequired') { return denied('verificationRequired'); }
    if (entitlement !== 'active' || entitlementIds.indexOf(feature.requiredEntitlementId) < 0) {
      return denied('purchaseRequired');
    }
  }
  const missing = feature.permissions.filter((permission: string): boolean =>
    context.grantedPermissions.indexOf(permission) < 0);
  if (missing.some((permission: string): boolean => context.requestablePermissions.indexOf(permission) < 0)) {
    return { visible: true, executable: false, reason: 'permissionDenied' };
  }
  if (missing.length > 0) { return { visible: true, executable: false, reason: 'permissionRequired' }; }
  // A local decision cannot grant a remotely billed service. Its server must authorize each request.
  if (feature.serverAuthorized) {
    return { visible: true, executable: false, reason: 'serverAuthorizationRequired' };
  }
  return { visible: true, executable: true, reason: 'allowed' };
}
export function proFeatureAccess(id: string, context: ProAccessContext, entitlement: ProEntitlementState,
  entitlementIds: string[]): ProAccessDecision {
  const feature = proFeatures().find((item: ProFeature): boolean => item.id === id);
  return feature ? resolveProFeatureAccess(feature, context, entitlement, entitlementIds) : denied('unknown');
}
