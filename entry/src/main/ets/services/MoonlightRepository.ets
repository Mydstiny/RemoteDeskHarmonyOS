import {
  MoonlightRecord,
  moonlightLocalOnlyFlagIsValid
} from '../model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MoonlightConflictMergeContext,
  resolveMoonlightRecordConflict
} from './MoonlightRecordConflictPolicy';
import {
  moonlightRecordPayloadHashSha256,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';

export type MoonlightRepositoryCode =
  'ok' | 'unchanged' | 'not_found' | 'not_ready' | 'stale_lease' |
  'invalid_owner' | 'invalid_record' | 'conflict' | 'quarantined' |
  'local_write_failed' | 'readback_failed';

export interface MoonlightRepositoryResult {
  ok: boolean;
  code: MoonlightRepositoryCode;
  record: MoonlightRecord | null;
  localCommitted: boolean;
  cloudAttempted: boolean;
  reason: string;
}

export interface MoonlightRepositoryReadResult {
  ok: boolean;
  record: MoonlightRecord | null;
  localOnly: number;
}

export interface MoonlightRepositoryCommit {
  record: MoonlightRecord;
  localOnly: number;
  operation: string;
}

export interface MoonlightRepositoryBatchMutation {
  record: MoonlightRecord;
  localOnly: number;
}

export interface MoonlightRepositoryBatchResult {
  ok: boolean;
  code: MoonlightRepositoryCode;
  records: MoonlightRecord[];
  localCommitted: boolean;
  reason: string;
}

export interface MoonlightRepositoryPort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
  readMoonlightLocalRecord(
    lease: AccountSessionLease, id: string
  ): MoonlightRepositoryReadResult;
  loadMoonlightLocalRecords(
    lease: AccountSessionLease, includeDeleted?: boolean
  ): MoonlightRecord[] | null;
  commitMoonlightLocalRecord(
    lease: AccountSessionLease,
    record: MoonlightRecord,
    localOnly: number,
    operation: string
  ): boolean;
  commitMoonlightLocalRecords(
    lease: AccountSessionLease,
    commits: MoonlightRepositoryCommit[]
  ): boolean;
  recordMoonlightQuarantine(
    lease: AccountSessionLease,
    recordId: string,
    reason: string,
    payloadHashSha256: string
  ): boolean;
}

function batchResult(ok: boolean, code: MoonlightRepositoryCode,
  records: MoonlightRecord[], localCommitted: boolean,
  reason: string = ''): MoonlightRepositoryBatchResult {
  const copies: MoonlightRecord[] = [];
  for (let i = 0; i < records.length; i++) {
    copies.push(MoonlightRecord.fromJSON(records[i].toJSON()));
  }
  return {
    ok: ok,
    code: code,
    records: copies,
    localCommitted: localCommitted,
    reason: reason
  };
}

function result(ok: boolean, code: MoonlightRepositoryCode,
  record: MoonlightRecord | null, localCommitted: boolean,
  reason: string = ''): MoonlightRepositoryResult {
  return {
    ok: ok,
    code: code,
    record: record,
    localCommitted: localCommitted,
    // The local repository never invokes cloud I/O. CloudStore owns promotion
    // after every physical/logical/bootstrap gate is satisfied.
    cloudAttempted: false,
    reason: reason
  };
}

function sameRecord(left: MoonlightRecord, right: MoonlightRecord): boolean {
  const leftJson = left.toJSON();
  const rightJson = right.toJSON();
  return leftJson.id === rightJson.id &&
    leftJson.userId === rightJson.userId &&
    leftJson.recordType === rightJson.recordType &&
    leftJson.ownerId === rightJson.ownerId &&
    leftJson.ownerType === rightJson.ownerType &&
    leftJson.secretKind === rightJson.secretKind &&
    leftJson.payload === rightJson.payload &&
    leftJson.ciphertext === rightJson.ciphertext &&
    leftJson.envelopeVersion === rightJson.envelopeVersion &&
    leftJson.cryptoVersion === rightJson.cryptoVersion &&
    leftJson.keyVersion === rightJson.keyVersion &&
    leftJson.aadVersion === rightJson.aadVersion &&
    leftJson.payloadHashSha256 === rightJson.payloadHashSha256 &&
    leftJson.syncVersion === rightJson.syncVersion &&
    leftJson.schemaVersion === rightJson.schemaVersion &&
    leftJson.resetEpoch === rightJson.resetEpoch &&
    leftJson.createdAt === rightJson.createdAt &&
    leftJson.updatedAt === rightJson.updatedAt &&
    leftJson.deletedAt === rightJson.deletedAt;
}

export class MoonlightRepository {
  private readonly port: MoonlightRepositoryPort;

  constructor(port: MoonlightRepositoryPort) {
    this.port = port;
  }

