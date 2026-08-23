import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DataCrypto } from '../../DataCrypto';
import {
  addSshSessionLogBookmark,
  appendSshSessionLogRecord,
  continueSshSessionLogSearch,
  createSshSessionLogSearchCursor,
  decodeSshSessionLogDocument,
  emptySshSessionLogDocument,
  encodeSshSessionLogDocument,
  exportSshSessionLog,
  pruneSshSessionLogDocument,
  removeSshSessionLogBookmark,
  searchSshSessionLog,
  SshSessionLogBookmarkV1,
  SshSessionLogChunkV1,
  SshSessionLogDocumentV1,
  SshSessionLogExportResultV1,
  SshSessionLogIdentityV1,
  SshSessionLogRecordV1,
  SshSessionLogSearchCursorV1,
  SshSessionLogSearchHitV1,
  SshSessionLogSettingsV1,
  SSH_SESSION_LOG_SEARCH_WORK_BUDGET
} from './SshSessionLogPolicy';

/**
 * The index contains only chunk metadata/bookmarks/settings. Each chunk is a
 * separately encrypted value, so appending a line does not rewrite a 10 MiB
 * document on the ArkUI thread. Implementations are local-only by contract.
 */
export interface SshSessionLogChunkIndexV1 {
  id: string;
  hostId: string;
  sessionId: number;
  generation: number;
  createdAt: number;
  updatedAt: number;
  byteSize: number;
}

export interface SshSessionLogIndexV1 {
  schemaVersion: number;
  settings: SshSessionLogSettingsV1;
  chunks: Array<SshSessionLogChunkIndexV1>;
  bookmarks: Array<SshSessionLogBookmarkV1>;
}

interface SshSessionLogPendingWriteV1 {
  id: string;
  serialized: string;
  ciphertext: string;
}

export interface SshSessionLogPersistencePort {
  /** Open/migrate the local-only persistence before synchronous reads/writes. */
  prepare(context: common.Context): Promise<boolean>;
  readIndex(context: common.Context): string | null;
  writeIndex(context: common.Context, value: string): boolean;
  readChunk(context: common.Context, chunkId: string): string | null;
  listChunkIds(context: common.Context): Array<string> | null;
  writeChunk(context: common.Context, chunkId: string, value: string): boolean;
  removeChunk(context: common.Context, chunkId: string): boolean;
}

export interface SshSessionLogCryptoPort {
  ready(): boolean;
  encrypt(value: string): string;
  decrypt(value: string): string;
}

export const SSH_SESSION_LOG_DATABASE_NAME: string = 'remotedesktop_ssh_session_log.db';
export const SSH_SESSION_LOG_DATABASE_VERSION: number = 1;
export const SSH_SESSION_LOG_INDEX_TABLE: string = 'sshlogindex';
export const SSH_SESSION_LOG_CHUNK_TABLE: string = 'sshlogchunks';
const SSH_SESSION_LOG_INDEX_ROW_ID: string = 'root';

/**
 * Local-only RDB adapter. The index and every log chunk contain ciphertext
 * only; no distributed table or cloud subscription is registered here.
 */
class HarmonySshSessionLogPersistence implements SshSessionLogPersistencePort {
  private store: relationalStore.RdbStore | null = null;
  private initialized: boolean = false;
  private initPromise: Promise<boolean> | null = null;

