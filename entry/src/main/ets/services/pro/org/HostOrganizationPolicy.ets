/** Pure, protocol-neutral rules for Pro host organization. */
export const HOST_ORGANIZATION_SCHEMA_VERSION: number = 1;
export const MAX_HOST_GROUPS: number = 100;
export const MAX_GROUP_NAME_LENGTH: number = 32;
export const MAX_HOST_TAGS: number = 10;
export const MAX_TAG_LENGTH: number = 32;
/** 「最近」智能分组覆盖的时间窗口。 */
export const HOST_RECENT_WINDOW_MS: number = 7 * 24 * 60 * 60 * 1000;
/** Twelve group colors tuned to read on both light and dark cards. */
export const HOST_GROUP_COLORS: string[] = [
  '#007DFF', '#34C759', '#FF9500', '#FF3B30', '#AF52DE', '#5856D6',
  '#00C7BE', '#FF2D55', '#A2845E', '#30B0C7', '#FFCC00', '#8E8E93'
];
/** Group icons are plain glyphs so they sync as text and render on every device. */
export const HOST_GROUP_ICONS: string[] = [
  '📁', '💼', '🏠', '🏢', '🖥️', '💻', '🧪', '🚀', '⚙️', '🛠️', '🔒', '☁️',
  '🌐', '📡', '🗄️', '🎮', '🎬', '📊', '🧩', '⭐', '🔥', '🌱', '🏷️', '🧭'
];
/** Smart chips shown on the home bar unless the user hides them. */
export const HOST_SMART_FILTER_KINDS: string[] = ['recent', 'online', 'offline', 'unassigned'];

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
  const recentCutoff: number = nowMs - HOST_RECENT_WINDOW_MS;
  return hosts.filter((host: HostOrganizationHostView): boolean => {
    if (kind === 'recent') { return (host.lastConnected || 0) > 0 && (host.lastConnected || 0) >= recentCutoff; }
    if (kind === 'online') { return host.nowOnline === true; }
    if (kind === 'offline') { return host.nowOnline === false; }
    if (kind === 'unassigned') { return (host.groupId || '').trim().length === 0; }
    if (kind === 'protocol') { return host.protocol === value; }
    if (kind === 'subnet') { return subnetMatches(host.host, value); }
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

export type HostFilterKind = 'all' | 'recent' | 'online' | 'offline' | 'unassigned' | 'protocol' | 'subnet' |
  'tag' | 'group';
export interface HostFilter { kind: HostFilterKind; value: string; }
export interface HostTagUsage { tag: string; count: number; }

export function hostFilterKey(filter: HostFilter): string {
  return filter.value.length > 0 ? filter.kind + ':' + filter.value : filter.kind;
}

export function parseHostFilterKey(key: string): HostFilter {
  const separator: number = key.indexOf(':');
  const kind: string = separator < 0 ? key : key.substring(0, separator);
  const value: string = separator < 0 ? '' : key.substring(separator + 1);
  const kinds: string[] = ['all', 'recent', 'online', 'offline', 'unassigned', 'protocol', 'subnet', 'tag', 'group'];
  if (kinds.indexOf(kind) < 0) { return { kind: 'all', value: '' }; }
  const needsValue: boolean = kind === 'protocol' || kind === 'subnet' || kind === 'tag' || kind === 'group';
  if (needsValue && value.length === 0) { return { kind: 'all', value: '' }; }
  return { kind: kind as HostFilterKind, value: needsValue ? value : '' };
}

function ipv4Number(address: string): number {
  const parts: string[] = address.trim().split('.');
  if (parts.length !== 4) { return -1; }
  let value: number = 0;
  for (let index: number = 0; index < 4; index++) {
    if (!/^[0-9]{1,3}$/.test(parts[index])) { return -1; }
    const octet: number = Number(parts[index]);
    if (octet > 255) { return -1; }
    value = value * 256 + octet;
  }
  return value;
}

/** IPv4 CIDR match (`192.168.31.0/24`); anything else falls back to a plain prefix match. */
export function subnetMatches(address: string, subnet: string): boolean {
  const rule: string = subnet.trim();
  if (rule.length === 0) { return false; }
  const slash: number = rule.indexOf('/');
  if (slash > 0) {
    const base: number = ipv4Number(rule.substring(0, slash));
    const bits: number = Number(rule.substring(slash + 1));
    const target: number = ipv4Number(address);
    if (base < 0 || target < 0 || !Number.isInteger(bits) || bits < 0 || bits > 32) { return false; }
    const size: number = Math.pow(2, 32 - bits);
    return Math.floor(base / size) === Math.floor(target / size);
  }
  return address.trim().toLowerCase().startsWith(rule.toLowerCase());
}

export function subnetForAddress(address: string): string {
  const value: number = ipv4Number(address);
  if (value < 0) { return ''; }
  const parts: string[] = address.trim().split('.');
  return parts[0] + '.' + parts[1] + '.' + parts[2] + '.0/24';
}

/** /24 networks that hold at least two hosts, most populated first. */
export function subnetSuggestions(hosts: HostOrganizationHostView[]): string[] {
  const counts: Record<string, number> = {};
  hosts.forEach((host: HostOrganizationHostView): void => {
    const subnet: string = subnetForAddress(host.host);
    if (subnet !== '') { counts[subnet] = (counts[subnet] || 0) + 1; }
  });
  return Object.keys(counts).filter((subnet: string): boolean => counts[subnet] >= 2)
    .sort((left: string, right: string): number => counts[right] - counts[left] || left.localeCompare(right));
}

export function emptyMembership(): HostMembership { return { groupId: '', tags: [], updatedAt: 0 }; }

export function hostMatchesFilter(host: HostOrganizationHostView, membership: HostMembership, filter: HostFilter,
  nowMs: number = Date.now()): boolean {
  if (filter.kind === 'all') { return true; }
  if (filter.kind === 'group') { return membership.groupId === filter.value; }
  if (filter.kind === 'unassigned') { return membership.groupId === ''; }
  if (filter.kind === 'tag') { return membership.tags.indexOf(filter.value) >= 0; }
  if (filter.kind === 'recent') { return (host.lastConnected || 0) > 0 && (host.lastConnected || 0) >= nowMs - HOST_RECENT_WINDOW_MS; }
  if (filter.kind === 'online') { return host.nowOnline === true; }
  if (filter.kind === 'offline') { return host.nowOnline === false; }
  if (filter.kind === 'protocol') { return host.protocol === filter.value; }
  if (filter.kind === 'subnet') { return subnetMatches(host.host, filter.value); }
  return false;
}

function copyMembership(byHost: Record<string, HostMembership>): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = {};
  Object.keys(byHost).forEach((hostRef: string): void => {
    const value: HostMembership = byHost[hostRef];
    result[hostRef] = { groupId: value.groupId, tags: value.tags.slice(), updatedAt: value.updatedAt };
  });
  return result;
}

function compactMembership(byHost: Record<string, HostMembership>): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = {};
  Object.keys(byHost).forEach((hostRef: string): void => {
    const value: HostMembership = byHost[hostRef];
    if (value.groupId !== '' || value.tags.length > 0) { result[hostRef] = value; }
  });
  return result;
}

