import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rdbInsertSucceeded, rdbSingleRowAffected } from '../../CloudStoreMutationPolicy';
import { sshDiagnosticErrorCode } from '../observability/SshDiagnosticPolicy';
import {
  cloneSshWorkspaceSnapshot,
  decodeSshWorkspaceSnapshots,
  encodeSshWorkspaceSnapshots,
  SSH_WORKSPACE_SCHEMA_VERSION,
  SshWorkspaceDecodeResult,
  SshWorkspaceSnapshotV1,
  validateSshWorkspaceSnapshot
} from './SshWorkspacePolicy';

export const SSH_WORKSPACE_DATABASE_NAME: string = 'remotedesktop_ssh_workspace.db';
export const SSH_WORKSPACE_DATABASE_VERSION: number = 1;
export const SSH_WORKSPACE_TABLE: string = 'sshworkspaces';

export interface SshWorkspaceStoredRow {
  workspaceId: string;
  schemaVersion: number;
  revision: number;
  payload: string;
  active: boolean;
  createdAt: number;
  updatedAt: number;
}

export interface SshWorkspaceStoredRowsResult {
  ok: boolean;
  rows: Array<SshWorkspaceStoredRow>;
}

/**
 * Narrow persistence port used by the repository and its fault-injection
 * tests. Native sessions, channels, output and credentials are deliberately
 * absent from this boundary.
 */
export interface SshWorkspacePersistencePort {
  readRows(): SshWorkspaceStoredRowsResult;
  replace(row: SshWorkspaceStoredRow, expectedRevision: number): boolean;
  remove(workspaceId: string, expectedRevision: number): boolean;
}

export interface SshWorkspaceRestoreResult {
  readable: boolean;
  snapshots: Array<SshWorkspaceSnapshotV1>;
  activeWorkspaceId: string;
  rejected: number;
  unsupported: number;
}

export type SshWorkspaceSaveCode =
  | 'saved'
  | 'invalid_snapshot'
  | 'stale_revision'
  | 'write_failed';

export interface SshWorkspaceSaveResult {
  ok: boolean;
  code: SshWorkspaceSaveCode;
  durableRevision: number;
}

function cloneRow(row: SshWorkspaceStoredRow): SshWorkspaceStoredRow {
  return {
    workspaceId: row.workspaceId,
    schemaVersion: row.schemaVersion,
    revision: row.revision,
    payload: row.payload,
    active: row.active,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt
  };
}

/**
 * Validates and isolates rows one at a time. A corrupt or future row cannot
 * erase otherwise valid workspaces, and no restore path can auto-connect.
 */
export class SshWorkspaceRepository {
  private port: SshWorkspacePersistencePort;
  private durableRevisions: Map<string, number> = new Map<string, number>();
  private durablePayloads: Map<string, string> = new Map<string, string>();

  constructor(port: SshWorkspacePersistencePort) { this.port = port; }

  restore(): SshWorkspaceRestoreResult {
    const readResult: SshWorkspaceStoredRowsResult = this.port.readRows();
    if (!readResult.ok) {
      this.durableRevisions.clear();
      this.durablePayloads.clear();
      return {
        readable: false, snapshots: [], activeWorkspaceId: '', rejected: 0, unsupported: 0
      };
    }
    const rows: Array<SshWorkspaceStoredRow> = readResult.rows;
    const snapshots: Array<SshWorkspaceSnapshotV1> = [];
    const workspaceIds: Set<string> = new Set<string>();
    let rejected: number = 0;
    let unsupported: number = 0;
    let activeWorkspaceId: string = '';
    let activeUpdatedAt: number = -1;
    this.durableRevisions.clear();
    this.durablePayloads.clear();
    for (let index: number = 0; index < rows.length; index++) {
      const row: SshWorkspaceStoredRow = rows[index];
      if (row.schemaVersion > SSH_WORKSPACE_SCHEMA_VERSION) {
        unsupported++;
        continue;
      }
      if (row.schemaVersion !== SSH_WORKSPACE_SCHEMA_VERSION ||
        row.payload.length === 0 || workspaceIds.has(row.workspaceId)) {
        rejected++;
        continue;
      }
      const decoded: SshWorkspaceDecodeResult = decodeSshWorkspaceSnapshots(row.payload);
      if (decoded.snapshots.length !== 1 || decoded.rejected !== 0 || decoded.unsupported !== 0) {
        rejected++;
        continue;
      }
      const snapshot: SshWorkspaceSnapshotV1 = decoded.snapshots[0];
      if (snapshot.workspaceId !== row.workspaceId || snapshot.schemaVersion !== row.schemaVersion ||
        snapshot.revision !== row.revision || snapshot.createdAt !== row.createdAt ||
        snapshot.updatedAt !== row.updatedAt) {
        rejected++;
        continue;
      }
      workspaceIds.add(snapshot.workspaceId);
      snapshots.push(cloneSshWorkspaceSnapshot(snapshot));
      this.durableRevisions.set(snapshot.workspaceId, snapshot.revision);
      this.durablePayloads.set(snapshot.workspaceId,
        encodeSshWorkspaceSnapshots([snapshot]));
      if (row.active && (activeWorkspaceId.length === 0 || row.updatedAt > activeUpdatedAt)) {
        activeWorkspaceId = row.workspaceId;
        activeUpdatedAt = row.updatedAt;
      }
    }
    if (activeWorkspaceId.length === 0 && snapshots.length > 0) {
      let latestIndex: number = 0;
      for (let index: number = 1; index < snapshots.length; index++) {
        if (snapshots[index].updatedAt > snapshots[latestIndex].updatedAt) { latestIndex = index; }
      }
      activeWorkspaceId = snapshots[latestIndex].workspaceId;
    }
    return { readable: true, snapshots, activeWorkspaceId, rejected, unsupported };
  }