  async prepare(context: common.Context): Promise<boolean> {
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
        name: SSH_SESSION_LOG_DATABASE_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      if (store.version > SSH_SESSION_LOG_DATABASE_VERSION) {
        try { await store.close(); } catch (_closeError) {}
        return false;
      }
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS ' + SSH_SESSION_LOG_INDEX_TABLE + ' (' +
        'id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL, updatedat INTEGER NOT NULL)');
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS ' + SSH_SESSION_LOG_CHUNK_TABLE + ' (' +
        'id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL, updatedat INTEGER NOT NULL)');
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_sshlogchunks_updated ' +
        'ON ' + SSH_SESSION_LOG_CHUNK_TABLE + ' (updatedat)');
      store.version = SSH_SESSION_LOG_DATABASE_VERSION;
      this.store = store;
      this.initialized = true;
      return true;
    } catch (_err) {
      this.store = null;
      this.initialized = false;
      return false;
    }
  }

  readIndex(_context: common.Context): string | null {
    return this.readValue(SSH_SESSION_LOG_INDEX_TABLE, SSH_SESSION_LOG_INDEX_ROW_ID);
  }

  writeIndex(_context: common.Context, value: string): boolean {
    return this.writeValue(SSH_SESSION_LOG_INDEX_TABLE, SSH_SESSION_LOG_INDEX_ROW_ID, value);
  }

  readChunk(_context: common.Context, chunkId: string): string | null {
    return this.readValue(SSH_SESSION_LOG_CHUNK_TABLE, chunkId);
  }

  listChunkIds(_context: common.Context): Array<string> | null {
    if (!this.initialized || this.store === null) { return null; }
    let rows: relationalStore.ResultSet | null = null;
    try {
      rows = this.store.querySync(
        new relationalStore.RdbPredicates(SSH_SESSION_LOG_CHUNK_TABLE), ['id']);
      const ids: Array<string> = [];
      const idColumn: number = rows.getColumnIndex('id');
      while (rows.goToNextRow()) {
        const id: string = rows.getString(idColumn).slice(0, 160);
        if (id.length > 0) { ids.push(id); }
      }
      return ids;
    } catch (_err) {
      return null;
    } finally {
      if (rows !== null) {
        try { rows.close(); } catch (_closeError) {}
      }
    }
  }

  writeChunk(_context: common.Context, chunkId: string, value: string): boolean {
    return this.writeValue(SSH_SESSION_LOG_CHUNK_TABLE, chunkId, value);
  }

  removeChunk(_context: common.Context, chunkId: string): boolean {
    return this.removeValue(SSH_SESSION_LOG_CHUNK_TABLE, chunkId);
  }

  private readValue(table: string, id: string): string | null {
    if (!this.initialized || this.store === null || id.length === 0) { return null; }
    let rows: relationalStore.ResultSet | null = null;
    try {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(table);
      predicates.equalTo('id', id);
      rows = this.store.querySync(predicates, ['ciphertext']);
      if (!rows.goToFirstRow()) { return null; }
      const value: string = rows.getString(rows.getColumnIndex('ciphertext'));
      return value.length > 0 ? value : null;
    } catch (_err) {
      return null;
    } finally {
      if (rows !== null) {
        try { rows.close(); } catch (_closeError) {}
      }
    }
  }

  private writeValue(table: string, id: string, value: string): boolean {
    if (!this.initialized || this.store === null || id.length === 0 || value.length === 0) {
      return false;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        id,
        ciphertext: value,
        updatedat: Date.now()
      };
      return this.store.insertSync(table, bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE) !== -1;
    } catch (_err) {
      return false;
    }
  }

  private removeValue(table: string, id: string): boolean {
    if (!this.initialized || this.store === null || id.length === 0) { return false; }
    try {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(table);
      predicates.equalTo('id', id);
      return this.store.deleteSync(predicates) !== -1;
    } catch (_err) {
      return false;
    }
  }
}

class DataCryptoSshSessionLogPort implements SshSessionLogCryptoPort {
  ready(): boolean { return DataCrypto.getInstance().isReady(); }
  encrypt(value: string): string { return DataCrypto.getInstance().encrypt(value); }
  decrypt(value: string): string { return DataCrypto.getInstance().decrypt(value); }
}

function cloneDocument(document: SshSessionLogDocumentV1): SshSessionLogDocumentV1 {
  return decodeSshSessionLogDocument(encodeSshSessionLogDocument(document)) ??
    emptySshSessionLogDocument();
}

function encodeChunk(chunk: Object): string {
  return JSON.stringify(chunk);
}

function decodeChunk(raw: string): Object | null {
  try {
    const value: Object = JSON.parse(raw) as Object;
    if (value === null || typeof value !== 'object') { return null; }
    return value;
  } catch (_err) { return null; }
}