/** Moves hosts into one group (or out of every group with ''), keeping their tags. */
export function assignGroupIn(byHost: Record<string, HostMembership>, hostRefs: string[], groupId: string,
  nowMs: number): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = copyMembership(byHost);
  hostRefs.forEach((hostRef: string): void => {
    if (hostRefParts(hostRef) === null) { return; }
    const current: HostMembership = result[hostRef] || emptyMembership();
    result[hostRef] = { groupId: groupId, tags: current.tags.slice(), updatedAt: nowMs };
  });
  return compactMembership(result);
}

export function addTagsIn(byHost: Record<string, HostMembership>, hostRefs: string[], tags: string[],
  nowMs: number): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = copyMembership(byHost);
  hostRefs.forEach((hostRef: string): void => {
    if (hostRefParts(hostRef) === null) { return; }
    const current: HostMembership = result[hostRef] || emptyMembership();
    result[hostRef] = { groupId: current.groupId, tags: normalizeTags(current.tags.concat(tags)), updatedAt: nowMs };
  });
  return compactMembership(result);
}

export function removeTagsIn(byHost: Record<string, HostMembership>, hostRefs: string[], tags: string[],
  nowMs: number): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = copyMembership(byHost);
  hostRefs.forEach((hostRef: string): void => {
    const current: HostMembership | undefined = result[hostRef];
    if (current === undefined) { return; }
    result[hostRef] = { groupId: current.groupId,
      tags: current.tags.filter((tag: string): boolean => tags.indexOf(tag) < 0), updatedAt: nowMs };
  });
  return compactMembership(result);
}

