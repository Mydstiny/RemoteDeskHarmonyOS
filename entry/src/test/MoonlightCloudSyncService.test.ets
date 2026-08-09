import { describe, expect, it } from '@ohos/hypium';
import {
  MoonlightRecord,
  moonlightRecordToCloudRow
} from '../main/ets/model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightCloudMaterializationResult,
  MoonlightCloudSyncGateSnapshot,
  MoonlightCloudSyncService,
  MoonlightCloudSyncServicePort
} from '../main/ets/services/MoonlightCloudSyncService';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import { MoonlightRepositoryReadResult } from '../main/ets/services/MoonlightRepository';

function lease(owner: string = 'owner-a', generation: number = 1,
  instance: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner, storeIdentity: 'store-' + owner,
    generation: generation, storeInstanceId: instance
  };
}

function hostRecord(id: string, mutationId: string,
  updatedAt: number = 101): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: mutationId, originId: 'owner-a-origin',
    baseSyncVersion: 0, fieldVersions: { 'displayName': 1 }
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1, serverUuid: 'server-' + id,
    displayName: 'PC ' + id,
    addresses: [{ host: '192.0.2.30', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.30|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, meta, 'host');
  const record = new MoonlightRecord();
  record.id = id;
  record.userId = 'owner-a';
  record.recordType = 'host';
  record.ownerId = 'owner-a';
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = 1;
  record.createdAt = 100;
  record.updatedAt = updatedAt;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function identityRecord(): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: 'identity-1', originId: 'owner-a-origin',
    baseSyncVersion: 0, fieldVersions: {}
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1, identityVersion: 1,
    certificateSha256: 'c'.repeat(64),
    storageMode: 'cloudEncryptedPending'
  }, meta, 'secret');
  const record = new MoonlightRecord();
  record.id = 'identity-1';
  record.userId = 'owner-a';
  record.recordType = 'secret';
  record.ownerId = 'owner-a';
  record.ownerType = 'account';
  record.secretKind = 'client_identity';
  record.payload = payload.canonical;
  record.ciphertext = 'AQID';
  record.envelopeVersion = 1;
  record.cryptoVersion = 1;
  record.keyVersion = 1;
  record.aadVersion = 1;
  record.syncVersion = 1;
  record.createdAt = 100;
  record.updatedAt = 101;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function tombstone(record: MoonlightRecord): MoonlightRecord {
  const deleted: MoonlightRecord = MoonlightRecord.fromJSON(record.toJSON());
  deleted.payload = '{}';
  deleted.ciphertext = '';
  deleted.envelopeVersion = 0;
  deleted.cryptoVersion = 0;
  deleted.keyVersion = 0;
  deleted.aadVersion = 0;
  deleted.syncVersion += 1;
  deleted.updatedAt = 200;
  deleted.deletedAt = 200;
  deleted.payloadHashSha256 = moonlightRecordPayloadHashSha256(deleted);
  return deleted;
}

function gates(scopes: string[] = ['hosts']): MoonlightCloudSyncGateSnapshot {
  return {
    cloudSchemaReady: true,
    physicalTableSelected: true,
    selectedScopes: scopes,
    identityCapabilityReady: false,
    cryptoConfigured: false
  };
}

function encryptedIdentity(value: string): boolean {
  return value === 'AQID';
}

class MemoryCloudSyncPort implements MoonlightCloudSyncServicePort {
  activeLease: AccountSessionLease | null = lease();
  rows: Map<string, MoonlightRecord> = new Map<string, MoonlightRecord>();
  localOnly: Map<string, number> = new Map<string, number>();
  failedWriteIds: string[] = [];
  projectionFailure: boolean = false;
  promotedIds: string[] = [];
  quarantineReasons: string[] = [];

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null :
      cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  readMoonlightLocalRecord(candidate: AccountSessionLease,
    id: string): MoonlightRepositoryReadResult {
    if (!this.isLeaseCurrent(candidate)) {
      return { ok: false, record: null, localOnly: 1 };
    }
    const row: MoonlightRecord | undefined = this.rows.get(id);
    if (row === undefined) { return { ok: true, record: null, localOnly: 1 }; }
    const flag: number | undefined = this.localOnly.get(id);
    return {
      ok: true,
      record: MoonlightRecord.fromJSON(row.toJSON()),
      localOnly: flag === undefined ? 1 : flag
    };
  }

  loadMoonlightLocalRecords(candidate: AccountSessionLease,
    includeDeleted: boolean = false): MoonlightRecord[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
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
    if (!this.isLeaseCurrent(candidate) ||
        this.failedWriteIds.indexOf(record.id) >= 0) { return false; }
    this.rows.set(record.id, MoonlightRecord.fromJSON(record.toJSON()));
    this.localOnly.set(record.id, localOnly);
    return true;
  }

