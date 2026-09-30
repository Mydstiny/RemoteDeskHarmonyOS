import { CloudStore } from '../../CloudStore';
import { AccountScopeToken } from '../../AccountScopePolicy';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { ProEntries } from '../ProEntries';
import { MAX_WORKSPACES, WORKSPACE_SCHEMA_VERSION, Workspace, validateWorkspace } from './WorkspacePolicy';

export interface WorkspacePersistence { load(key: string): string | null; save(key: string, value: string): boolean; }
class CloudWorkspacePersistence implements WorkspacePersistence {
  load(key: string): string | null { const value = CloudStore.getInstance().loadUserSettings()[key]; return typeof value === 'string' ? value : null; }
  save(key: string, value: string): boolean { return CloudStore.getInstance().upsertUserSetting(key, value); }
}

/** Account-scoped workspace CRUD. A revoked Pro account keeps rows but becomes read-only. */
export class WorkspaceStore {
  private static instance: WorkspaceStore | null = null;
  private persistence: WorkspacePersistence = new CloudWorkspacePersistence();
  private items: Workspace[] = [];
  private scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
  private loadedOwner: string = '';
  private listeners: Array<() => void> = [];
  private accountStop: () => void;
  private constructor() {
    this.accountStop = AccountSessionCoordinator.getInstance().onChange((scope: AccountScopeToken): void => {
      if (scope.ownerScopeId === this.scope.ownerScopeId && scope.generation === this.scope.generation) { return; }
      this.scope = scope; this.items = []; this.loadedOwner = ''; this.publish(); this.load();
    });
  }
  static getInstance(): WorkspaceStore { if (WorkspaceStore.instance === null) { WorkspaceStore.instance = new WorkspaceStore(); } return WorkspaceStore.instance; }
  bindPersistence(persistence: WorkspacePersistence): void { this.persistence = persistence; this.items = []; this.loadedOwner = ''; }
  load(): Workspace[] {
    if (this.loadedOwner === this.scope.ownerScopeId) { return this.list(); }
    this.items = []; this.loadedOwner = this.scope.ownerScopeId;
    const settings: Record<string, string | number | boolean> = CloudStore.getInstance().loadUserSettings();
    Object.keys(settings).filter((key: string): boolean => key.indexOf('pro.ws.') === 0).forEach((key: string): void => {
      const raw: string | number | boolean = settings[key];
      if (typeof raw !== 'string') { return; }
      try {
        const workspace: Workspace = JSON.parse(raw) as Workspace;
        if (validateWorkspace(workspace).length === 0) { this.items.push(workspace); }
      } catch (_error) {}
    });
    this.items.sort((a: Workspace, b: Workspace): number => a.order - b.order);
    this.publish(); return this.list();
  }
  list(): Workspace[] { return this.items.slice().sort((a: Workspace, b: Workspace): number => a.order - b.order); }
  get(id: string): Workspace | null { return this.items.find((item: Workspace): boolean => item.id === id) || null; }
  save(workspace: Workspace): boolean {
    if (!ProEntries.visible('pro.workspaces') || validateWorkspace(workspace).length > 0) { return false; }
    if (this.get(workspace.id) === null && this.items.length >= MAX_WORKSPACES) { return false; }
    const next: Workspace = { schemaVersion: workspace.schemaVersion, id: workspace.id, name: workspace.name,
      color: workspace.color, icon: workspace.icon, order: workspace.order, entries: workspace.entries.slice(),
      layout: workspace.layout, updatedAt: Date.now() };
    const previous: Workspace[] = this.items.slice();
    this.items = this.items.filter((item: Workspace): boolean => item.id !== next.id).concat([next]);
    const ok: boolean = this.persistence.save('pro.ws.' + next.id, JSON.stringify(next));
    if (!ok) { this.items = previous; return false; }
    this.publish(); return true;
  }
  remove(id: string): boolean {
    if (!ProEntries.visible('pro.workspaces')) { return false; }
    const previous: Workspace[] = this.items.slice(); this.items = this.items.filter((item: Workspace): boolean => item.id !== id);
    // A tombstone keeps deletion deterministic across devices without adding a new table.
    const tombstone: string = JSON.stringify({ schemaVersion: WORKSPACE_SCHEMA_VERSION, id, deleted: true, updatedAt: Date.now() });
    if (!this.persistence.save('pro.ws.' + id, tombstone)) { this.items = previous; return false; }
    this.publish(); return true;
  }
  subscribe(listener: () => void): () => void { this.listeners.push(listener); listener(); return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); }; }
  dispose(): void { this.accountStop(); this.listeners = []; }
  private publish(): void { this.listeners.slice().forEach((listener: () => void): void => { try { listener(); } catch (_error) {} }); }
}