function indexFromDocument(document: SshSessionLogDocumentV1): SshSessionLogIndexV1 {
  return {
    schemaVersion: 1,
    settings: document.settings,
    chunks: document.chunks.map((chunk): SshSessionLogChunkIndexV1 => ({
      id: chunk.id,
      hostId: chunk.hostId,
      sessionId: chunk.sessionId,
      generation: chunk.generation,
      createdAt: chunk.createdAt,
      updatedAt: chunk.updatedAt,
      byteSize: chunk.byteSize
    })),
    bookmarks: document.bookmarks
  };
}

function encodeIndex(index: SshSessionLogIndexV1): string {
  return JSON.stringify(index);
}

function decodeIndex(raw: string): SshSessionLogIndexV1 | null {
  try {
    const source: Object = JSON.parse(raw) as Object;
    if (source === null || typeof source !== 'object') { return null; }
    const item = source as SshSessionLogIndexV1;
    if (item.schemaVersion !== 1 || !Array.isArray(item.chunks) ||
      !Array.isArray(item.bookmarks) || item.settings === null ||
      typeof item.settings !== 'object') { return null; }
    return {
      schemaVersion: 1,
      settings: {
        enabled: item.settings.enabled === true,
        paused: item.settings.paused === true,
        redactSensitive: item.settings.redactSensitive !== false,
        retentionDays: item.settings.retentionDays,
        quotaBytes: item.settings.quotaBytes
      },
      chunks: item.chunks.slice(0, 2048).filter(
        (chunk: SshSessionLogChunkIndexV1): boolean => typeof chunk.id === 'string' &&
          chunk.id.length > 0 && typeof chunk.hostId === 'string' && chunk.hostId.length > 0 &&
          chunk.sessionId > 0 && chunk.generation > 0).map(
        (chunk: SshSessionLogChunkIndexV1): SshSessionLogChunkIndexV1 => ({
          id: chunk.id.slice(0, 160), hostId: chunk.hostId.slice(0, 96),
          sessionId: Math.floor(chunk.sessionId), generation: Math.floor(chunk.generation),
          createdAt: Math.max(0, Math.floor(chunk.createdAt)),
          updatedAt: Math.max(0, Math.floor(chunk.updatedAt)),
          byteSize: Math.max(0, Math.floor(chunk.byteSize))
        })),
      bookmarks: item.bookmarks.slice(0, 500) as Array<SshSessionLogBookmarkV1>
    };
  } catch (_err) {
    return null;
  }
}

export class SshSessionLogStore {
  private context: common.Context | null = null;
  private persistence: SshSessionLogPersistencePort;
  private crypto: SshSessionLogCryptoPort;
  private document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
  private initialized: boolean = false;
  private chunkSerialized: Map<string, string> = new Map<string, string>();
  private chunkCiphertext: Map<string, string> = new Map<string, string>();

  constructor(
    persistence: SshSessionLogPersistencePort = new HarmonySshSessionLogPersistence(),
    crypto: SshSessionLogCryptoPort = new DataCryptoSshSessionLogPort()
  ) {
    this.persistence = persistence;
    this.crypto = crypto;
  }

  async prepare(context: common.Context): Promise<boolean> {
    return await this.persistence.prepare(context);
  }

