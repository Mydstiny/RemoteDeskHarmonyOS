import { CloudStore } from '../../CloudStore';
import { HostSyncService } from '../../HostSyncService';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { ProEntries } from '../ProEntries';
import {
  HostGroupDefinition, HostMembership, HostOrganizationSnapshot, HOST_ORGANIZATION_SCHEMA_VERSION,
  emptyOrganization, normalizeOrganizationName, normalizeTags, validateOrganization
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
  listGroups(): HostGroupDefinition[] { return this.groups.slice().sort((a: HostGroupDefinition, b: HostGroupDefinition): number => a.order - b.order); }
  membership(hostRef: string): HostMembership { return this.byHost[hostRef] || { groupId: '', tags: [], updatedAt: 0 }; }
  createGroup(group: HostGroupDefinition): boolean {
    if (!this.canWrite() || this.groups.length >= 100 || this.groups.some((item: HostGroupDefinition): boolean => item.id === group.id)) { return false; }
    const now: number = Date.now();
    const next: HostGroupDefinition = { id: group.id.trim(), name: normalizeOrganizationName(group.name), color: group.color.trim(), icon: group.icon.trim(), order: this.groups.length, createdAt: now, updatedAt: now };
    this.groups = this.groups.concat([next]);
    return this.persist();
  }
  renameGroup(groupId: string, name: string): boolean {
    if (!this.canWrite()) { return false; }
    const nextName: string = normalizeOrganizationName(name);
    if (nextName.length === 0) { return false; }
    const index: number = this.groups.findIndex((group: HostGroupDefinition): boolean => group.id === groupId);
    if (index < 0) { return false; }
    const current: HostGroupDefinition = this.groups[index];
    const next: HostGroupDefinition = { id: current.id, name: nextName, color: current.color, icon: current.icon,
      order: current.order, createdAt: current.createdAt, updatedAt: Date.now() };
    this.groups[index] = next;
    return this.persist();
  }
  deleteGroup(groupId: string): boolean {
    if (!this.canWrite()) { return false; }
    this.groups = this.groups.filter((group: HostGroupDefinition): boolean => group.id !== groupId)
      .map((group: HostGroupDefinition, index: number): HostGroupDefinition => ({ id: group.id, name: group.name,
        color: group.color, icon: group.icon, order: index, createdAt: group.createdAt, updatedAt: Date.now() }));
    Object.keys(this.byHost).forEach((hostRef: string): void => {
      if (this.byHost[hostRef].groupId === groupId) {
        const current: HostMembership = this.byHost[hostRef];
        this.byHost[hostRef] = { groupId: '', tags: current.tags.slice(), updatedAt: Date.now() };
      }
    });
    return this.persist();
  }
  assignHost(hostRef: string, groupId: string, tags: string[] = []): boolean {
    if (!this.canWrite() || hostRef.trim() === '' || (groupId !== '' && !this.groups.some((group: HostGroupDefinition): boolean => group.id === groupId))) { return false; }
    const now: number = Date.now();
    this.byHost[hostRef] = { groupId: groupId.trim(), tags: normalizeTags(tags), updatedAt: now };
    // Keep the legacy RemoteHost.groupId view synchronized for the canonical host table.
    if (!hostRef.includes(':')) { HostSyncService.getInstance().setGroup(hostRef, groupId); }
    return this.persist();
  }
  setTags(hostRef: string, tags: string[]): boolean {
    if (!this.canWrite() || hostRef.trim() === '') { return false; }
    const current: HostMembership = this.membership(hostRef);
    this.byHost[hostRef] = { groupId: current.groupId, tags: normalizeTags(tags), updatedAt: Date.now() };
    return this.persist();
  }
  subscribe(listener: () => void): () => void { this.listeners.push(listener); listener(); return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); }; }
  dispose(): void { this.accountStop(); this.listeners = []; }
  private persist(): boolean {
    const now: number = Date.now(); this.updatedAt = now;
    const groupsPayload: string = JSON.stringify({ schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, groups: this.groups, updatedAt: now });
    const membershipPayload: string = JSON.stringify({ schemaVersion: HOST_ORGANIZATION_SCHEMA_VERSION, byHost: this.byHost, updatedAt: now });
    const ok: boolean = this.persistence.save(HOST_GROUPS_SETTING_KEY, groupsPayload) && this.persistence.save(HOST_MEMBERSHIP_SETTING_KEY, membershipPayload);
    if (ok) { this.publish(); }
    return ok;
  }
  private publish(): void { this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} }); }
}
