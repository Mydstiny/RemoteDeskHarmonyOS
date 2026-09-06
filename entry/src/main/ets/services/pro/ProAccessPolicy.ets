export type ProEnvironment = 'sandbox' | 'production';
export type ProAvailability = 'available' | 'planned';
export interface ProFeature {
  id: string;
  title: string;
  description: string;
  requiresPro: boolean;
  availability: ProAvailability;
}
export function proFeatures(): ProFeature[] {
  return [
    { id: 'core.connection', title: '完整的远程连接', description: '全部协议、正常画质与核心操作继续免费。', requiresPro: false, availability: 'available' },
    { id: 'pro.workspaces', title: '工作区与布局', description: '保存常用会话组合，让每次开工更从容。', requiresPro: true, availability: 'planned' },
    { id: 'pro.hostManagement', title: '高级主机管理', description: '智能分组与批量配置，减少重复操作。', requiresPro: true, availability: 'planned' },
    { id: 'pro.personalization', title: '个性化方案', description: '更多主题、工具栏与操作方案。', requiresPro: true, availability: 'planned' }
  ];
}
// A grant is accepted only from an injected trusted verifier, never from UI/IAP JSON.
export interface ProVerifiedGrant {
  owner: string;
  environment: ProEnvironment;
  productId: string;
  active: boolean;
  validUntil: number;
  featureIds: string[];
}
export type ProAccess = 'allowed' | 'purchaseRequired' | 'planned' | 'unknown';
export function proFeatureAccess(id: string, grant: ProVerifiedGrant | null,
  owner: string, environment: ProEnvironment, now: number): ProAccess {
  const feature = proFeatures().find((item: ProFeature): boolean => item.id === id);
  if (!feature) { return 'unknown'; }
  return resolveProFeatureAccess(feature, grant, owner, environment, now);
}
export function resolveProFeatureAccess(feature: ProFeature, grant: ProVerifiedGrant | null,
  owner: string, environment: ProEnvironment, now: number): ProAccess {
  if (feature.availability !== 'available') { return 'planned'; }
  if (!feature.requiresPro) { return 'allowed'; }
  if (grant === null || owner.length === 0 || grant.owner !== owner || grant.environment !== environment ||
    !grant.active || !Number.isFinite(grant.validUntil) || grant.validUntil <= now ||
    !Number.isFinite(now) || grant.featureIds.indexOf(feature.id) < 0) { return 'purchaseRequired'; }
  return 'allowed';
}
