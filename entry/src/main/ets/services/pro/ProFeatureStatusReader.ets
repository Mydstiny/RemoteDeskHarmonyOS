import { DEBUG } from 'BuildProfile';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProFeature } from './ProFeatureCatalog';
import { ProFeatureStatus, proFeatureStatus, proSystemCapability } from './ProFeatureStatus';
import { ProRuntimeSnapshot } from './ProRuntime';

/** Live status with the same device, version, protocol and capability checks as the entry points. */
export function proFeatureCurrentStatus(feature: ProFeature): ProFeatureStatus {
  const app = ProAppRuntime.getInstance();
  const context: ProAccessContext = app.context(feature.protocols.length > 0 ? feature.protocols[0] : '');
  feature.capabilities.forEach((capability: string): void => {
    if (!proSystemCapability(capability) || canIUse(capability)) { context.capabilities.push(capability); }
  });
  context.requestablePermissions = feature.permissions.slice();
  return proFeatureStatus(feature, app.runtime.decision(feature.id, context), DEBUG, app.runtime.snapshot().complimentary);
}

export function proStateText(snapshot: ProRuntimeSnapshot): string {
  if (snapshot.label.length > 0) { return snapshot.label; }
  if (snapshot.effectiveState === 'active') { return 'Pro 已激活'; }
  if (snapshot.effectiveState === 'verificationRequired') { return '需要验证'; }
  if (snapshot.effectiveState === 'revoked') { return '已撤销'; }
  return '未开通';
}
