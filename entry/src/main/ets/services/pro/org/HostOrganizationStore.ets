import { CloudStore } from '../../CloudStore';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { ProEntries } from '../ProEntries';
import {
  addTagsIn, assignGroupIn, danglingRefs, deleteTagIn, HOST_GROUP_COLORS, HOST_GROUP_ICONS,
  HOST_ORGANIZATION_SCHEMA_VERSION, HostGroupDefinition, HostMembership, HostOrganizationSnapshot, hostRefParts,
  MAX_HOST_GROUPS, moveGroupIn, normalizeOrganizationName, normalizeTags, pruneMembership, removeTagsIn,
  renameTagIn, sortedGroups, validateGroup, validateOrganization
} from './HostOrganizationPolicy';

export const HOST_GROUPS_SETTING_KEY: string = 'pro.org.groups.v1';
export const HOST_MEMBERSHIP_SETTING_KEY: string = 'pro.org.membership.v1';

export interface HostOrganizationPersistence {
  load(key: string): string | null;
  save(key: string, value: string): boolean;
}

class CloudHostOrganizationPersistence implements HostOrganizationPersistence {
  load(key: string): string | null {
    const value = CloudStore.getInstance().loadUserSettings()[key];
    return typeof value === 'string' ? value : null;
  }
  save(key: string, value: string): boolean { return CloudStore.getInstance().upsertUserSetting(key, value); }
}

/** Account-scoped owner of groups/memberships. Store writes fail closed when Pro is unavailable. */
export class HostOrganizationStore {
  private static instance: HostOrganizationStore | null = null;
  private persistence: HostOrganizationPersistence = new CloudHostOrganizationPersistence();
  private groups: HostGroupDefinition[] = [];
  private byHost: Record<string, HostMembership> = {};
  private updatedAt: number = 0;
  private scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
  private loadedOwner: string = '';
  private listeners: Array<() => void> = [];
  private accountStop: () => void;

