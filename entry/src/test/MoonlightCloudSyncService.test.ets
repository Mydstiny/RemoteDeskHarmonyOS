import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightRecord,
  moonlightRecordToCloudRow
} from '../main/ets/model/MoonlightRecord';
import { defaultMoonlightSettings } from '../main/ets/model/MoonlightModels';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightCloudLocalMutation,
  MoonlightCloudMaterializationResult,
  MoonlightCloudQuarantineMutation,
  MoonlightCloudSyncGateSnapshot,
  MoonlightCloudSyncService,
  MoonlightCloudSyncServicePort
} from '../main/ets/services/MoonlightCloudSyncService';
import {
  MoonlightCloudSyncScope,
  isMoonlightRecordTypeSelected
} from '../main/ets/services/MoonlightCloudSyncSelectionPolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import {
  MoonlightRepositoryCommit,
  MoonlightRepositoryReadResult
} from '../main/ets/services/MoonlightRepository';

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

function scopedHostRecord(id: string, mutationId: string): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: mutationId, originId: 'owner-a-origin',
    baseSyncVersion: 0, fieldVersions: { 'addresses': 1 }
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1, serverUuid: 'server-' + id,
    displayName: 'Scoped PC ' + id,
    addresses: [{
      host: 'fe80::20', family: 'ipv6', port: 47989, scope: 'wlan0'
    }],
    preferredAddressKey: 'ipv6|fe80::20%wlan0|47989',
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
  record.updatedAt = 101;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function embeddedScopedHostRecord(id: string, mutationId: string): MoonlightRecord {
  const record: MoonlightRecord = scopedHostRecord(id, mutationId);
  const payload: Record<string, Object> = JSON.parse(record.payload) as Record<string, Object>;
  const addresses: Array<Record<string, Object>> =
    payload['addresses'] as Array<Record<string, Object>>;
  addresses[0]['host'] = 'fe80::20%wlan0';
  delete addresses[0]['scope'];
  const meta: MoonlightRecordMeta = payload['_meta'] as MoonlightRecordMeta;
  delete payload['_meta'];
  record.payload = moonlightPayloadWithMeta(
    payload, meta, 'host').canonical;
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

function settingsRecord(mutationId: string, baseSyncVersion: number,
  syncVersion: number, updatedAt: number, fps: number, bitrate: number,
  fieldVersions: Record<string, number>): MoonlightRecord {
  const settings = defaultMoonlightSettings();
  settings.video.fps = fps;
  settings.video.bitrateKbps = bitrate;
  const meta: MoonlightRecordMeta = {
    mutationId: mutationId,
    originId: 'owner-a-origin',
    baseSyncVersion: baseSyncVersion,
    fieldVersions: fieldVersions
  };
  const payload = moonlightPayloadWithMeta(
    settings as Record<string, Object>, meta, 'settings');
  const record = new MoonlightRecord();
  record.id = 'settings-owner-a';
  record.userId = 'owner-a';
  record.recordType = 'settings';
  record.ownerId = 'owner-a';
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = syncVersion;
  record.createdAt = 100;
  record.updatedAt = updatedAt;
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
  promotedDeletedAt: number[] = [];
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

  commitMoonlightLocalRecords(candidate: AccountSessionLease,
    commits: MoonlightRepositoryCommit[]): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < commits.length; i++) {
      if (this.failedWriteIds.indexOf(commits[i].record.id) >= 0) {
        return false;
      }
    }
    for (let i = 0; i < commits.length; i++) {
      this.rows.set(commits[i].record.id,
        MoonlightRecord.fromJSON(commits[i].record.toJSON()));
      this.localOnly.set(commits[i].record.id, commits[i].localOnly);
    }
    return true;
  }

  recordMoonlightQuarantine(candidate: AccountSessionLease,
    _recordId: string, reason: string,
    _payloadHashSha256: string): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    this.quarantineReasons.push(reason);
    return true;
  }

  commitMoonlightCloudMaterialization(
    candidate: AccountSessionLease,
    mutations: MoonlightCloudLocalMutation[],
    quarantines: MoonlightCloudQuarantineMutation[]): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < mutations.length; i++) {
      if (this.failedWriteIds.indexOf(
        mutations[i].record.id) >= 0) {
        return false;
      }
    }
    const nextRows: Map<string, MoonlightRecord> =
      new Map<string, MoonlightRecord>(this.rows);
    const nextFlags: Map<string, number> =
      new Map<string, number>(this.localOnly);
    for (let i = 0; i < mutations.length; i++) {
      nextRows.set(mutations[i].record.id,
        MoonlightRecord.fromJSON(mutations[i].record.toJSON()));
      nextFlags.set(mutations[i].record.id, mutations[i].localOnly);
    }
    for (let i = 0; i < quarantines.length; i++) {
      this.quarantineReasons.push(quarantines[i].reason);
    }
    this.rows = nextRows;
    this.localOnly = nextFlags;
    return true;
  }

  replaceMoonlightLocalRecordsFromCloud(
    candidate: AccountSessionLease, records: MoonlightRecord[],
    selectedScopes: MoonlightCloudSyncScope[]): boolean {
    if (!this.isLeaseCurrent(candidate) || this.projectionFailure) {
      return false;
    }
    const nextRows: Map<string, MoonlightRecord> =
      new Map<string, MoonlightRecord>();
    const nextFlags: Map<string, number> = new Map<string, number>();
    this.rows.forEach((row: MoonlightRecord, id: string): void => {
      if (!isMoonlightRecordTypeSelected(
        row.recordType, selectedScopes, false)) {
        nextRows.set(id, MoonlightRecord.fromJSON(row.toJSON()));
        nextFlags.set(id, this.localOnly.get(id) as number);
      }
    });
    for (let i = 0; i < records.length; i++) {
      nextRows.set(records[i].id,
        MoonlightRecord.fromJSON(records[i].toJSON()));
      nextFlags.set(records[i].id, 0);
    }
    this.rows = nextRows;
    this.localOnly = nextFlags;
    return true;
  }

  promoteMoonlightLocalRecords(candidate: AccountSessionLease,
    records: MoonlightRecord[]): number {
    if (!this.isLeaseCurrent(candidate) || this.projectionFailure) {
      return -1;
    }
    for (let i = 0; i < records.length; i++) {
      this.promotedIds.push(records[i].id);
      this.promotedDeletedAt.push(records[i].deletedAt);
      this.localOnly.set(records[i].id, 0);
    }
    return records.length;
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
        const promotion = service.promoteSelectedLocalRecords(
          lease(), gates());
        expect(promotion.ok).assertTrue();
        expect(promotion.promoted).assertEqual(0);
        expect(port.promotedDeletedAt.length).assertEqual(0);
        expect((port.rows.get('h1') as MoonlightRecord).deletedAt)
          .assertEqual(200);
      });

    it('promotes_an_offline_local_tombstone_only_after_cloud_first_merge',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        const live: MoonlightRecord = hostRecord('h1', 'cloud-live');
        const deleted: MoonlightRecord = tombstone(live);
        port.rows.set(deleted.id, deleted);
        port.localOnly.set(deleted.id, 1);
        const newerCloud: MoonlightRecord =
          MoonlightRecord.fromJSON(live.toJSON());
        newerCloud.syncVersion = 99;
        newerCloud.updatedAt = 999;
        newerCloud.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(newerCloud);
        const service = new MoonlightCloudSyncService(
          port, encryptedIdentity);
        const pulled = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(newerCloud)], gates());
        expect(pulled.ok).assertTrue();
        expect((port.rows.get('h1') as MoonlightRecord).deletedAt)
          .assertEqual(200);
        expect(port.localOnly.get('h1') as number).assertEqual(1);
        const promoted = service.promoteSelectedLocalRecords(
          lease(), gates());
        expect(promoted.ok).assertTrue();
        expect(promoted.promoted).assertEqual(1);
        expect(port.promotedDeletedAt[0]).assertEqual(200);
      });

    it('does_not_resurrect_a_synced_mirror_missing_from_the_cloud_snapshot',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('synced-host', hostRecord('synced-host', 'old-cloud'));
        port.localOnly.set('synced-host', 0);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.promoteSelectedLocalRecords(
          lease(), gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.promoted).assertEqual(0);
        expect(port.promotedIds.length).assertEqual(0);
        expect(port.localOnly.get('synced-host') as number).assertEqual(0);
      });

    it('manual_cloud_authority_replaces_selected_rows_and_preserves_local_identity',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        const cloud: MoonlightRecord = hostRecord('h1', 'cloud', 120);
        const newerLocal: MoonlightRecord = hostRecord('h1', 'local', 220);
        newerLocal.syncVersion = 2;
        newerLocal.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(newerLocal);
        port.rows.set('h1', newerLocal);
        port.localOnly.set('h1', 1);
        port.rows.set('h2', hostRecord('h2', 'local-only', 230));
        port.localOnly.set('h2', 1);
        port.rows.set('identity-1', identityRecord());
        port.localOnly.set('identity-1', 1);
        const service = new MoonlightCloudSyncService(
          port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(cloud)],
          gates(['hosts']), true);
        expect(result.ok).assertTrue();
        expect((port.rows.get('h1') as MoonlightRecord).updatedAt)
          .assertEqual(120);
        expect(port.localOnly.get('h1') as number).assertEqual(0);
        expect(port.rows.has('h2')).assertFalse();
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('manual_empty_cloud_authority_clears_only_selected_scopes', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('h1', hostRecord('h1', 'local'));
        port.localOnly.set('h1', 1);
        port.rows.set('identity-1', identityRecord());
        port.localOnly.set('identity-1', 1);
        const service = new MoonlightCloudSyncService(
          port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [], gates(['hosts']), true);
        expect(result.ok).assertTrue();
        expect(port.rows.has('h1')).assertFalse();
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('manual_partial_snapshot_salvages_valid_rows_without_deleting_local_rows', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('h1', hostRecord('h1', 'local'));
        port.localOnly.set('h1', 1);
        const malformed: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord('bad', 'bad'));
        delete malformed['ownerid'];
        const valid: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord('good', 'cloud'));
        const service = new MoonlightCloudSyncService(
          port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [malformed, valid], gates(['hosts']), true);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('partial');
        expect(result.accepted).assertEqual(1);
        expect(result.quarantined).assertEqual(1);
        expect(port.rows.has('h1')).assertTrue();
        expect(port.localOnly.get('h1') as number).assertEqual(1);
        expect(port.rows.has('good')).assertTrue();
        expect(port.localOnly.get('good') as number).assertEqual(0);
        expect(port.quarantineReasons[0])
          .assertEqual('cloud_row_shape_invalid');
      });

    it('preserves_a_newer_local_host_for_post_pull_promotion', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const cloud: MoonlightRecord = hostRecord('h1', 'cloud-old', 120);
        const local: MoonlightRecord = MoonlightRecord.fromJSON(cloud.toJSON());
        local.syncVersion = 2;
        local.updatedAt = 220;
        local.payloadHashSha256 = moonlightRecordPayloadHashSha256(local);
        port.rows.set(local.id, local);
        port.localOnly.set(local.id, 0);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(cloud)], gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.accepted).assertEqual(1);
        expect((port.rows.get(local.id) as MoonlightRecord).syncVersion)
          .assertEqual(2);
        expect(port.localOnly.get(local.id) as number).assertEqual(1);
        expect(service.promoteSelectedLocalRecords(
          lease(), gates(['hosts'])).promoted).assertEqual(1);
        expect(port.promotedIds.join(',')).assertEqual(local.id);
      });

    it('deterministically_merges_concurrent_settings_before_projection', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const local: MoonlightRecord = settingsRecord(
          'writer-a', 1, 2, 200, 30, 20000,
          { 'video.fps': 2 });
        const cloud: MoonlightRecord = settingsRecord(
          'writer-b', 1, 2, 201, 60, 40000,
          { 'video.bitrateKbps': 2 });
        port.rows.set(local.id, local);
        port.localOnly.set(local.id, 1);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(cloud)], gates(['settings']));
        expect(result.ok).assertTrue();
        const merged: MoonlightRecord =
          port.rows.get(local.id) as MoonlightRecord;
        const payload = JSON.parse(merged.payload) as Record<string, Object>;
        const video = payload['video'] as Record<string, Object>;
        const meta = payload['_meta'] as Record<string, Object>;
        expect(video['fps'] as number).assertEqual(30);
        expect(video['bitrateKbps'] as number).assertEqual(40000);
        expect(merged.syncVersion).assertEqual(3);
        expect(port.localOnly.get(local.id) as number).assertEqual(1);
        expect((meta['mutationId'] as string).indexOf(
          'moonlight-cloud-merge-v1:')).assertEqual(0);
        expect(service.promoteSelectedLocalRecords(
          lease(), gates(['settings'])).promoted).assertEqual(1);
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

    it('never_materializes_private_identity_even_when_legacy_gates_claim_ready',
      0, (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const enabled: MoonlightCloudSyncGateSnapshot = gates(['identity']);
        enabled.identityCapabilityReady = true;
        enabled.cryptoConfigured = true;
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(identityRecord())], enabled);
        expect(result.ok).assertTrue();
        expect(result.skipped).assertEqual(1);
        expect(result.accepted).assertEqual(0);
        expect(port.rows.has('identity-1')).assertFalse();
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

    it('quarantines_downloaded_link_local_scope_as_device_private', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(scopedHostRecord('scoped', 'm1'))],
          gates(['hosts']));
        expect(result.code).assertEqual('partial');
        expect(result.accepted).assertEqual(0);
        expect(result.quarantined).assertEqual(1);
        expect(port.quarantineReasons[0])
          .assertEqual('cloud_device_private_endpoint');
        expect(port.rows.has('scoped')).assertFalse();
      });

    it('quarantines_downloaded_embedded_scope_instead_of_materializing_it', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(
          lease(), [moonlightRecordToCloudRow(
            embeddedScopedHostRecord('embedded-scoped', 'm1'))], gates(['hosts']));
        expect(result.code).assertEqual('partial');
        expect(result.accepted).assertEqual(0);
        expect(result.quarantined).assertEqual(1);
        expect(port.rows.has('embedded-scoped')).assertFalse();
      });

    it('rolls_back_the_whole_materialization_when_one_write_fails', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.failedWriteIds.push('fail');
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.materializeDownloadedRows(lease(), [
          moonlightRecordToCloudRow(hostRecord('fail', 'm1')),
          moonlightRecordToCloudRow(hostRecord('ok', 'm2'))
        ], gates());
        expect(result.code).assertEqual('projection_failed');
        expect(result.failed).assertEqual(1);
        expect(result.accepted).assertEqual(2);
        expect(port.rows.has('ok')).assertFalse();
        expect(port.rows.has('fail')).assertFalse();
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

    it('never_promotes_a_link_local_interface_scope_to_cloud', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('scoped', scopedHostRecord('scoped', 'm1'));
        port.localOnly.set('scoped', 1);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.promoteSelectedLocalRecords(
          lease(), gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.promoted).assertEqual(0);
        expect(port.promotedIds.length).assertEqual(0);
        expect(port.localOnly.get('scoped') as number).assertEqual(1);
      });

    it('never_promotes_an_embedded_scope_bypass_to_cloud', 0,
      (): void => {
        const port = new MemoryCloudSyncPort();
        port.rows.set('embedded-scoped',
          embeddedScopedHostRecord('embedded-scoped', 'm1'));
        port.localOnly.set('embedded-scoped', 1);
        const service = new MoonlightCloudSyncService(port, encryptedIdentity);
        const result = service.promoteSelectedLocalRecords(
          lease(), gates(['hosts']));
        expect(result.ok).assertTrue();
        expect(result.promoted).assertEqual(0);
        expect(port.promotedIds.length).assertEqual(0);
        expect(port.localOnly.get('embedded-scoped') as number).assertEqual(1);
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