  recordMoonlightQuarantine(candidate: AccountSessionLease,
    _recordId: string, reason: string,
    _payloadHashSha256: string): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    this.quarantineReasons.push(reason);
    return true;
  }

  promoteMoonlightLocalRecords(candidate: AccountSessionLease,
    records: MoonlightRecord[]): boolean {
    if (!this.isLeaseCurrent(candidate) || this.projectionFailure) {
      return false;
    }
    for (let i = 0; i < records.length; i++) {
      this.promotedIds.push(records[i].id);
      this.localOnly.set(records[i].id, 0);
    }
    return true;
  }
}

export default function moonlightCloudSyncServiceTest(): void {
  describe('MoonlightCloudSyncService', (): void => {
    it('does_nothing_when_schema_or_physical_selection_is_off', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const disabled: MoonlightCloudSyncGateSnapshot = gates();
        disabled.cloudSchemaReady = false;
        const result: MoonlightCloudMaterializationResult =
          service.materializeDownloadedRows(
            lease(), [moonlightRecordToCloudRow(hostRecord('h1', 'm1'))], disabled);
        expect(result.code).assertEqual('disabled');
        expect(result.cloudAttempted).assertFalse();
        expect(port.rows.size).assertEqual(0);
      });

    it('skips_logical_scopes_without_deleting_or_quarantining_rows', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(hostRecord('h1', 'm1'))],
          gates([]));
        expect(result.ok).assertTrue();
        expect(result.skipped).assertEqual(1);
        expect(result.quarantined).assertEqual(0);
        expect(port.rows.size).assertEqual(0);
      });

    it('materializes_cloud_first_live_rows_and_later_tombstones', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const live: MoonlightRecord = hostRecord('h1', 'm1');
        expect(service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(live)], gates()).ok).assertTrue();
        expect(port.localOnly.get('h1') as number).assertEqual(0);
        expect(service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(tombstone(live))], gates()).ok)
          .assertTrue();
        expect((port.rows.get('h1') as MoonlightRecord).deletedAt)
          .assertEqual(200);
      });

    it('keeps_identity_opaque_and_unmaterialized_when_identity_scope_is_off',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(identityRecord())], gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.skipped).assertEqual(1);
        expect(result.quarantined).assertEqual(0);
        expect(port.rows.has('identity-1')).assertFalse();
      });

    it('materializes_identity_only_with_capability_crypto_scope_and_ciphertext',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const enabled: MoonlightCloudSyncGateSnapshot = gates(['identity']);
        enabled.identityCapabilityReady = true;
        enabled.cryptoConfigured = true;
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(identityRecord())], enabled);
        expect(result.ok).assertTrue();
        expect(result.accepted).assertEqual(1);
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('quarantines_malformed_rows_and_continues_safe_rows', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const malformed: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord('bad', 'bad'));
        delete malformed['ownerid'];
        const result = service.materializeDownloadedRows(lease(), [
          malformed,
          moonlightRecordToCloudRow(hostRecord('good', 'good'))
        ], gates());
        expect(result.code).assertEqual('partial');
        expect(result.quarantined).assertEqual(1);
        expect(result.accepted).assertEqual(1);
        expect(port.quarantineReasons[0]).assertEqual('cloud_row_shape_invalid');
      });

    it('reports_partial_failure_without_rolling_back_other_safe_rows', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.failedWriteIds.push('fail');
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(lease(), [
          moonlightRecordToCloudRow(hostRecord('fail', 'm1')),
          moonlightRecordToCloudRow(hostRecord('ok', 'm2'))
        ], gates());
        expect(result.code).assertEqual('partial');
        expect(result.failed).assertEqual(1);
        expect(result.accepted).assertEqual(1);
        expect(port.rows.has('ok')).assertTrue();
      });

    it('promotes_only_selected_local_rows_and_preserves_hidden_identity', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('h1', hostRecord('h1', 'm1'));
        port.localOnly.set('h1', 1);
        port.rows.set('identity-1', identityRecord());
        port.localOnly.set('identity-1', 1);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.promoteSelectedLocalRecords(lease(), gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.promoted).assertEqual(1);
        expect(port.promotedIds.join(',')).assertEqual('h1');
        expect(port.localOnly.get('identity-1') as number).assertEqual(1);
      });

    it('fails_closed_when_atomic_projection_fails', 0, (): void => {
      const port = new MemoryCloudSyncPort();
      port.rows.set('h1', hostRecord('h1', 'm1'));
      port.localOnly.set('h1', 1);
      port.projectionFailure = true;
      const service = new MoonlightCloudSyncService(port, encryptedIdentity);
      const result = service.promoteSelectedLocalRecords(lease(), gates(['hosts']));
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('projection_failed');
      expect(result.cloudAttempted).assertFalse();
      expect(port.localOnly.get('h1') as number).assertEqual(1);
    });
  });
}
