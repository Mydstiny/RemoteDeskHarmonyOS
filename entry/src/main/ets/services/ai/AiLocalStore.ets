import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AiAccess, AiAccountLease } from './AiAccess';
import { AiLifecycle } from './AiLifecycle';
import { AiHost, AiIdentity, AiPendingOperation, AiSettings, aiHostError, aiIdValid,
  aiSameEndpoint, aiSettingsValid, defaultAiSettings } from './AiModels';

export interface AiConnectionRecord { host: AiHost; identity: AiIdentity | null; }

/** Independent encrypted local database. Never registered for cloud sync/export. */
export class AiLocalStore {
  private static instance: AiLocalStore;
  private store: relationalStore.RdbStore | null = null;
  private opening: Promise<void> | null = null;
  private queue: Promise<void> = Promise.resolve();
  private listeners: Array<() => void> = [];
  static getInstance(): AiLocalStore {
    if (!AiLocalStore.instance) { AiLocalStore.instance = new AiLocalStore(); }
    return AiLocalStore.instance;
  }
  initialize(context: common.Context): Promise<void> {
    if (this.store !== null) { return Promise.resolve(); }
    if (this.opening !== null) { return this.opening; }
    this.opening = this.open(context).finally((): void => { this.opening = null; });
    return this.opening;
  }
  private async open(context: common.Context): Promise<void> {
    const db = await relationalStore.getRdbStore(context, { name: 'remotedesk_ai_private_v1.db',
      securityLevel: relationalStore.SecurityLevel.S4, encrypt: true });
    try {
      if (db.version !== 0 && db.version !== 1) { throw new Error('AI_STORE_VERSION_UNSUPPORTED'); }
      if (db.version === 0) {
        db.beginTransaction();
        try {
          await db.executeSql('CREATE TABLE ai_hosts (owner TEXT NOT NULL,id TEXT NOT NULL,data TEXT NOT NULL,' +
            'identity TEXT NOT NULL,PRIMARY KEY(owner,id))');
          await db.executeSql('CREATE TABLE ai_operations (owner TEXT NOT NULL,id TEXT NOT NULL,host TEXT NOT NULL,' +
            'session TEXT NOT NULL,created INTEGER NOT NULL,body TEXT NOT NULL,receipt TEXT NOT NULL,PRIMARY KEY(owner,id))');
          await db.executeSql('CREATE TABLE ai_settings (owner TEXT PRIMARY KEY,data TEXT NOT NULL)');
          db.version = 1;
          db.commit();
        } catch (_error) { db.rollBack(); throw new Error('AI_STORE_SCHEMA_FAILED'); }
      }
      this.store = db;
    } catch (_error) { await db.close(); throw new Error('AI_STORE_UNAVAILABLE'); }
  }
  private serialize<T>(lease: AiAccountLease, action: (db: relationalStore.RdbStore) => Promise<T>): Promise<T> {
    const access = AiAccess.getInstance();
    const operation = this.queue.then(async (): Promise<T> => {
      if (this.opening !== null) { await this.opening; }
      if (!access.proVisible()) { throw new Error('AI_PRO_ACCESS_REQUIRED'); }
      access.assertCurrent(lease);
      const db = this.store;
      if (db === null) { throw new Error('AI_STORE_UNAVAILABLE'); }
      const result = await action(db);
      if (!access.proVisible()) { throw new Error('AI_PRO_ACCESS_REQUIRED'); }
      access.assertCurrent(lease);
      return result;
    });
    this.queue = operation.then((): void => {}, (): void => {});
    return operation;
  }
  private async transaction(lease: AiAccountLease, db: relationalStore.RdbStore,
    action: () => Promise<void>): Promise<void> {
    db.beginTransaction();
    try {
      await action();
      if (!AiAccess.getInstance().proVisible()) { throw new Error('AI_PRO_ACCESS_REQUIRED'); }
      AiAccess.getInstance().assertCurrent(lease);
      db.commit();
    } catch (_error) { db.rollBack(); throw new Error('AI_STORE_WRITE_FAILED'); }
  }
  hosts(lease: AiAccountLease): Promise<AiHost[]> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<AiHost[]> => {
      const rows = await db.querySql('SELECT data FROM ai_hosts WHERE owner=? LIMIT 257', [lease.owner]);
      const hosts: AiHost[] = [];
      try {
        while (rows.goToNextRow()) {
          const host = JSON.parse(rows.getString(0)) as AiHost;
          if (host.owner !== lease.owner || aiHostError(host) !== '' || hosts.length >= 256) {
            throw new Error('AI_HOST_RECORD_INVALID');
          }
          hosts.push(host);
        }
      } finally { rows.close(); }
      return hosts;
    });
  }
  saveHost(lease: AiAccountLease, host: AiHost, identity: AiIdentity | null = null): Promise<void> {
    if (host.owner !== lease.owner || aiHostError(host) !== '') { return Promise.reject(new Error('AI_HOST_INVALID')); }
    // Freeze the caller's mutable draft before waiting on the process-wide queue.
    const frozen = JSON.stringify(host);
    const secret = identity === null ? null : JSON.stringify(identity);
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      AiLifecycle.closeHost(host.id);
      await this.transaction(lease, db, async (): Promise<void> => {
        const next = JSON.parse(frozen) as AiHost;
        const rows = await db.querySql('SELECT data,identity FROM ai_hosts WHERE owner=? AND id=?', [lease.owner, next.id]);
        let old: AiHost | null = null;
        let retained = '';
        try {
          if (rows.goToFirstRow()) { old = JSON.parse(rows.getString(0)) as AiHost; retained = rows.getString(1); }
        } finally { rows.close(); }
        if ((old === null && next.revision !== 0) || (old !== null && old.revision !== next.revision)) {
          throw new Error('AI_HOST_CHANGED');
        }
        if (old !== null && !aiSameEndpoint(old, next)) { retained = ''; }
        if (old === null) {
          const count = await db.querySql('SELECT COUNT(*) FROM ai_hosts WHERE owner=?', [lease.owner]);
          try { if (!count.goToFirstRow() || count.getLong(0) >= 256) { throw new Error('AI_HOST_LIMIT'); } }
          finally { count.close(); }
        }
        next.revision++;
        await db.executeSql('INSERT OR REPLACE INTO ai_hosts VALUES (?,?,?,?)',
          [lease.owner, next.id, JSON.stringify(next), secret === null ? retained : secret]);
      });
      this.publish();
    });
  }
  connection(lease: AiAccountLease, id: string): Promise<AiConnectionRecord | null> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<AiConnectionRecord | null> => {
      const rows = await db.querySql('SELECT data,identity FROM ai_hosts WHERE owner=? AND id=?', [lease.owner, id]);
      try {
        if (!rows.goToFirstRow()) { return null; }
        const host = JSON.parse(rows.getString(0)) as AiHost;
        if (host.owner !== lease.owner || aiHostError(host) !== '') { throw new Error('AI_HOST_RECORD_INVALID'); }
        if (rows.getString(1) === '') { return { host, identity: null }; }
        const identity = JSON.parse(rows.getString(1)) as AiIdentity;
        if (!aiIdValid(identity.deviceId) || !aiIdValid(identity.instance) ||
          !identity.ca.includes('BEGIN CERTIFICATE') || !identity.certificate.includes('BEGIN CERTIFICATE') ||
          !identity.privateKey.includes('PRIVATE KEY')) { throw new Error('AI_IDENTITY_INVALID'); }
        return { host, identity };
      } finally { rows.close(); }
    });
  }
  removeHost(lease: AiAccountLease, id: string): Promise<void> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      AiLifecycle.closeHost(id);
      await this.transaction(lease, db, async (): Promise<void> => {
        await db.executeSql('DELETE FROM ai_operations WHERE owner=? AND host=?', [lease.owner, id]);
        await db.executeSql('DELETE FROM ai_hosts WHERE owner=? AND id=?', [lease.owner, id]);
      });
      this.publish();
    });
  }
  settings(lease: AiAccountLease): Promise<AiSettings> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<AiSettings> => {
      const rows = await db.querySql('SELECT data FROM ai_settings WHERE owner=?', [lease.owner]);
      try {
        if (!rows.goToFirstRow()) { return defaultAiSettings(); }
        const settings = JSON.parse(rows.getString(0)) as AiSettings;
        if (!aiSettingsValid(settings)) { throw new Error('AI_SETTINGS_INVALID'); }
        return settings;
      } finally { rows.close(); }
    });
  }
  /**
   * Read, change and write the settings as one step of the store's queue, so a change made elsewhere in between is
   * kept. `change` returns the settings to write, or null to leave them; the result is what is stored afterwards.
   */
  updateSettings(lease: AiAccountLease, change: (stored: AiSettings) => AiSettings | null): Promise<AiSettings> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<AiSettings> => {
      const rows = await db.querySql('SELECT data FROM ai_settings WHERE owner=?', [lease.owner]);
      let stored: AiSettings = defaultAiSettings();
      try {
        if (rows.goToFirstRow()) {
          stored = JSON.parse(rows.getString(0)) as AiSettings;
          if (!aiSettingsValid(stored)) { throw new Error('AI_SETTINGS_INVALID'); }
        }
      } finally { rows.close(); }
      const next: AiSettings | null = change(JSON.parse(JSON.stringify(stored)) as AiSettings);
      if (next === null) { return stored; }
      if (!aiSettingsValid(next)) { throw new Error('AI_SETTINGS_INVALID'); }
      const data = JSON.stringify(next);
      await this.transaction(lease, db, async (): Promise<void> => {
        await db.executeSql('INSERT OR REPLACE INTO ai_settings VALUES (?,?)', [lease.owner, data]);
      });
      this.publish();
      return JSON.parse(data) as AiSettings;
    });
  }
  saveSettings(lease: AiAccountLease, settings: AiSettings): Promise<void> {
    if (!aiSettingsValid(settings)) { return Promise.reject(new Error('AI_SETTINGS_INVALID')); }
    const data = JSON.stringify(settings);
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      await this.transaction(lease, db, async (): Promise<void> => {
        await db.executeSql('INSERT OR REPLACE INTO ai_settings VALUES (?,?)', [lease.owner, data]);
      });
      this.publish();
    });
  }
  retainOperation(lease: AiAccountLease, operation: AiPendingOperation): Promise<void> {
    if (!aiIdValid(operation.id) || !aiIdValid(operation.hostId) ||
      new util.TextEncoder().encodeInto(operation.body).length > 800000) {
      return Promise.reject(new Error('AI_OPERATION_INVALID'));
    }
    const frozen = JSON.stringify(operation);
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      const op = JSON.parse(frozen) as AiPendingOperation;
      await this.transaction(lease, db, async (): Promise<void> => {
        const prior = await db.querySql('SELECT body FROM ai_operations WHERE owner=? AND id=?', [lease.owner, op.id]);
        let exists = false;
        try {
          exists = prior.goToFirstRow();
          if (exists && prior.getString(0) !== op.body) { throw new Error('AI_OPERATION_CONFLICT'); }
        } finally { prior.close(); }
        if (exists) { return; }
        const completed = await db.querySql('SELECT id,receipt,LENGTH(CAST(body AS BLOB)) FROM ai_operations WHERE owner=? ORDER BY created DESC', [lease.owner]);
        const oldIds: string[] = []; let retainedCount = 0; let retainedBytes = 0;
        try {
          while (completed.goToNextRow()) {
            const text = completed.getString(1); if (text === '') { continue; }
            const receipt = JSON.parse(text) as Record<string, Object>;
            if (receipt['status'] === 'succeeded' || receipt['status'] === 'rejected') {
              retainedCount++; retainedBytes += completed.getLong(2);
              if (retainedCount > 200 || retainedBytes > 8 * 1024 * 1024) { oldIds.push(completed.getString(0)); }
            }
          }
        } finally { completed.close(); }
        for (const id of oldIds) { await db.executeSql('DELETE FROM ai_operations WHERE owner=? AND id=?', [lease.owner, id]); }
        const count = await db.querySql('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(body AS BLOB))),0) ' +
          'FROM ai_operations WHERE owner=?', [lease.owner]);
        try {
          if (!count.goToFirstRow() || count.getLong(0) >= 1000 ||
            count.getLong(1) + new util.TextEncoder().encodeInto(op.body).length > 16 * 1024 * 1024) {
            throw new Error('AI_OPERATION_STORAGE_FULL');
          }
        } finally { count.close(); }
        await db.executeSql('INSERT INTO ai_operations VALUES (?,?,?,?,?,?,?)',
          [lease.owner, op.id, op.hostId, op.sessionId, op.createdAt, op.body, '']);
      });
    });
  }
  saveReceipt(lease: AiAccountLease, id: string, receipt: string): Promise<void> {
    if (receipt.length > 1000000) { return Promise.reject(new Error('AI_RECEIPT_TOO_LARGE')); }
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      await this.transaction(lease, db, async (): Promise<void> => {
        await db.executeSql('UPDATE ai_operations SET receipt=? WHERE owner=? AND id=?', [receipt, lease.owner, id]);
      });
    });
  }
  operations(lease: AiAccountLease, hostId: string): Promise<AiPendingOperation[]> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<AiPendingOperation[]> => {
      const rows = await db.querySql('SELECT id,session,created,body,receipt FROM ai_operations ' +
        'WHERE owner=? AND host=? ORDER BY created DESC LIMIT 1000', [lease.owner, hostId]);
      const output: AiPendingOperation[] = [];
      try {
        while (rows.goToNextRow()) { output.push({ id: rows.getString(0), hostId, sessionId: rows.getString(1),
          createdAt: rows.getLong(2), body: rows.getString(3), receipt: rows.getString(4) }); }
      } finally { rows.close(); }
      return output;
    });
  }
  clearCompletedOperations(lease: AiAccountLease): Promise<void> {
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      const rows = await db.querySql('SELECT id,receipt FROM ai_operations WHERE owner=?', [lease.owner]);
      const ids: string[] = [];
      try {
        while (rows.goToNextRow()) {
          const text = rows.getString(1);
          if (text === '') { continue; }
          const receipt = JSON.parse(text) as Record<string, Object>;
          if (receipt['status'] === 'succeeded' || receipt['status'] === 'rejected') { ids.push(rows.getString(0)); }
        }
      } finally { rows.close(); }
      await this.transaction(lease, db, async (): Promise<void> => {
        for (const id of ids) { await db.executeSql('DELETE FROM ai_operations WHERE owner=? AND id=?', [lease.owner, id]); }
      });
    });
  }
  importHosts(lease: AiAccountLease, hosts: AiHost[], settings: AiSettings): Promise<void> {
    if (hosts.some((host: AiHost): boolean => host.owner !== lease.owner || aiHostError(host) !== '') ||
      !aiSettingsValid(settings)) { return Promise.reject(new Error('AI_IMPORT_INVALID')); }
    const frozen = JSON.stringify(hosts); const preferences = JSON.stringify(settings);
    return this.serialize(lease, async (db: relationalStore.RdbStore): Promise<void> => {
      await this.transaction(lease, db, async (): Promise<void> => {
        const rows = await db.querySql('SELECT COUNT(*) FROM ai_hosts WHERE owner=?', [lease.owner]);
        try { if (!rows.goToFirstRow() || rows.getLong(0) + hosts.length > 256) { throw new Error('AI_HOST_LIMIT'); } }
        finally { rows.close(); }
        for (const host of JSON.parse(frozen) as AiHost[]) {
          host.revision = 1;
          await db.executeSql('INSERT INTO ai_hosts VALUES (?,?,?,?)', [lease.owner, host.id, JSON.stringify(host), '']);
        }
        await db.executeSql('INSERT OR REPLACE INTO ai_settings VALUES (?,?)', [lease.owner, preferences]);
      }); this.publish();
    });
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* Isolate subscribers. */ }
    });
  }
}
