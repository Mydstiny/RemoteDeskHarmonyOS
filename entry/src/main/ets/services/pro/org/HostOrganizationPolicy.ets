/** Pure, protocol-neutral rules for Pro host organization. */
export const HOST_ORGANIZATION_SCHEMA_VERSION: number = 1;
export const MAX_HOST_GROUPS: number = 100;
export const MAX_GROUP_NAME_LENGTH: number = 32;
export const MAX_HOST_TAGS: number = 10;
export const MAX_TAG_LENGTH: number = 32;

export type HostOrganizationProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight' | 'ai' | string;
export type HostSmartGroup = 'recent' | 'online' | 'offline' | 'unassigned' | 'protocol' | 'subnet' | 'tag';

export interface HostGroupDefinition {
  id: string;
  name: string;
  color: string;
  icon: string;
  order: number;
  createdAt: number;
  updatedAt: number;
}

export interface HostMembership {
  groupId: string;
  tags: string[];
  updatedAt: number;
}

export interface HostOrganizationSnapshot {
  schemaVersion: number;
  groups: HostGroupDefinition[];
  byHost: Record<string, HostMembership>;
  updatedAt: number;
}

export interface HostOrganizationHostView {
  id: string;
  protocol: HostOrganizationProtocol;
  host: string;
  port: number;
  username: string;
  label: string;
  groupId?: string;
  tags?: string[];
  lastConnected?: number;
  lastHealth?: number;
  nowOnline?: boolean;
}

export interface HostDuplicateGroup {
  key: string;
  hostIds: string[];
}
export interface HostRefParts { protocol: string; id: string; }

function finiteInteger(value: number, min: number, max: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= min && value <= max;
}

function safeText(value: string, max: number, allowEmpty: boolean = false): boolean {
  return typeof value === 'string' && value.length <= max &&
    (allowEmpty || value.trim().length > 0) &&
    !/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(value);
}

export function normalizeOrganizationId(value: string): string {
  return value.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64);
}

export function normalizeOrganizationName(value: string): string {
  return value.trim().replace(/\s+/g, ' ').slice(0, MAX_GROUP_NAME_LENGTH);
}

export function normalizeHostTag(value: string): string {
  return value.trim().replace(/\s+/g, ' ').slice(0, MAX_TAG_LENGTH);
}

/** One stable reference format is shared by all Pro host features. */
export function hostRefForProtocol(protocol: string, id: string): string {
  const normalizedId: string = id.trim();
  if (normalizedId.length === 0) { return ''; }
  if (protocol === 'vnc' || protocol === 'moonlight' || protocol === 'ai') {
    return protocol + ':' + normalizedId;
  }
  return normalizedId;
}

export function hostRefParts(hostRef: string): HostRefParts | null {
  const value: string = hostRef.trim();
  if (value.length === 0) { return null; }
  const separator: number = value.indexOf(':');
  if (separator <= 0) { return { protocol: 'remote', id: value }; }
  const protocol: string = value.substring(0, separator);
  const id: string = value.substring(separator + 1);
  return id.length === 0 ? null : { protocol, id };
}

export function normalizeTags(tags: string[]): string[] {
  const result: string[] = [];
  if (!Array.isArray(tags)) { return result; }
  tags.forEach((raw: string): void => {
    if (!safeText(raw, MAX_TAG_LENGTH)) { return; }
    const tag: string = normalizeHostTag(raw);
    if (tag.length > 0 && result.indexOf(tag) < 0 && result.length < MAX_HOST_TAGS) { result.push(tag); }
  });
  return result;
}

export function validateGroup(group: HostGroupDefinition): string[] {
  const errors: string[] = [];
  if (!safeText(group.id, 64)) { errors.push('invalid_group_id'); }
  if (!safeText(group.name, MAX_GROUP_NAME_LENGTH)) { errors.push('invalid_group_name'); }
  if (!safeText(group.color, 32)) { errors.push('invalid_group_color'); }
  if (!safeText(group.icon, 64)) { errors.push('invalid_group_icon'); }
  if (!finiteInteger(group.order, 0, MAX_HOST_GROUPS - 1)) { errors.push('invalid_group_order'); }
  if (!finiteInteger(group.createdAt, 0, Number.MAX_SAFE_INTEGER) ||
      !finiteInteger(group.updatedAt, 0, Number.MAX_SAFE_INTEGER)) { errors.push('invalid_group_time'); }
  return errors;
}