  init(context: common.Context): boolean {
    this.context = context;
    this.document = emptySshSessionLogDocument();
    this.chunkSerialized.clear();
    this.chunkCiphertext.clear();
    this.initialized = false;
    if (!this.crypto.ready()) { return false; }
    const stored: string | null = this.persistence.readIndex(context);
    if (stored === null) {
      const persistedIds: Array<string> | null = this.persistence.listChunkIds(context);
      if (persistedIds === null || persistedIds.length > 0) { return false; }
      // First use after the crypto store is unlocked: create an empty
      // encrypted index so opt-in logging is immediately available.
      const committed: boolean = this.commit(this.document);
      if (!committed || !this.removeOrphanedChunks(new Set<string>())) {
        this.initialized = false;
        return false;
      }
      return true;
    }
    if (stored.length === 0) {
      const persistedIds: Array<string> | null = this.persistence.listChunkIds(context);
      if (persistedIds === null || persistedIds.length > 0) { return false; }
      const committed: boolean = this.commit(this.document);
      if (!committed || !this.removeOrphanedChunks(new Set<string>())) {
        this.initialized = false;
        return false;
      }
      return true;
    }
    try {
      const index: SshSessionLogIndexV1 | null = decodeIndex(this.crypto.decrypt(stored));
      if (index === null) { return false; }
      const restored = emptySshSessionLogDocument();
      restored.settings = index.settings;
      restored.bookmarks = index.bookmarks;
      for (let indexPosition: number = 0; indexPosition < index.chunks.length; indexPosition++) {
        const metadata: SshSessionLogChunkIndexV1 = index.chunks[indexPosition];
        const ciphertext: string | null = this.persistence.readChunk(context, metadata.id);
        if (ciphertext === null || ciphertext.length === 0) { continue; }
        try {
          const chunkObject: Object | null = decodeChunk(this.crypto.decrypt(ciphertext));
          if (chunkObject === null) { continue; }
          const chunk = chunkObject as SshSessionLogChunkV1;
          if (chunk.id !== metadata.id || !Array.isArray(chunk.records)) { continue; }
          restored.chunks.push(chunk);
          this.chunkSerialized.set(chunk.id, encodeChunk(chunk));
          this.chunkCiphertext.set(chunk.id, ciphertext);
        } catch (_chunkError) {
          // One corrupt chunk must not hide the remaining sessions.
        }
      }
      this.document = pruneSshSessionLogDocument(restored, Date.now());
      this.initialized = true;
      // Repair an index that referenced a missing/corrupt/expired chunk.
      if (encodeIndex(indexFromDocument(this.document)) !== this.crypto.decrypt(stored)) {
        if (!this.commit(this.document)) {
          this.initialized = false;
          return false;
        }
      }
      const retainedIds: Set<string> = new Set<string>();
      this.document.chunks.forEach((chunk: SshSessionLogChunkV1): void => {
        retainedIds.add(chunk.id);
      });
      if (!this.removeOrphanedChunks(retainedIds)) {
        this.initialized = false;
        return false;
      }
      return true;
    } catch (_err) { return false; }
  }

  isReady(): boolean {
    return this.initialized && this.context !== null && this.crypto.ready();
  }

  snapshot(): SshSessionLogDocumentV1 {
    return cloneDocument(this.document);
  }

  /**
   * ArkUI only needs settings and chunk counts. Keep durable record payloads
   * out of observable page state so an open log sheet cannot clone up to the
   * full local quota after every buffered output flush.
   */
  pageSnapshot(): SshSessionLogDocumentV1 {
    return {
      schemaVersion: this.document.schemaVersion,
      settings: this.settingsSnapshot(),
      bookmarks: [],
      chunks: this.document.chunks.map((chunk): SshSessionLogChunkV1 => ({
        id: chunk.id,
        hostId: chunk.hostId,
        sessionId: chunk.sessionId,
        generation: chunk.generation,
        createdAt: chunk.createdAt,
        updatedAt: chunk.updatedAt,
        byteSize: chunk.byteSize,
        records: []
      }))
    };
  }

  settingsSnapshot(): SshSessionLogSettingsV1 {
    const settings: SshSessionLogSettingsV1 = this.document.settings;
    return {
      enabled: settings.enabled,
      paused: settings.paused,
      redactSensitive: settings.redactSensitive,
      retentionDays: settings.retentionDays,
      quotaBytes: settings.quotaBytes
    };
  }

  setSettings(settings: SshSessionLogSettingsV1): boolean {
    if (!this.isReady()) { return false; }
    const next: SshSessionLogDocumentV1 = cloneDocument(this.document);
    next.settings = settings;
    if (!settings.enabled) { next.settings.paused = false; }
    return this.commit(next);
  }