  save(snapshot: SshWorkspaceSnapshotV1, active: boolean): SshWorkspaceSaveResult {
    if (validateSshWorkspaceSnapshot(snapshot).length > 0) {
      return { ok: false, code: 'invalid_snapshot', durableRevision: -1 };
    }
    const encoded: string = encodeSshWorkspaceSnapshots([snapshot]);
    const readback: SshWorkspaceDecodeResult = decodeSshWorkspaceSnapshots(encoded);
    if (readback.snapshots.length !== 1 || readback.rejected !== 0 ||
      readback.unsupported !== 0) {
      return { ok: false, code: 'invalid_snapshot', durableRevision: -1 };
    }
    const durable: number | undefined = this.durableRevisions.get(snapshot.workspaceId);
    const expectedRevision: number = durable === undefined ? -1 : durable;
    if (expectedRevision >= snapshot.revision) {
      if (expectedRevision === snapshot.revision) {
        const durablePayload: string | undefined =
          this.durablePayloads.get(snapshot.workspaceId);
        if (durablePayload === encoded) {
          return { ok: true, code: 'saved', durableRevision: expectedRevision };
        }
      }
      return { ok: false, code: 'stale_revision', durableRevision: expectedRevision };
    }
    const row: SshWorkspaceStoredRow = {
      workspaceId: snapshot.workspaceId,
      schemaVersion: snapshot.schemaVersion,
      revision: snapshot.revision,
      payload: encoded,
      active,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt
    };
    if (!this.port.replace(cloneRow(row), expectedRevision)) {
      return { ok: false, code: 'write_failed', durableRevision: expectedRevision };
    }
    this.durableRevisions.set(snapshot.workspaceId, snapshot.revision);
    this.durablePayloads.set(snapshot.workspaceId, encoded);
    return { ok: true, code: 'saved', durableRevision: snapshot.revision };
  }

  remove(workspaceId: string): boolean {
    const id: string = workspaceId.trim();
    const durable: number | undefined = this.durableRevisions.get(id);
    if (id.length === 0 || durable === undefined || !this.port.remove(id, durable)) { return false; }
    this.durableRevisions.delete(id);
    this.durablePayloads.delete(id);
    return true;
  }

  durableRevision(workspaceId: string): number {
    return this.durableRevisions.get(workspaceId.trim()) ?? -1;
  }
}

/** Local-only RDB adapter. It never registers a distributed/cloud table. */
export class HarmonySshWorkspacePersistenceAdapter implements SshWorkspacePersistencePort {
  private store: relationalStore.RdbStore | null = null;
  private initialized: boolean = false;
  private initPromise: Promise<boolean> | null = null;

