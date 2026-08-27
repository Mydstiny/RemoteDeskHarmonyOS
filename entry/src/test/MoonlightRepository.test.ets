import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { MoonlightRecord } from '../main/ets/model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import {
  MoonlightRepository,
  MoonlightRepositoryCommit,
  MoonlightRepositoryPort,
  MoonlightRepositoryReadResult
} from '../main/ets/services/MoonlightRepository';

function lease(owner: string, generation: number = 1,
  storeInstanceId: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation: generation,
    storeInstanceId: storeInstanceId
  };
}

function hostRecord(owner: string, mutationId: string,
  displayName: string = 'PC', syncVersion: number = 1,
  updatedAt: number = 101): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: mutationId,
    originId: 'origin-' + owner,
    baseSyncVersion: 0,
    fieldVersions: { 'displayName': syncVersion }
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    serverUuid: 'server-uuid-1',
    displayName: displayName,
    addresses: [{ host: '192.0.2.20', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.20|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, meta, 'host');
  const record = new MoonlightRecord();
  record.id = 'shared-host-id';
  record.userId = owner;
  record.recordType = 'host';
  record.ownerId = owner;
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = syncVersion;
  record.createdAt = 100;
  record.updatedAt = updatedAt;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

class MemoryMoonlightRepositoryPort implements MoonlightRepositoryPort {
  activeLease: AccountSessionLease | null = lease('owner-a');
  rows: Map<string, MoonlightRecord> = new Map<string, MoonlightRecord>();
  localOnlyByKey: Map<string, number> = new Map<string, number>();
  writeFailure: boolean = false;
  readFailure: boolean = false;
  corruptReadback: boolean = false;
  switchAfterCommit: boolean = false;
  commitCount: number = 0;
  quarantineCount: number = 0;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null :
      cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  readMoonlightLocalRecord(candidate: AccountSessionLease,
    id: string): MoonlightRepositoryReadResult {
    if (this.readFailure || !this.isLeaseCurrent(candidate)) {
      return { ok: false, record: null, localOnly: 1 };
    }
    const stored: MoonlightRecord | undefined =
      this.rows.get(candidate.ownerScopeId + ':' + id);
    if (stored === undefined) { return { ok: true, record: null, localOnly: 1 }; }
    const copy: MoonlightRecord = MoonlightRecord.fromJSON(stored.toJSON());
    if (this.corruptReadback && this.commitCount > 0) {
      copy.updatedAt += 1;
    }
    const key: string = candidate.ownerScopeId + ':' + id;
    const localOnly: number | undefined = this.localOnlyByKey.get(key);
    return { ok: true, record: copy,
      localOnly: localOnly === undefined ? 1 : localOnly };
  }

  loadMoonlightLocalRecords(candidate: AccountSessionLease,
    includeDeleted: boolean = false): MoonlightRecord[] | null {
    if (this.readFailure || !this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightRecord[] = [];
    this.rows.forEach((row: MoonlightRecord): void => {
      if (row.userId === candidate.ownerScopeId &&
          (includeDeleted || row.deletedAt === 0)) {
        result.push(MoonlightRecord.fromJSON(row.toJSON()));
      }
    });
    return result;
  }

  commitMoonlightLocalRecord(candidate: AccountSessionLease,
    record: MoonlightRecord, localOnly: number,
    _operation: string): boolean {
    if (this.writeFailure || !this.isLeaseCurrent(candidate)) { return false; }
    const key: string = candidate.ownerScopeId + ':' + record.id;
    this.rows.set(key,
      MoonlightRecord.fromJSON(record.toJSON()));
    this.localOnlyByKey.set(key, localOnly);
    this.commitCount++;
    if (this.switchAfterCommit) {
      this.activeLease = lease('owner-b', candidate.generation + 1,
        candidate.storeInstanceId + 1);
    }
    return true;
  }

  commitMoonlightLocalRecords(candidate: AccountSessionLease,
    commits: MoonlightRepositoryCommit[]): boolean {
    if (this.writeFailure || !this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < commits.length; i++) {
      const key: string = candidate.ownerScopeId + ':' + commits[i].record.id;
      this.rows.set(key, MoonlightRecord.fromJSON(commits[i].record.toJSON()));
      this.localOnlyByKey.set(key, commits[i].localOnly);
      this.commitCount++;
    }
    if (this.switchAfterCommit) {
      this.activeLease = lease('owner-b', candidate.generation + 1,
        candidate.storeInstanceId + 1);
    }
    return true;
  }

  recordMoonlightQuarantine(candidate: AccountSessionLease,
    _recordId: string, _reason: string,
    _payloadHashSha256: string): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    this.quarantineCount++;
    return true;
  }
}

export default function moonlightRepositoryTest(): void {
  describe('MoonlightRepository', (): void => {
    it('commits_new_rows_to_the_local_overlay_without_cloud_calls', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      const result = repository.upsert(lease('owner-a'),
        hostRecord('owner-a', 'm1'));
      expect(result.ok).assertTrue();
      expect(result.localCommitted).assertTrue();
      expect(result.cloudAttempted).assertFalse();
      expect(port.commitCount).assertEqual(1);
    });

    it('rejects_a_stale_generation_before_read_or_write', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      const result = repository.upsert(lease('owner-a', 2),
        hostRecord('owner-a', 'm1'));
      expect(result.code).assertEqual('stale_lease');
      expect(port.commitCount).assertEqual(0);
    });

    it('isolates_the_same_record_id_between_owner_A_and_B', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      expect(repository.upsert(lease('owner-a'),
        hostRecord('owner-a', 'a')).ok).assertTrue();
      port.activeLease = lease('owner-b', 2, 2);
      expect(repository.upsert(lease('owner-b', 2, 2),
        hostRecord('owner-b', 'b')).ok).assertTrue();
      expect(port.rows.size).assertEqual(2);
      expect((port.rows.get('owner-a:shared-host-id') as MoonlightRecord).userId)
        .assertEqual('owner-a');
      expect((port.rows.get('owner-b:shared-host-id') as MoonlightRecord).userId)
        .assertEqual('owner-b');
    });

    it('reports_transaction_failure_without_claiming_local_commit', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      port.writeFailure = true;
      const result = new MoonlightRepository(port).upsert(
        lease('owner-a'), hostRecord('owner-a', 'm1'));
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('local_write_failed');
      expect(result.localCommitted).assertFalse();
    });

    it('detects_an_account_switch_after_the_storage_commit', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      port.switchAfterCommit = true;
      const result = new MoonlightRepository(port).upsert(
        lease('owner-a'), hostRecord('owner-a', 'm1'));
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('stale_lease');
      expect(result.localCommitted).assertTrue();
      expect(result.cloudAttempted).assertFalse();
    });

    it('makes_an_exact_retry_idempotent', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      const record: MoonlightRecord = hostRecord('owner-a', 'same');
      expect(repository.upsert(lease('owner-a'), record).ok).assertTrue();
      const retry = repository.upsert(lease('owner-a'), record);
      expect(retry.ok).assertTrue();
      expect(retry.code).assertEqual('unchanged');
      expect(port.commitCount).assertEqual(1);
    });

    it('persists_projection_eligibility_without_attempting_cloud_IO', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      const record: MoonlightRecord = hostRecord('owner-a', 'same');
      expect(repository.upsert(lease('owner-a'), record, 1).ok).assertTrue();
      const eligible = repository.upsert(lease('owner-a'), record, 0);
      expect(eligible.ok).assertTrue();
      expect(eligible.cloudAttempted).assertFalse();
      expect(port.localOnlyByKey.get('owner-a:shared-host-id') as number)
        .assertEqual(0);
      expect(port.commitCount).assertEqual(2);
    });

    it('quarantines_mutation_id_reuse_and_preserves_the_current_row', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      expect(repository.upsert(lease('owner-a'),
        hostRecord('owner-a', 'same', 'PC')).ok).assertTrue();
      const conflict = repository.upsert(lease('owner-a'),
        hostRecord('owner-a', 'same', 'Other PC'));
      expect(conflict.ok).assertFalse();
      expect(conflict.code).assertEqual('quarantined');
      expect(port.quarantineCount).assertEqual(1);
      expect(port.commitCount).assertEqual(1);
    });

    it('writes_a_content_free_tombstone_with_a_new_version', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      expect(repository.upsert(lease('owner-a'),
        hostRecord('owner-a', 'm1')).ok).assertTrue();
      const deleted = repository.tombstone(
        lease('owner-a'), 'shared-host-id', 200);
      expect(deleted.ok).assertTrue();
      expect((deleted.record as MoonlightRecord).payload).assertEqual('{}');
      expect((deleted.record as MoonlightRecord).deletedAt).assertEqual(200);
      expect((deleted.record as MoonlightRecord).syncVersion).assertEqual(2);
    });

    it('rejects_cross_owner_and_invalid_rows_without_storage_calls', 0, (): void => {
      const port = new MemoryMoonlightRepositoryPort();
      const repository = new MoonlightRepository(port);
      expect(repository.upsert(lease('owner-a'),
        hostRecord('owner-b', 'm1')).code).assertEqual('invalid_owner');
      const invalid: MoonlightRecord = hostRecord('owner-a', 'm2');
      invalid.payloadHashSha256 = 'bad';
      expect(repository.upsert(lease('owner-a'), invalid).code)
        .assertEqual('invalid_record');
      expect(port.commitCount).assertEqual(0);
    });
  });
}