  append(record: SshSessionLogRecordV1, nowMs: number = Date.now()): boolean {
    if (!this.isReady() || !this.document.settings.enabled || this.document.settings.paused) {
      return false;
    }
    const next: SshSessionLogDocumentV1 = appendSshSessionLogRecord(
      this.document, record, nowMs);
    if (next === this.document) { return false; }
    return this.commitAppend(next);
  }

  addBookmark(identity: SshSessionLogIdentityV1, recordId: string, note: string,
    pinned: boolean = true, nowMs: number = Date.now()): boolean {
    if (!this.isReady()) { return false; }
    const next: SshSessionLogDocumentV1 | null = addSshSessionLogBookmark(
      this.document, identity, recordId, note, pinned, nowMs);
    return next !== null && this.commit(next);
  }

  removeBookmark(bookmarkId: string): boolean {
    if (!this.isReady()) { return false; }
    return this.commit(removeSshSessionLogBookmark(this.document, bookmarkId));
  }

  search(query: string, hostId: string = '', identity?: SshSessionLogIdentityV1):
    Array<SshSessionLogSearchHitV1> {
    if (!this.isReady()) { return []; }
    return searchSshSessionLog(this.document, query, hostId, identity);
  }

  /** Yield after bounded scan slices so a 10 MiB miss cannot monopolize ArkUI. */
  searchAsync(query: string, hostId: string = '', identity?: SshSessionLogIdentityV1,
    shouldContinue?: () => boolean):
    Promise<Array<SshSessionLogSearchHitV1>> {
    if (!this.isReady()) { return Promise.resolve([]); }
    const document: SshSessionLogDocumentV1 = this.document;
    let cursor: SshSessionLogSearchCursorV1 = createSshSessionLogSearchCursor(
      document, query, hostId, identity);
    return new Promise<Array<SshSessionLogSearchHitV1>>((resolve): void => {
      const advance = (): void => {
        if (shouldContinue !== undefined && !shouldContinue()) {
          resolve([]);
          return;
        }
        cursor = continueSshSessionLogSearch(
          document, cursor, SSH_SESSION_LOG_SEARCH_WORK_BUDGET);
        if (cursor.done) {
          resolve(cursor.results);
          return;
        }
        setTimeout(advance, 0);
      };
      advance();
    });
  }

  export(hostId: string, identity?: SshSessionLogIdentityV1, redact: boolean = true):
    SshSessionLogExportResultV1 {
    if (!this.isReady()) {
      return { ok: false, text: '', recordCount: 0, redactedCount: 0, truncated: false };
    }
    return exportSshSessionLog(this.document, hostId, identity, redact);
  }

  clearHost(hostId: string): boolean {
    if (!this.isReady()) { return false; }
    const normalized: string = hostId.trim();
    const next: SshSessionLogDocumentV1 = cloneDocument(this.document);
    next.chunks = next.chunks.filter((chunk): boolean => chunk.hostId !== normalized);
    next.bookmarks = next.bookmarks.filter((bookmark): boolean => bookmark.hostId !== normalized);
    return this.commit(next);
  }

  clearAll(): boolean {
    if (!this.isReady()) { return false; }
    return this.commit(emptySshSessionLogDocument());
  }

  private commit(nextDocument: SshSessionLogDocumentV1): boolean {
    const normalized: SshSessionLogDocumentV1 = decodeSshSessionLogDocument(
      encodeSshSessionLogDocument(nextDocument)) ?? emptySshSessionLogDocument();
    return this.commitPrepared(normalized);
  }