/** Renames a tag everywhere; renaming onto an existing tag merges the two. */
export function renameTagIn(byHost: Record<string, HostMembership>, from: string, to: string,
  nowMs: number): Record<string, HostMembership> {
  const target: string = normalizeHostTag(to);
  const result: Record<string, HostMembership> = copyMembership(byHost);
  Object.keys(result).forEach((hostRef: string): void => {
    const current: HostMembership = result[hostRef];
    if (current.tags.indexOf(from) < 0) { return; }
    const tags: string[] = current.tags.map((tag: string): string => tag === from ? target : tag)
      .filter((tag: string): boolean => tag.length > 0);
    result[hostRef] = { groupId: current.groupId, tags: normalizeTags(tags), updatedAt: nowMs };
  });
  return compactMembership(result);
}

export function deleteTagIn(byHost: Record<string, HostMembership>, tag: string,
  nowMs: number): Record<string, HostMembership> {
  return removeTagsIn(byHost, Object.keys(byHost), [tag], nowMs);
}

export function tagUsage(byHost: Record<string, HostMembership>, liveRefs: string[] = []): HostTagUsage[] {
  const counts: Record<string, number> = {};
  Object.keys(byHost).forEach((hostRef: string): void => {
    if (liveRefs.length > 0 && liveRefs.indexOf(hostRef) < 0) { return; }
    byHost[hostRef].tags.forEach((tag: string): void => { counts[tag] = (counts[tag] || 0) + 1; });
  });
  return Object.keys(counts).map((tag: string): HostTagUsage => ({ tag, count: counts[tag] }))
    .sort((left: HostTagUsage, right: HostTagUsage): number => right.count - left.count || left.tag.localeCompare(right.tag));
}

/** Memberships that point at hosts which no longer exist on this account. */
export function danglingRefs(byHost: Record<string, HostMembership>, liveRefs: string[]): string[] {
  return Object.keys(byHost).filter((hostRef: string): boolean => liveRefs.indexOf(hostRef) < 0).sort();
}

export function pruneMembership(byHost: Record<string, HostMembership>,
  liveRefs: string[]): Record<string, HostMembership> {
  const result: Record<string, HostMembership> = {};
  Object.keys(byHost).forEach((hostRef: string): void => {
    if (liveRefs.indexOf(hostRef) >= 0) { result[hostRef] = byHost[hostRef]; }
  });
  return copyMembership(result);
}

export function groupMemberCounts(byHost: Record<string, HostMembership>, liveRefs: string[]): Record<string, number> {
  const counts: Record<string, number> = {};
  liveRefs.forEach((hostRef: string): void => {
    const membership: HostMembership | undefined = byHost[hostRef];
    if (membership !== undefined && membership.groupId !== '') {
      counts[membership.groupId] = (counts[membership.groupId] || 0) + 1;
    }
  });
  return counts;
}

/** Moves one group up (-1) or down (+1) and renumbers every order. */
export function moveGroupIn(groups: HostGroupDefinition[], groupId: string, delta: number,
  nowMs: number): HostGroupDefinition[] {
  const ordered: HostGroupDefinition[] = sortedGroups(groups);
  const index: number = ordered.findIndex((group: HostGroupDefinition): boolean => group.id === groupId);
  const target: number = index + delta;
  if (index < 0 || target < 0 || target >= ordered.length) { return ordered; }
  const moved: HostGroupDefinition = ordered[index];
  ordered.splice(index, 1);
  ordered.splice(target, 0, moved);
  return ordered.map((group: HostGroupDefinition, order: number): HostGroupDefinition => ({
    id: group.id, name: group.name, color: group.color, icon: group.icon, order,
    createdAt: group.createdAt, updatedAt: group.order === order ? group.updatedAt : nowMs
  }));
}

/** Picks a fresh default name (分组 1, 分组 2 …) that no existing group uses. */
export function nextGroupName(groups: HostGroupDefinition[], base: string = '分组'): string {
  for (let index: number = 1; index <= MAX_HOST_GROUPS + 1; index++) {
    const name: string = base + ' ' + index.toString();
    if (!groups.some((group: HostGroupDefinition): boolean => group.name === name)) { return name; }
  }
  return base;
}