  loadAll(lease: AccountSessionLease,
    includeDeleted: boolean = false): MoonlightRecord[] | null {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) { return null; }
    const rows: MoonlightRecord[] | null =
      this.port.loadMoonlightLocalRecords(captured, includeDeleted);
    if (rows === null || !this.leaseIsCurrent(captured)) { return null; }
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].userId !== captured.ownerScopeId ||
          !moonlightValidateRecord(rows[i]).valid ||
          (!includeDeleted && rows[i].deletedAt > 0)) {
        return null;
      }
    }
    return rows;
  }

  upsert(lease: AccountSessionLease, candidate: MoonlightRecord,
    localOnly: number = 1,
    mergeContext: MoonlightConflictMergeContext | null = null
  ): MoonlightRepositoryResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', null, false);
    }
    if (!moonlightLocalOnlyFlagIsValid(localOnly)) {
      return result(false, 'invalid_record', null, false, 'invalid_localonly');
    }
    const proposed: MoonlightRecord = MoonlightRecord.fromJSON(candidate.toJSON());
    if (proposed.userId !== captured.ownerScopeId) {
      return result(false, 'invalid_owner', null, false);
    }
    const validation = moonlightValidateRecord(proposed);
    if (!validation.valid) {
      return result(false, 'invalid_record', null, false, validation.reason);
    }
    let currentRead: MoonlightRepositoryReadResult;
    try {
      currentRead = this.port.readMoonlightLocalRecord(captured, proposed.id);
    } catch (_error) {
      return result(false, 'not_ready', null, false);
    }
    if (!currentRead.ok || !this.leaseIsCurrent(captured)) {
      return result(false, currentRead.ok ? 'stale_lease' : 'not_ready',
        null, false);
    }
    let toWrite: MoonlightRecord = proposed;
    if (currentRead.record !== null) {
      if (currentRead.record.userId !== captured.ownerScopeId) {
        return result(false, 'invalid_owner', null, false);
      }
      const decision = resolveMoonlightRecordConflict(
        currentRead.record, proposed, mergeContext);
      if (decision.action === 'keep_current') {
        const unchanged: boolean = decision.reason === 'identical_retry' ||
          sameRecord(currentRead.record, proposed);
        if (!unchanged || currentRead.localOnly === localOnly) {
          return result(unchanged, unchanged ? 'unchanged' : 'conflict',
            MoonlightRecord.fromJSON(currentRead.record.toJSON()), false,
            decision.reason);
        }
        // A projection decision may change while the logical row remains an
        // exact retry. Persist only the local eligibility bit; cloud I/O still
        // belongs to the gated projection service.
        toWrite = MoonlightRecord.fromJSON(currentRead.record.toJSON());
      }
      if (decision.action === 'quarantine_candidate' ||
          decision.action === 'quarantine_both') {
        const quarantined: boolean = this.port.recordMoonlightQuarantine(
          captured, proposed.id, decision.reason,
          proposed.payloadHashSha256);
        return result(false, quarantined ? 'quarantined' : 'conflict',
          MoonlightRecord.fromJSON(currentRead.record.toJSON()), false,
          decision.reason);
      }
      if (decision.record === null) {
        return result(false, 'conflict', null, false, decision.reason);
      }
      toWrite = MoonlightRecord.fromJSON(decision.record.toJSON());
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', null, false);
    }
    const operation: string = toWrite.deletedAt > 0 ? 'tombstone' : 'upsert';
    if (!this.port.commitMoonlightLocalRecord(
      captured, toWrite, localOnly, operation)) {
      return result(false, this.leaseIsCurrent(captured) ?
        'local_write_failed' : 'stale_lease', null, false);
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', null, true);
    }
    let readback: MoonlightRepositoryReadResult;
    try {
      readback = this.port.readMoonlightLocalRecord(captured, toWrite.id);
    } catch (_error) {
      return result(false, 'readback_failed', null, true);
    }
    if (!readback.ok || readback.record === null ||
        readback.localOnly !== localOnly ||
        !sameRecord(readback.record, toWrite)) {
      return result(false, 'readback_failed', readback.record, true);
    }
    return result(true, 'ok',
      MoonlightRecord.fromJSON(toWrite.toJSON()), true);
  }

  /**
   * Resolve and persist a related Moonlight graph in one physical transaction.
   * This is used for compound user actions such as host + trust creation where
   * compensating a first committed row cannot cover process death.
   */
  upsertBatch(lease: AccountSessionLease,
    mutations: MoonlightRepositoryBatchMutation[]): MoonlightRepositoryBatchResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return batchResult(false, 'stale_lease', [], false);
    }
    if (mutations.length === 0) {
      return batchResult(true, 'unchanged', [], false);
    }
    const ids: string[] = [];
    const writes: MoonlightRepositoryCommit[] = [];
    const resolved: MoonlightRecord[] = [];
    for (let i = 0; i < mutations.length; i++) {
      const localOnly: number = mutations[i].localOnly;
      const proposed: MoonlightRecord =
        MoonlightRecord.fromJSON(mutations[i].record.toJSON());
      if (!moonlightLocalOnlyFlagIsValid(localOnly) ||
          proposed.userId !== captured.ownerScopeId ||
          !moonlightValidateRecord(proposed).valid ||
          ids.indexOf(proposed.id) >= 0) {
        return batchResult(false, 'invalid_record', [], false);
      }
      ids.push(proposed.id);
      let currentRead: MoonlightRepositoryReadResult;
      try {
        currentRead = this.port.readMoonlightLocalRecord(
          captured, proposed.id);
      } catch (_error) {
        return batchResult(false, 'not_ready', [], false);
      }
      if (!currentRead.ok || !this.leaseIsCurrent(captured)) {
        return batchResult(false, currentRead.ok ? 'stale_lease' : 'not_ready',
          [], false);
      }
      let toWrite: MoonlightRecord = proposed;
      if (currentRead.record !== null) {
        if (currentRead.record.userId !== captured.ownerScopeId) {
          return batchResult(false, 'invalid_owner', [], false);
        }
        const decision = resolveMoonlightRecordConflict(
          currentRead.record, proposed, null);
        if (decision.action === 'quarantine_candidate' ||
            decision.action === 'quarantine_both') {
          this.port.recordMoonlightQuarantine(
            captured, proposed.id, decision.reason,
            proposed.payloadHashSha256);
          return batchResult(false, 'quarantined', [], false,
            decision.reason);
        }
        if (decision.record === null) {
          return batchResult(false, 'conflict', [], false, decision.reason);
        }
        toWrite = MoonlightRecord.fromJSON(decision.record.toJSON());
        if (decision.action === 'keep_current' &&
            currentRead.localOnly === localOnly) {
          const unchanged: boolean = decision.reason === 'identical_retry' ||
            sameRecord(currentRead.record, proposed);
          if (!unchanged) {
            return batchResult(false, 'conflict', [], false,
              decision.reason);
          }
          resolved.push(toWrite);
          continue;
        }
      }
      resolved.push(toWrite);
      writes.push({
        record: toWrite,
        localOnly: localOnly,
        operation: toWrite.deletedAt > 0 ? 'tombstone' : 'upsert'
      });
    }
    if (writes.length === 0) {
      return batchResult(true, 'unchanged', resolved, false);
    }
    if (!this.leaseIsCurrent(captured)) {
      return batchResult(false, 'stale_lease', [], false);
    }
    if (!this.port.commitMoonlightLocalRecords(captured, writes)) {
      return batchResult(false, this.leaseIsCurrent(captured) ?
        'local_write_failed' : 'stale_lease', [], false);
    }
    if (!this.leaseIsCurrent(captured)) {
      return batchResult(false, 'stale_lease', resolved, true);
    }
    for (let i = 0; i < resolved.length; i++) {
      const localOnly: number = mutations[i].localOnly;
      let readback: MoonlightRepositoryReadResult;
      try {
        readback = this.port.readMoonlightLocalRecord(
          captured, resolved[i].id);
      } catch (_error) {
        return batchResult(false, 'readback_failed', resolved, true);
      }
      if (!readback.ok || readback.record === null ||
          readback.localOnly !== localOnly ||
          !sameRecord(readback.record, resolved[i])) {
        return batchResult(false, 'readback_failed', resolved, true);
      }
    }
    return batchResult(true, 'ok', resolved, true);
  }

  tombstone(lease: AccountSessionLease, id: string, nowMs: number,
    localOnly: number = 1): MoonlightRepositoryResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', null, false);
    }
    if (!Number.isSafeInteger(nowMs) || nowMs <= 0 || id.trim() === '') {
      return result(false, 'invalid_record', null, false);
    }
    let read: MoonlightRepositoryReadResult;
    try {
      read = this.port.readMoonlightLocalRecord(captured, id);
    } catch (_error) {
      return result(false, 'not_ready', null, false);
    }
    if (!read.ok) { return result(false, 'not_ready', null, false); }
    if (read.record === null) { return result(false, 'not_found', null, false); }
    if (read.record.userId !== captured.ownerScopeId) {
      return result(false, 'invalid_owner', null, false);
    }
    if (read.record.deletedAt > 0) {
      return result(true, 'unchanged', read.record, false, 'already_deleted');
    }
    if (read.record.syncVersion >= Number.MAX_SAFE_INTEGER ||
        nowMs < read.record.createdAt || nowMs < read.record.updatedAt) {
      return result(false, 'invalid_record', null, false);
    }
    const tombstone: MoonlightRecord =
      MoonlightRecord.fromJSON(read.record.toJSON());
    tombstone.payload = '{}';
    tombstone.ciphertext = '';
    tombstone.envelopeVersion = 0;
    tombstone.cryptoVersion = 0;
    tombstone.keyVersion = 0;
    tombstone.aadVersion = 0;
    tombstone.syncVersion += 1;
    tombstone.updatedAt = nowMs;
    tombstone.deletedAt = nowMs;
    tombstone.payloadHashSha256 =
      moonlightRecordPayloadHashSha256(tombstone);
    return this.upsert(captured, tombstone, localOnly);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}