  async init(context: common.Context): Promise<boolean> {
    if (this.initialized && this.store !== null) { return true; }
    if (this.initPromise !== null) { return await this.initPromise; }
    this.initPromise = this.open(context);
    try {
      return await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private async open(context: common.Context): Promise<boolean> {
    try {
      const config: relationalStore.StoreConfig = {
        name: SSH_WORKSPACE_DATABASE_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      if (store.version > SSH_WORKSPACE_DATABASE_VERSION) {
        try { await store.close(); } catch (_closeError) {}
        return false;
      }
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS ' + SSH_WORKSPACE_TABLE + ' (' +
        'workspaceid TEXT PRIMARY KEY, schemaversion INTEGER NOT NULL, ' +
        'revision INTEGER NOT NULL, payload TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 0, ' +
        'createdat INTEGER NOT NULL, updatedat INTEGER NOT NULL)');
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_sshworkspaces_active_updated ' +
        'ON ' + SSH_WORKSPACE_TABLE + ' (active, updatedat)');
      store.version = SSH_WORKSPACE_DATABASE_VERSION;
      this.store = store;
      this.initialized = true;
      return true;
    } catch (err) {
      hilog.error(0x0017, 'SshWorkspaceStore', 'workspace RDB init failed code=' +
        sshDiagnosticErrorCode(err));
      this.store = null;
      this.initialized = false;
      return false;
    }
  }

  isReady(): boolean {
    return this.initialized && this.store !== null;
  }

  readRows(): SshWorkspaceStoredRowsResult {
    const result: Array<SshWorkspaceStoredRow> = [];
    if (this.store === null) { return { ok: false, rows: result }; }
    let rows: relationalStore.ResultSet | null = null;
    try {
      rows = this.store.querySync(new relationalStore.RdbPredicates(SSH_WORKSPACE_TABLE));
      const workspaceIdIndex: number = rows.getColumnIndex('workspaceid');
      const schemaVersionIndex: number = rows.getColumnIndex('schemaversion');
      const revisionIndex: number = rows.getColumnIndex('revision');
      const payloadIndex: number = rows.getColumnIndex('payload');
      const activeIndex: number = rows.getColumnIndex('active');
      const createdAtIndex: number = rows.getColumnIndex('createdat');
      const updatedAtIndex: number = rows.getColumnIndex('updatedat');
      while (rows.goToNextRow()) {
        result.push({
          workspaceId: rows.getString(workspaceIdIndex),
          schemaVersion: rows.getLong(schemaVersionIndex),
          revision: rows.getLong(revisionIndex),
          payload: rows.getString(payloadIndex),
          active: rows.getLong(activeIndex) === 1,
          createdAt: rows.getLong(createdAtIndex),
          updatedAt: rows.getLong(updatedAtIndex)
        });
      }
    } catch (err) {
      hilog.error(0x0017, 'SshWorkspaceStore', 'workspace RDB read failed code=' +
        sshDiagnosticErrorCode(err));
      return { ok: false, rows: [] };
    } finally {
      if (rows !== null) {
        try { rows.close(); } catch (_closeError) {}
      }
    }
    return { ok: true, rows: result };
  }

  replace(row: SshWorkspaceStoredRow, expectedRevision: number): boolean {
    if (this.store === null) { return false; }
    let existing: relationalStore.ResultSet | null = null;
    try {
      this.store.beginTransaction();
      const existingPredicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(SSH_WORKSPACE_TABLE);
      existingPredicates.equalTo('workspaceid', row.workspaceId);
      existing = this.store.querySync(existingPredicates, ['revision']);
      const currentRevision: number = existing.goToFirstRow() ?
        existing.getLong(existing.getColumnIndex('revision')) : -1;
      existing.close();
      existing = null;
      if (currentRevision !== expectedRevision) { throw new Error('stale workspace revision'); }
      if (row.active) {
        this.store.updateSync({ active: 0 }, new relationalStore.RdbPredicates(SSH_WORKSPACE_TABLE));
      }
      const bucket: relationalStore.ValuesBucket = {
        workspaceid: row.workspaceId,
        schemaversion: row.schemaVersion,
        revision: row.revision,
        payload: row.payload,
        active: row.active ? 1 : 0,
        createdat: row.createdAt,
        updatedat: row.updatedAt
      };
      if (!rdbInsertSucceeded(this.store.insertSync(SSH_WORKSPACE_TABLE, bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('workspace insert failed');
      }
      this.store.commit();
      return true;
    } catch (_err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      return false;
    } finally {
      if (existing !== null) {
        try { existing.close(); } catch (_closeError) {}
      }
    }
  }

  remove(workspaceId: string, expectedRevision: number): boolean {
    if (this.store === null) { return false; }
    try {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(SSH_WORKSPACE_TABLE);
      predicates.equalTo('workspaceid', workspaceId);
      predicates.equalTo('revision', expectedRevision);
      return rdbSingleRowAffected(this.store.deleteSync(predicates));
    } catch (_err) {
      return false;
    }
  }
}

export class SshWorkspaceStore {
  private static instance: SshWorkspaceStore;
  private adapter: HarmonySshWorkspacePersistenceAdapter =
    new HarmonySshWorkspacePersistenceAdapter();
  private repository: SshWorkspaceRepository = new SshWorkspaceRepository(this.adapter);

  static getInstance(): SshWorkspaceStore {
    if (!SshWorkspaceStore.instance) { SshWorkspaceStore.instance = new SshWorkspaceStore(); }
    return SshWorkspaceStore.instance;
  }

  async init(context: common.Context): Promise<boolean> {
    return await this.adapter.init(context);
  }

  isReady(): boolean { return this.adapter.isReady(); }

  restore(): SshWorkspaceRestoreResult { return this.repository.restore(); }

  save(snapshot: SshWorkspaceSnapshotV1, active: boolean = true): SshWorkspaceSaveResult {
    return this.repository.save(snapshot, active);
  }

  remove(workspaceId: string): boolean { return this.repository.remove(workspaceId); }
}