  private commitAppend(nextDocument: SshSessionLogDocumentV1): boolean {
    // Incremental append preserves old chunk references. A changed object with
    // an old immutable id would overwrite data visible through the old index,
    // so reject that collision instead of weakening restart consistency.
    const oldChunks: Map<string, SshSessionLogChunkV1> =
      new Map<string, SshSessionLogChunkV1>();
    for (let index: number = 0; index < this.document.chunks.length; index++) {
      const chunk: SshSessionLogChunkV1 = this.document.chunks[index];
      oldChunks.set(chunk.id, chunk);
    }
    for (let index: number = 0; index < nextDocument.chunks.length; index++) {
      const chunk: SshSessionLogChunkV1 = nextDocument.chunks[index];
      const oldChunk: SshSessionLogChunkV1 | undefined = oldChunks.get(chunk.id);
      if (oldChunk !== undefined && oldChunk !== chunk) { return false; }
    }
    return this.commitPrepared(nextDocument);
  }

  private commitPrepared(normalized: SshSessionLogDocumentV1): boolean {
    if (this.context === null || !this.crypto.ready()) { return false; }
    const context: common.Context = this.context;
    const nextIds: Set<string> = new Set<string>();
    const writes: Array<SshSessionLogPendingWriteV1> = [];
    const writtenIds: Array<string> = [];
    try {
      for (let index: number = 0; index < normalized.chunks.length; index++) {
        const chunk = normalized.chunks[index];
        nextIds.add(chunk.id);
        // Chunk ids are immutable. A cached id is therefore an unchanged row;
        // do not stringify its records merely to rediscover that fact.
        if (this.chunkSerialized.has(chunk.id)) { continue; }
        const serialized: string = encodeChunk(chunk);
        const ciphertext: string = this.crypto.encrypt(serialized);
        if (ciphertext.length === 0 || ciphertext === serialized) { return false; }
        writes.push({ id: chunk.id, serialized, ciphertext });
      }
      // Write data first. If the index update fails, the old index remains
      // authoritative and every newly written row is rolled back immediately.
      // A real process stop between these operations is cleaned on next init.
      for (let index: number = 0; index < writes.length; index++) {
        const item = writes[index];
        if (!this.persistence.writeChunk(context, item.id, item.ciphertext)) {
          this.rollbackPendingChunks(writtenIds);
          return false;
        }
        writtenIds.push(item.id);
      }
      const indexPlain: string = encodeIndex(indexFromDocument(normalized));
      const indexCiphertext: string = this.crypto.encrypt(indexPlain);
      if (indexCiphertext.length === 0 || indexCiphertext === indexPlain ||
        !this.persistence.writeIndex(context, indexCiphertext)) {
        this.rollbackPendingChunks(writtenIds);
        return false;
      }
      const oldIds: string[] = [];
      this.document.chunks.forEach((chunk): void => { oldIds.push(chunk.id); });
      oldIds.forEach((id: string): void => {
        if (!nextIds.has(id)) {
          this.persistence.removeChunk(context, id);
          this.chunkSerialized.delete(id);
          this.chunkCiphertext.delete(id);
        }
      });
      writes.forEach((item): void => {
        this.chunkSerialized.set(item.id, item.serialized);
        this.chunkCiphertext.set(item.id, item.ciphertext);
      });
      this.document = normalized;
      this.initialized = true;
      return true;
    } catch (_err) {
      this.rollbackPendingChunks(writtenIds);
      return false;
    }
  }

  private rollbackPendingChunks(chunkIds: Array<string>): void {
    if (this.context === null) { return; }
    for (let index: number = 0; index < chunkIds.length; index++) {
      this.persistence.removeChunk(this.context, chunkIds[index]);
      this.chunkSerialized.delete(chunkIds[index]);
      this.chunkCiphertext.delete(chunkIds[index]);
    }
  }

  private removeOrphanedChunks(retainedIds: Set<string>): boolean {
    if (this.context === null) { return false; }
    const persistedIds: Array<string> | null = this.persistence.listChunkIds(this.context);
    if (persistedIds === null) { return false; }
    for (let index: number = 0; index < persistedIds.length; index++) {
      const id: string = persistedIds[index];
      if (retainedIds.has(id)) { continue; }
      if (!this.persistence.removeChunk(this.context, id)) { return false; }
      this.chunkSerialized.delete(id);
      this.chunkCiphertext.delete(id);
    }
    return true;
  }
}