  private constructor() {
    this.accountStop = AccountSessionCoordinator.getInstance().onChange((scope: AccountScopeToken): void => {
      if (scope.ownerScopeId === this.scope.ownerScopeId && scope.generation === this.scope.generation) { return; }
      this.scope = scope; this.clearMemory(); this.load();
    });
  }
  static getInstance(): HostOrganizationStore {
    if (HostOrganizationStore.instance === null) { HostOrganizationStore.instance = new HostOrganizationStore(); }
    return HostOrganizationStore.instance;
  }
  /** Test/embedding seam; production keeps CloudStore as the only persistence. */
  bindPersistence(persistence: HostOrganizationPersistence): void { this.persistence = persistence; this.clearMemory(); }
  private clearMemory(): void { this.groups = []; this.byHost = {}; this.updatedAt = 0; this.loadedOwner = ''; this.publish(); }
  private canWrite(): boolean { return ProEntries.visible('pro.hostManagement'); }
  private loadRow(key: string): Object | null {
    const raw: string | null = this.persistence.load(key);
    if (raw === null) { return null; }
    try { return JSON.parse(raw) as Object; } catch (_error) { return null; }
  }
  load(): HostOrganizationSnapshot {
    const owner: string = this.scope.ownerScopeId;
    if (this.loadedOwner === owner) { return this.snapshot(); }
    this.groups = []; this.byHost = {}; this.updatedAt = 0; this.loadedOwner = owner;
    const groupsRow: Object | null = this.loadRow(HOST_GROUPS_SETTING_KEY);
    const membershipRow: Object | null = this.loadRow(HOST_MEMBERSHIP_SETTING_KEY);
    if (groupsRow !== null && (groupsRow as Record<string, Object>)['schemaVersion'] === HOST_ORGANIZATION_SCHEMA_VERSION &&
        Array.isArray((groupsRow as Record<string, Object>)['groups'])) {
      this.groups = ((groupsRow as Record<string, Object>)['groups'] as HostGroupDefinition[]).slice();
      this.updatedAt = Number((groupsRow as Record<string, Object>)['updatedAt']) || 0;
    }
    if (membershipRow !== null && (membershipRow as Record<string, Object>)['schemaVersion'] === HOST_ORGANIZATION_SCHEMA_VERSION &&
        typeof (membershipRow as Record<string, Object>)['byHost'] === 'object') {
      this.byHost = ((membershipRow as Record<string, Object>)['byHost'] as Record<string, HostMembership>);
      this.updatedAt = Math.max(this.updatedAt, Number((membershipRow as Record<string, Object>)['updatedAt']) || 0);
    }
    const snapshot: HostOrganizationSnapshot = this.snapshot();
    if (validateOrganization(snapshot).length > 0) { this.groups = []; this.byHost = {}; this.updatedAt = 0; }
    this.publish();
    return this.snapshot();
  }
  snapshot(): HostOrganizationSnapshot {
    const membership: Record<string, HostMembership> = {};
    Object.keys(this.byHost).forEach((hostRef: string): void => {
      const value: HostMembership = this.byHost[hostRef];
      membership[hostRef] = { groupId: value.groupId, tags: value.tags.slice(), updatedAt: value.updatedAt };
    });
    return { schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, groups: this.groups.slice(), byHost: membership, updatedAt: this.updatedAt };
  }
  listGroups(): HostGroupDefinition[] { return sortedGroups(this.groups); }
  group(groupId: string): HostGroupDefinition | null {
    return this.groups.find((group: HostGroupDefinition): boolean => group.id === groupId) || null;
  }
  membership(hostRef: string): HostMembership { return this.byHost[hostRef] || { groupId: '', tags: [], updatedAt: 0 }; }
  /** Forces a re-read, used after cloud sync may have replaced the rows. */
  reload(): HostOrganizationSnapshot { this.loadedOwner = ''; return this.load(); }
  createGroup(group: HostGroupDefinition): boolean {
    const name: string = normalizeOrganizationName(group.name);
    if (!this.canWrite() || name.length === 0 || this.groups.length >= MAX_HOST_GROUPS ||
        this.groups.some((item: HostGroupDefinition): boolean => item.id === group.id)) { return false; }
    const now: number = Date.now();
    const next: HostGroupDefinition = { id: group.id.trim(), name, color: group.color.trim(), icon: group.icon.trim(),
      order: this.groups.length, createdAt: now, updatedAt: now };
    if (validateGroup(next).length > 0) { return false; }
    return this.commit(this.groups.concat([next]), this.byHost);
  }
  /** Updates name, color and icon together; empty values keep the current ones. */
  updateGroup(groupId: string, name: string, color: string, icon: string): boolean {
    if (!this.canWrite()) { return false; }
    const index: number = this.groups.findIndex((group: HostGroupDefinition): boolean => group.id === groupId);
    if (index < 0) { return false; }
    const current: HostGroupDefinition = this.groups[index];
    const nextName: string = normalizeOrganizationName(name);
    const next: HostGroupDefinition = { id: current.id, name: nextName.length > 0 ? nextName : current.name,
      color: color.trim().length > 0 ? color.trim() : current.color,
      icon: icon.trim().length > 0 ? icon.trim() : current.icon,
      order: current.order, createdAt: current.createdAt, updatedAt: Date.now() };
    if (validateGroup(next).length > 0) { return false; }
    const groups: HostGroupDefinition[] = this.groups.slice();
    groups[index] = next;
    return this.commit(groups, this.byHost);
  }
  renameGroup(groupId: string, name: string): boolean { return this.updateGroup(groupId, name, '', ''); }
  moveGroup(groupId: string, delta: number): boolean {
    if (!this.canWrite()) { return false; }
    return this.commit(moveGroupIn(this.groups, groupId, delta, Date.now()), this.byHost);
  }
  /** Deletes the group only; its hosts stay and become ungrouped. */
  deleteGroup(groupId: string): boolean {
    if (!this.canWrite()) { return false; }
    const now: number = Date.now();
    const groups: HostGroupDefinition[] = sortedGroups(this.groups.filter((group: HostGroupDefinition): boolean =>
      group.id !== groupId)).map((group: HostGroupDefinition, index: number): HostGroupDefinition => ({
        id: group.id, name: group.name, color: group.color, icon: group.icon, order: index,
        createdAt: group.createdAt, updatedAt: group.order === index ? group.updatedAt : now }));
    const members: string[] = Object.keys(this.byHost).filter((hostRef: string): boolean =>
      this.byHost[hostRef].groupId === groupId);
    return this.commit(groups, assignGroupIn(this.byHost, members, '', now));
  }
  assignHost(hostRef: string, groupId: string): boolean { return this.assignHosts([hostRef], groupId); }
  /** Moves hosts into a group ('' removes them from every group); tags are kept. */
  assignHosts(hostRefs: string[], groupId: string): boolean {
    if (!this.canWrite() || hostRefs.length === 0 ||
        (groupId !== '' && this.group(groupId) === null)) { return false; }
    return this.commit(this.groups, assignGroupIn(this.byHost, hostRefs, groupId, Date.now()));
  }
  setTags(hostRef: string, tags: string[]): boolean {
    if (!this.canWrite() || hostRefParts(hostRef) === null) { return false; }
    const current: string[] = this.membership(hostRef).tags;
    const now: number = Date.now();
    return this.commit(this.groups, addTagsIn(removeTagsIn(this.byHost, [hostRef], current, now), [hostRef], tags, now));
  }
  addTags(hostRefs: string[], tags: string[]): boolean {
    if (!this.canWrite() || hostRefs.length === 0 || normalizeTags(tags).length === 0) { return false; }
    return this.commit(this.groups, addTagsIn(this.byHost, hostRefs, tags, Date.now()));
  }
  removeTags(hostRefs: string[], tags: string[]): boolean {
    if (!this.canWrite() || hostRefs.length === 0) { return false; }
    return this.commit(this.groups, removeTagsIn(this.byHost, hostRefs, tags, Date.now()));
  }
  renameTag(from: string, to: string): boolean {
    if (!this.canWrite() || normalizeTags([to]).length === 0) { return false; }
    return this.commit(this.groups, renameTagIn(this.byHost, from, to, Date.now()));
  }
  deleteTag(tag: string): boolean {
    if (!this.canWrite()) { return false; }
    return this.commit(this.groups, deleteTagIn(this.byHost, tag, Date.now()));
  }
  /** Drops memberships of hosts that were deleted; returns how many were removed. */
  pruneDangling(liveRefs: string[]): number {
    const dangling: string[] = danglingRefs(this.byHost, liveRefs);
    if (!this.canWrite() || dangling.length === 0) { return 0; }
    return this.commit(this.groups, pruneMembership(this.byHost, liveRefs)) ? dangling.length : 0;
  }
  /** Adds imported groups (by name) and memberships; existing groups with the same name are reused. */
  importOrganization(groups: HostGroupDefinition[], assignments: Record<string, HostMembership>): boolean {
    if (!this.canWrite()) { return false; }
    const now: number = Date.now();
    let nextGroups: HostGroupDefinition[] = sortedGroups(this.groups);
    const idMap: Record<string, string> = {};
    groups.forEach((group: HostGroupDefinition, index: number): void => {
      const name: string = normalizeOrganizationName(group.name || '');
      if (name.length === 0) { return; }
      const existing: HostGroupDefinition | undefined =
        nextGroups.find((item: HostGroupDefinition): boolean => item.name === name);
      if (existing !== undefined) { idMap[group.id] = existing.id; return; }
      if (nextGroups.length >= MAX_HOST_GROUPS) { return; }
      const created: HostGroupDefinition = { id: 'group-' + now.toString(36) + '-' + index.toString(36), name,
        color: typeof group.color === 'string' && group.color.length > 0 ? group.color : HOST_GROUP_COLORS[0],
        icon: typeof group.icon === 'string' && group.icon.length > 0 ? group.icon : HOST_GROUP_ICONS[0],
        order: nextGroups.length, createdAt: now, updatedAt: now };
      if (validateGroup(created).length > 0) { return; }
      idMap[group.id] = created.id;
      nextGroups = nextGroups.concat([created]);
    });
    let membership: Record<string, HostMembership> = this.byHost;
    Object.keys(assignments).forEach((hostRef: string): void => {
      const value: HostMembership = assignments[hostRef];
      const groupId: string = idMap[value.groupId] || '';
      if (groupId !== '') { membership = assignGroupIn(membership, [hostRef], groupId, now); }
      if (value.tags.length > 0) { membership = addTagsIn(membership, [hostRef], value.tags, now); }
    });
    return this.commit(nextGroups, membership);
  }
  subscribe(listener: () => void): () => void { this.listeners.push(listener); listener(); return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); }; }
  dispose(): void { this.accountStop(); this.listeners = []; }
  /** Validates and writes both rows; memory only changes when the write succeeds. */
  private commit(groups: HostGroupDefinition[], byHost: Record<string, HostMembership>): boolean {
    const now: number = Date.now();
    const candidate: HostOrganizationSnapshot = { schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, groups,
      byHost, updatedAt: now };
    if (validateOrganization(candidate).length > 0) { return false; }
    const groupsPayload: string = JSON.stringify({ schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, groups, updatedAt: now });
    const membershipPayload: string = JSON.stringify({ schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, byHost, updatedAt: now });
    const ok: boolean = this.persistence.save(HOST_GROUPS_SETTING_KEY, groupsPayload) &&
      this.persistence.save(HOST_MEMBERSHIP_SETTING_KEY, membershipPayload);
    if (!ok) { return false; }
    this.groups = groups.slice(); this.byHost = byHost; this.updatedAt = now;
    this.publish();
    return true;
  }
  private publish(): void { this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} }); }
}