export function validateOrganization(snapshot: HostOrganizationSnapshot): string[] {
  const errors: string[] = [];
  if (snapshot.schemaVersion !== HOST_ORGANIZATION_SCHEMA_VERSION) { errors.push('unsupported_schema'); }
  if (!Array.isArray(snapshot.groups) || snapshot.groups.length > MAX_HOST_GROUPS) { errors.push('group_limit'); }
  const ids: string[] = [];
  (snapshot.groups || []).forEach((group: HostGroupDefinition): void => {
    validateGroup(group).forEach((error: string): void => { if (errors.indexOf(error) < 0) { errors.push(error); } });
    if (ids.indexOf(group.id) >= 0) { errors.push('duplicate_group_id'); }
    ids.push(group.id);
  });
  if (typeof snapshot.byHost !== 'object' || snapshot.byHost === null || Array.isArray(snapshot.byHost)) {
    errors.push('invalid_membership');
  } else {
    Object.keys(snapshot.byHost).forEach((hostRef: string): void => {
      const membership: HostMembership = snapshot.byHost[hostRef];
      if (!hostRefParts(hostRef) || !membership || typeof membership.groupId !== 'string' ||
          membership.groupId.length > 64 || !Array.isArray(membership.tags) ||
          membership.tags.length > MAX_HOST_TAGS || membership.tags.some((tag: string): boolean =>
            !safeText(tag, MAX_TAG_LENGTH))) { errors.push('invalid_membership_entry'); }
    });
  }
  if (!finiteInteger(snapshot.updatedAt, 0, Number.MAX_SAFE_INTEGER)) { errors.push('invalid_updated_at'); }
  return Array.from(new Set<string>(errors));
}

export function emptyOrganization(nowMs: number = Date.now()): HostOrganizationSnapshot {
  return { schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, groups: [], byHost: {}, updatedAt: nowMs };
}

export function sortedGroups(groups: HostGroupDefinition[]): HostGroupDefinition[] {
  return groups.slice().sort((left: HostGroupDefinition, right: HostGroupDefinition): number =>
    left.order - right.order || left.name.localeCompare(right.name) || left.id.localeCompare(right.id));
}

export function sortedHosts(hosts: HostOrganizationHostView[], mode: 'manual' | 'name' | 'recent' | 'online' = 'manual'):
  HostOrganizationHostView[] {
  return hosts.slice().sort((left: HostOrganizationHostView, right: HostOrganizationHostView): number => {
    if (mode === 'name') { return left.label.localeCompare(right.label) || left.id.localeCompare(right.id); }
    if (mode === 'recent') { return (right.lastConnected || 0) - (left.lastConnected || 0) || left.label.localeCompare(right.label); }
    if (mode === 'online') { return Number(right.nowOnline === true) - Number(left.nowOnline === true) || left.label.localeCompare(right.label); }
    return left.id.localeCompare(right.id);
  });
}

export function smartGroup(hosts: HostOrganizationHostView[], kind: HostSmartGroup, value: string = '', nowMs: number = Date.now()): string[] {
  const recentCutoff: number = nowMs - 15 * 60 * 1000;
  return hosts.filter((host: HostOrganizationHostView): boolean => {
    if (kind === 'recent') { return (host.lastConnected || 0) >= recentCutoff; }
    if (kind === 'online') { return host.nowOnline === true; }
    if (kind === 'offline') { return host.nowOnline === false; }
    if (kind === 'unassigned') { return (host.groupId || '').trim().length === 0; }
    if (kind === 'protocol') { return host.protocol === value; }
    if (kind === 'subnet') { return host.host.trim().startsWith(value.trim()); }
    if (kind === 'tag') { return (host.tags || []).indexOf(value) >= 0; }
    return false;
  }).map((host: HostOrganizationHostView): string => host.id);
}

export function duplicateHostGroups(hosts: HostOrganizationHostView[]): HostDuplicateGroup[] {
  const buckets: Record<string, string[]> = {};
  hosts.forEach((host: HostOrganizationHostView): void => {
    const key: string = [host.protocol, host.host.trim().toLowerCase(), host.port.toString(), host.username.trim().toLowerCase()].join('|');
    if (!buckets[key]) { buckets[key] = []; }
    buckets[key].push(host.id);
  });
  return Object.keys(buckets).filter((key: string): boolean => buckets[key].length > 1)
    .map((key: string): HostDuplicateGroup => ({ key, hostIds: buckets[key].slice() }));
}
